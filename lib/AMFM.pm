package AMFM;

use 5.014;
use warnings;
use lib './../lib/';
use Data::Dumper;
use Digest::MD5 qw/md5_hex/;
use IO::Socket::INET;
use Logger qw/error debug warning info/;
use JSON qw/from_json/;
use POSIX qw/strftime setsid/;
use URI::Escape;
use WWW::Curl::Easy qw/CURLOPT_HEADER CURLOPT_URL CURLOPT_TIMEOUT CURLOPT_HTTPHEADER CURLOPT_WRITEDATA CURLOPT_POSTFIELDS CURLOPT_POST/;
use Exporter 'import';
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
my $API_KEY = "7c04baa41513c100f7544a329ac97638";
my $SECRET = "c1e017252469c6387459e6e7b51d6f53";
my $URL_ROOT = "https://ws.audioscrobbler.com/2.0/";

sub new {
    my $class = shift;
    my %self = (
        artist => undef,
        track => undef,
        token => undef,
        session_key => undef,
        mpd_socket => undef,
        updated => undef,
        scrobbled => 0,
        running => 1,
        colorize => 1,
        curl => WWW::Curl::Easy->new(),
    );
    return bless \%self, $class;
}
sub quit {
    my $self = shift;
    warning("Closing connection to MPD");
    $self->{running} = 0;
    $self->{mpd_socket}->close() if $self->{mpd_socket};
}

sub compose_signed_url {
    my $self = shift;
    my %params = @_;
    $params{api_key} = $API_KEY;
    $params{format} = 'json';
    my $sign = (join '', map {(!($_ eq 'format' or $_ eq 'callback')) ? $_.$params{$_} : ''} sort keys %params).$SECRET;
    my $res = join('&', (map {$_."=".uri_escape($params{$_})} keys %params), "api_sig=".md5_hex($sign));
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
    $res =~ s/\nOK\n//g;
    return $res;
}

sub make_request {
    my $self = shift;
    my ($url, $post, $body) = @_;
    my $response;

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
    my $json = {};
    if ($response) {
        $json = from_json($response);
        #say Dumper \ $json;
        if ($json->{error}) {
            error($json->{info});
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
    return ($status{state} =~ /play/) ? 1 : 0;
}

sub get_track {
    my $self = shift;
    my $song = $self->mpd_command('currentsong');
    my ($artist, $track) = ();
    if ($song =~ /Title:\s+(.+)$/m) {
        $song = $1;
        # trying to remove track numbers
        $song =~ s/[-_.\[\]\(\)0-9]{2,}//g;
        $song =~ s/^(?:-|\s)+//g;
        $song =~ s/(?:-|\s)+$//g;
        ($artist, $track) = split(/(?:-|\s-|-\s)+/, $song);
        if ($artist and $track) {
            $artist =~ s/_/ /g;
            $track =~ s/_/ /g;
        }
        # filter out possible garbage
        my $title = '[a-zA-Z0-9_\t\n\f\r\cK]{3,}';
        return () unless $artist and $track and $artist =~ /$title/ and $track =~ /$title/;
    }
    return ($artist, $track);
}

sub update_current_song {
    my $self = shift;
    my ($artist, $track) = $self->get_track();
    if ($artist and $track) {
        if (!defined($self->{track}) or !($self->{track} eq $track)
         or !defined($self->{artist}) or !($self->{artist} eq $artist)) {
            info("Playing $track by $artist");
            ($self->{artist}, $self->{track}) = ($artist, $track);
            $self->{updated} = time;
            $self->{scrobbled} = 0;
            $self->update_now_playing;
        }
    }
}

sub scrobble {
    my $self = shift;
    if ($self->{artist} and $self->{track}) {
        info("Scrobbling track $self->{track} by $self->{artist}");
        my $req = $self->compose_signed_url(method => 'track.scrobble',
                           timestamp => time,
                           sk => $self->{session_key},
                           artist => $self->{artist}, track => $self->{track});
        debug("$req");
        $self->make_request($URL_ROOT, 1, $req); 
    }
    $self->{scrobbled} = 1;
}

sub update_now_playing {
    my $self = shift;
    if ($self->{artist} and $self->{track}) {
        info("Updating now playing $self->{track} by $self->{artist}");
        my $req = $self->compose_signed_url(method => 'track.updateNowPlaying',
                           sk => $self->{session_key},
                           artist => $self->{artist}, track => $self->{track});
        $self->make_request($URL_ROOT, 1, $req);
    }
}

sub run {
    my $self = shift;
    $self->handshake unless $self->{session_key};
    $self->mpd_connect unless $self->{mpd_socket};
    return unless $self->mpd_is_playing();

    my $last_updated = $self->{updated};
    my ($artist, $track) = $self->update_current_song;

    return if !$last_updated or !$self->{artist} or $self->{scrobbled}
              or !$self->{track} or ((time - $self->{updated}) < $MIN_PLAY_TIME);

    $self->scrobble;
}

sub main {
    my $self = shift;
    while ($self->{running}) {
        $self->run();
        sleep $TICK;
    }
}

sub daemonize {
    my $self = shift;
    setsid or die "setsid: $!";
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
    open (my $pid_f, ">>$PID_FILE");

    print $pid_f "$$";
    close($pid_f);

    $self->{colorize} = 0;
    open(STDIN, "</dev/null");
    open(STDOUT, ">$LOG_FILE");
    open(STDERR, ">$ERR_FILE");
    main;
}

1;
