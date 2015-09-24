package AMFM;

use 5.014;
use warnings;
use Data::Dumper;
use Digest::MD5 qw/md5_hex/;
use IO::Socket::INET;
use Logger qw/error debug warning info/;
use JSON qw/from_json to_json/;
use POSIX qw/strftime setsid/;
use URI::Escape;
use Net::Ping;
use WWW::Curl::Easy qw/CURLOPT_HEADER CURLOPT_URL CURLOPT_TIMEOUT CURLOPT_HTTPHEADER CURLOPT_WRITEDATA CURLOPT_POSTFIELDS CURLOPT_POST/;
use List::MoreUtils qw/all zip/;
use Try::Tiny;
use Encode;
use open ':std', ':utf8';
$| = 1;

my $MPD_HOST = $ENV{MPD_HOST} || "localhost";
my $MPD_PORT = $ENV{MPD_PORT} || "6600";
my $PASSWORD = $ENV{LASTFM_PASSWORD} || die "Please provide LASTFM_PASSWORD variable";
my $USERNAME = $ENV{LASTFM_USERNAME} || die "Please provide LASTFM_USERNAME variable";
my $PID_FILE = $ENV{PID_FILE} || '/tmp/amfm.pid';
my $LOG_FILE = $ENV{LOG_FILE} || '/tmp/amfm.log';
my $ERR_FILE = $ENV{ERR_FILE} || '/tmp/amfm.err';
my $TICK = 5;
my $MIN_PLAY_TIME = 30;
my $NOW_PLAYING_INTERVAL = 20;
my $API_KEY = "7c04baa41513c100f7544a329ac97638";
my $SECRET = "c1e017252469c6387459e6e7b51d6f53";
my $URL_ROOT = "https://ws.audioscrobbler.com/2.0/";

sub new {
    my $class = shift;
    my %self = (
        artist => '',
        track => '',
        title => '',
        token => undef,
        session_key => undef,
        mpd_socket => undef,
        updated => 0,
        started => undef,
        is_scrobbled => 0,
        is_running => 1,
        colorize => 1,
        curl => WWW::Curl::Easy->new(),
    );
    return bless \%self, $class;
}
sub quit {
    my $self = shift;
    warning("Closing connection to MPD");
    $self->{is_running} = 0;
    $self->{mpd_socket}->close() if $self->{mpd_socket};
}

sub compose_signed_url {
    my $self = shift;
    my %params = @_;
    $params{api_key} = $API_KEY;
    $params{format} = 'json';
    my $sign = (join '', map {($_ eq 'format' or $_ eq 'callback' or !$params{$_}) ? '' : $_.$params{$_}} sort keys %params).$SECRET;
    my $res = join('&', (map {($params{$_}) ? $_."=".uri_escape_utf8($params{$_}) : ''} keys %params), "api_sig=".md5_hex(encode('utf8', $sign)));
    return $res;
};

sub mpd_connect {
    my $self = shift;
    my $socket = IO::Socket::INET->new(
        PeerHost => $MPD_HOST,
        PeerPort => $MPD_PORT,
        Proto => 'tcp',
    ) or die "Could not create socket: $!\n";

    my $data = <$socket>;
    if (!$data) {
        info("Cannot connect to MPD");
        return;
    }
    $self->{mpd_socket} = $socket;
    return $socket;
}

sub mpd_command {
    my $self = shift;
    my $cmd = shift;
    my $socket = $self->{mpd_socket};
    $socket->send("$cmd\r\n");
    my $res = do { local $/ = "OK\n"; <$socket>};
    $res = decode("utf8", $res);
    return '' if !$res;
    $res =~ s/\nOK\n//g;
    return $res;
}

sub can_connect {
    my $p = Net::Ping->new("external");
    if (!$p->ping("ws.audioscrobbler.com")) {
        error("Last.fm is unreachable");
        return '';
    }
    return 1;
}

sub make_request {
    my $self = shift;
    my ($url, $post, $body) = @_;
    my $response;
    #say "$url?$body";

    $self->{curl}->setopt(WWW::Curl::Easy::CURLOPT_URL, $url);
    if ($post) {
        $self->{curl}->setopt(WWW::Curl::Easy::CURLOPT_POST, 1);
        if ($body) {
            $self->{curl}->setopt(WWW::Curl::Easy::CURLOPT_POSTFIELDS, $body);
        }
    }
    $self->{curl}->setopt(WWW::Curl::Easy::CURLOPT_WRITEDATA, \$response);

    my $retcode = $self->{curl}->perform();
    if ($retcode > 0) {
        error($self->{curl}->strerror($retcode));
        return '';
    }
    if (!defined($response)) {
        error("No response from: $url");
    }
    my $json = {};
    if ($response) {
        $json = from_json($response);
        if ($json->{error}) {
            error(to_json($json));
        }
    }
    return $json;
}

sub handshake {
    my $self = shift;
    my $token_url = $self->compose_signed_url(method => 'auth.getToken');
    info("Requesting an auth token from Last.fm");
    $self->{token} = $self->make_request($URL_ROOT.'?'.$token_url)->{token};
    if (!$self->{token}) {
        error('Cannot get token');
        die;
    }
    my $req = $self->compose_signed_url(username => $USERNAME,
                       password => $PASSWORD,
                       method => "auth.getMobileSession",
                       token => $self->{token});

    info("Requesting a session key from Last.fm");

    $self->{session_key} = $self->make_request($URL_ROOT, 1, $req)->{session}->{key};
    if (!$self->{session_key}) {
        @$self{('session_key', 'token')} = ();
    }
    return $self->{session_key};
}

sub mpd_is_playing {
    my $self = shift;
    my %status = split(/:\s|\n/, $self->mpd_command("status"));
    return (%status and defined($status{state}) and $status{state} =~ /play/) ? 1 : 0;
}

sub parse_title {
    my ($self, $title) = @_;
    my ($artist, $track, $album);
    my $old_title = $title;
    #say "Before: $title";
    for ($title) {
        s/(?:_|\s)+/ /g;
        # removing remixes
        s/\[[^\]]+\]//g;
        s/\([^\)]+\)//g;
        # removing track numbers
        s/[.\[\]\(\)0-9]{2,}//g;
        s/^(?:-|\s)+//g;
        s/\s+$//g;
        #s/,\s+The//g;
        # removing station title
        s/^[^:]+: //g;
    }
    #say "After: $title";
    ($artist, $track, $album) = split(/\s+-+\s+/, $title);
    if (!$artist or !$track) {
        ($artist, $track, $album) = split(/\s*-+\s*/, $title);
    }
    #say "SPLIT: $artist, $track";
    if ($artist and $track) {
        my ($new_artist, $new_track) = $self->search_track("$artist - $track".(($album) ? " - $album" : ''));
        if ($new_artist and $new_track) {
            ($artist, $track) = ($new_artist, $new_track);
        }
    }
    else {
        ($artist, $track) = ('', '');
    }
    warning("Could not parse '$old_title'") unless $artist and $track;
    return ($artist, $track);
}

sub update_current_song {
    my $self = shift;
    my ($title, $length, $artist, $track) = ('', '', '', '');
    my $status = $self->mpd_command('currentsong');
    #debug("$status");

    if ($status =~ /Title:\s+(.+)$/m) {
        ($title, $track) = ($1, $1);
        #debug("Track title: $track");
    }
    if ($status =~ /Artist:\s+(.+)$/m) {
        $artist = $1;
        #debug("Track artist: $artist");
    }
    if ($status =~ /Time:\s+(\d+)$/m) {
        $length = int($1);
        #debug("Track length: $length seconds");
    }

    return ($self->{artist}, $self->{track}) unless !($self->{title} eq $title);

    if (!$length) {
        debug('Length unknown, searching for the track online');
        ($artist, $track) = $self->parse_title($title);
    }
    if ($artist and $track) {
        if (!defined($self->{title}) or !($self->{title} eq $title)) {
            info("Playing $track by $artist");
            $self->{started} = time;
            $self->{is_scrobbled} = 0;
            $self->{artist} = $artist;
            $self->{track} = $track;
            $self->{minplaytime} = ($length) ? $length / 2 : $MIN_PLAY_TIME;
        }
    }
    else {
        $self->{is_scrobbled} = 1;
    }
    $self->{title} = $title;
    #debug(Dumper $self);
    return ($artist, $track);
}

sub scrobble {
    my ($self, $artist, $track) = @_;
    if ($artist and $track) {
        info("Scrobbling track $track by $artist");
        my $req = $self->compose_signed_url(method => 'track.scrobble',
                           timestamp => time,
                           sk => $self->{session_key},
                           artist => $artist, track => $track);
        debug("$req");
        $self->make_request($URL_ROOT, 1, $req);
    }
    $self->{is_scrobbled} = 1;
}

sub contains {
    my ($target, @substrings) = @_;
    my $q_target = quotemeta($target);
    for my $str (@substrings) {
        my $q_str = quotemeta($str);
        return 0 unless $target =~ /$q_str/i;
    }
    return 1;
}

sub search_track {
    my $self = shift;
    my $title = shift;
    my ($artist, $track) = ('', '');
    my $req = $self->compose_signed_url(method => 'track.search',
                       sk => $self->{session_key},
                       track => $title, limit => '100');
    my $search_results = $self->make_request($URL_ROOT, 1, $req);
    my $results = $search_results->{results};
    if ($results) {
        my $total = $results->{'opensearch:totalResults'};
        my $trackmatch;
        if ($total > 1) {
            # try to get best possible match
            my %by_listeners = map {$_->{listeners}, $_} @{$results->{trackmatches}->{track}};
            my $cmp = sub {
                my $a_artist = $by_listeners{$_[0]}->{artist};
                my $a_track = $by_listeners{$_[0]}->{name};

                my $b_artist = $by_listeners{$_[1]}->{artist};
                my $b_track = $by_listeners{$_[1]}->{name};

                #say "$a_artist: $a_track, $b_artist: $b_track";#, $title";
                my $m_both_a = contains($title, $a_artist, $a_track);
                my $m_both_b = contains($title, $b_artist, $b_track);
                return $m_both_b <=> $m_both_a unless $m_both_a == $m_both_b;

                return $_[1] <=> $_[0];
            };
            $trackmatch = $by_listeners{(sort {$cmp->($a, $b)} keys %by_listeners)[0]};
        }
        elsif ($total == 1) {
            $trackmatch = $search_results->{results}->{trackmatches}->{track};
        }
        if (defined($trackmatch)) {
            $artist = $trackmatch->{artist};
            $track = $trackmatch->{name};
        }
        else {
            warning("No search matches");
        }
    }
    else {
        warning("No search matches");
    }
    return ($artist, $track);
}

sub update_now_playing {
    my ($self, $artist, $track) = @_;
    if ($artist and $track) {
        info("Updating now playing $track by $artist");
        my $req = $self->compose_signed_url(method => 'track.updateNowPlaying',
                           sk => $self->{session_key},
                           artist => $artist, track => $track);
        $self->make_request($URL_ROOT, 1, $req);
    }
    $self->{updated} = time;
}

sub run {
    my $self = shift;
    $self->mpd_connect unless $self->{mpd_socket};
    return unless $self->mpd_is_playing;
    return unless $self->can_connect;
    $self->handshake unless $self->{session_key};

    $self->update_current_song;
    return unless $self->{artist} and $self->{track} and $self->{started};

    if ((time - $self->{updated}) > $NOW_PLAYING_INTERVAL) {
        $self->update_now_playing($self->{artist}, $self->{track});
    }

    return if (time - $self->{started}) < $self->{minplaytime} or $self->{is_scrobbled};
    $self->scrobble($self->{artist}, $self->{track});
}

sub main {
    my $self = shift;
    my $rv = '';
    while ($self->{is_running}) {
        $rv = try {
            $self->run();
        } catch {
            error($rv);
        };
        sleep $TICK;
    }
}

sub daemonize {
    my $self = shift;
    setsid or die "setsid: $!";
    say "Starting daemon";
    my $pid = fork();
    if ($pid < 0) {
        die "fork: $!";
    }
    elsif ($pid) {
        exit 0;
    }
    chdir "/";
    umask 0;
    foreach (0 .. (POSIX::sysconf (&POSIX::_SC_OPEN_MAX) || 1024)) {
        POSIX::close $_;
    }
    open (my $pid_f, ">$PID_FILE");

    print $pid_f "$$";
    close($pid_f);

    $self->{colorize} = 0;
    open(STDIN, "</dev/null");
    open(STDOUT, ">$LOG_FILE");
    open(STDERR, ">$ERR_FILE");
    $self->main;
}

sub stop {
    my $self = shift;
    my $pid_f;
    my $is_open = open($pid_f, '<', $PID_FILE);
    if ($is_open) {
        my $pid = <$pid_f>;
        close $pid_f;
        if ($pid) {
            my $count = 0;
            my $exists = kill 0, $pid;
            say "Waiting for process: $pid, $exists";
            while ($exists) {
                $exists = kill 0, $pid;
                if ($count > 60) {
                    kill 'KILL', $pid;
                }
                else {
                    kill 'TERM', $pid;
                }
                sleep 1;
                $count ++;
            }
        }
        say "Removing pidfile";
        unlink $PID_FILE;
    }
    else {
        say "No pidfile found";
    }
}

1;
