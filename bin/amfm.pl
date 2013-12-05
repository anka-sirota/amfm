use 5.014;
use warnings;
use Data::Dumper;
use Digest::MD5 qw/md5_hex/;
use IO::Socket::INET;
use JSON qw/from_json/;
use POSIX qw/strftime/;
use URI::Escape;
use WWW::Curl::Easy qw/CURLOPT_HEADER CURLOPT_URL CURLOPT_TIMEOUT CURLOPT_HTTPHEADER CURLOPT_WRITEDATA CURLOPT_POSTFIELDS CURLOPT_POST/;
$| = 1;

my %SETTINGS = (
    username => $ENV{LASTFM_USERNAME},
    password => $ENV{LASTFM_PASSWORD},
    mpd_host => $ENV{MPD_HOST} || "localhost",
    mpd_port => $ENV{MPD_PORT} || "6600",
    autosubmit => 0,
    date_format => "%a %b %e %H:%M:%S %Y",
);

my $TICK = 5;
my $MIN_PLAY_TIME = 30;
my $API_KEY = "7c04baa41513c100f7544a329ac97638";
my $SECRET = "c1e017252469c6387459e6e7b51d6f53";
my $URL_ROOT = "https://ws.audioscrobbler.com/2.0/";

my %STATE = (
    artist => undef,
    track => undef,
    token => undef,
    session_key => undef,
    mpd_socket => undef,
    updated => undef,
    scrobbled => 0,
    running => 1,
);

my $curl = WWW::Curl::Easy->new();

sub compose_signed_url {
    my %params = @_;
    $params{api_key} = $API_KEY;
    $params{format} = 'json';
    my $sign = (join '', map {(!($_ eq 'format' or $_ eq 'callback')) ? $_.$params{$_} : ''} sort keys %params).$SECRET;
    my $res = join('&', (map {$_."=".$params{$_}} keys %params), "api_sig=".md5_hex($sign));
    return $res;
};

sub mpd_connect {
    my $socket = IO::Socket::INET->new(
        PeerHost => $SETTINGS{mpd_host}, 
        PeerPort => $SETTINGS{mpd_port},
        Proto => 'tcp',
    ) or die "Could not create socket: $!\n";

    my $data = <$socket>;
    if (!$data) {
        warn "Cannot connect to MPD";
        return;
    }
    $STATE{mpd_socket} = $socket;
    return $socket;
}

sub mpd_command {
    my $cmd = shift;
    my $socket = $STATE{mpd_socket};
    $socket->send("$cmd\r\n");
    my $res = do { local $/ = "OK\n"; <$socket>};
    $res =~ s/\nOK\n//g;
    return $res;
}

sub make_request {
    my ($url, $post, $body) = @_;
    my $response;

    $curl->setopt(WWW::Curl::Easy::CURLOPT_URL, $url);
    if ($post) {
        $curl->setopt(WWW::Curl::Easy::CURLOPT_POST, 1);
        if ($body) {
            $curl->setopt(WWW::Curl::Easy::CURLOPT_POSTFIELDS, $body);
        }
    }
    $curl->setopt(WWW::Curl::Easy::CURLOPT_WRITEDATA, \$response);

    my $retcode = $curl->perform();
    if ($retcode > 0) {
        warn $curl->strerror($retcode);
        return '';
    }
    return (defined($response)) ? from_json($response) : {token => undef};
}

sub handshake {
    my $token_url = compose_signed_url(method => 'auth.getToken');
    warn "[INFO]\tRequesting an auth token from Last.fm";
    $STATE{token} = make_request($URL_ROOT.'?'.$token_url)->{token};
    if (!$STATE{token}) {
        die 'Cannot get token';
    }
    my $req = compose_signed_url(username => $SETTINGS{username},
                       password => $SETTINGS{password},
                       method => "auth.getMobileSession",
                       token => $STATE{token});

    warn "[INFO]\tRequesting a session key from Last.fm";

    $STATE{session_key} = make_request($URL_ROOT, 1, $req)->{session}->{key};
    if (!$STATE{session_key}) {
        @STATE{('session_key', 'token')} = ();
    }
    return $STATE{session_key};
}

sub mpd_is_playing {
    my %status = split(/:\s|\n/, mpd_command("status"));
    return ($status{state} =~ /play/) ? 1 : 0;
}

sub get_track {
    my $song = mpd_command('currentsong');
    my ($artist, $track) = ();
    if ($song =~ /Title:\s+(.+)$/m) {
        $song = $1;
        # trying to remove track numbers
        $song =~ s/[.\[\]\(\)0-9_]{2,}//g;
        ($artist, $track) = split(/\s+-\s+/, $song);
        if (!($artist and $track)) {
            ($artist, $track) = split(/-/, $song);
        }
    }
    return ($artist, $track);
}

sub update_current_song {
    my ($artist, $track) = get_track();
    if ($artist and $track) {
        warn "[INFO]\t Playing $track by $artist";
        if (!defined($STATE{track}) or !($STATE{track} eq $track)
         or !defined($STATE{artist}) or !($STATE{artist} eq $artist)) {
            ($STATE{artist}, $STATE{track}) = ($artist, $track);
            $STATE{updated} = time;
            $STATE{scrobbled} = 0;
            update_now_playing();
        }
    }
}

sub scrobble {
    if ($STATE{artist} and $STATE{track}) {
        warn "[INFO]\tScrobbling track $STATE{artist} - $STATE{track}";
        my $req = compose_signed_url(method => 'track.scrobble',
                           timestamp => time,
                           sk => $STATE{session_key},
                           artist => $STATE{artist}, track => $STATE{track});
        say $req;
        make_request($URL_ROOT, 1, $req); 
    }
    $STATE{scrobbled} = 1;
}

sub update_now_playing {
    if ($STATE{artist} and $STATE{track}) {
        warn "[INFO]\tUpdating now playing $STATE{artist} - $STATE{track}";
        my $req = compose_signed_url(method => 'track.updateNowPlaying',
                           sk => $STATE{session_key},
                           artist => $STATE{artist}, track => $STATE{track});
        make_request($URL_ROOT, 1, $req);
    }
}

sub run {
    handshake unless $STATE{session_key};
    mpd_connect unless $STATE{mpd_socket};
    return unless mpd_is_playing();

    my $last_updated = $STATE{updated};
    my ($artist, $track) = update_current_song;

    if ($last_updated) {
        say time - $STATE{updated};
    }
    return if !$last_updated or !$STATE{artist} or $STATE{scrobbled}
              or !$STATE{track} or ((time - $STATE{updated}) < $MIN_PLAY_TIME);

    scrobble;
}

$SIG{'INT'} = sub {
        warn "Closing connection to MPD";
        $STATE{running} = 0;
        $STATE{mpd_socket}->close() if $STATE{mpd_socket};
    };

while ($STATE{running}) {
    run();
    sleep $TICK;
}
