use 5.014;
use warnings;
use IO::Socket::INET;
use Data::Dumper;
use URI::Escape;
use POSIX qw/strftime/;
use WWW::Curl::Easy qw/CURLOPT_HEADER CURLOPT_URL CURLOPT_TIMEOUT CURLOPT_HTTPHEADER CURLOPT_WRITEDATA CURLOPT_POSTFIELDS CURLOPT_POST/;
use JSON qw/from_json/;
use Digest::MD5 qw/md5_hex/;
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

sub sign_url {
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
    my $token_url = sign_url(method => 'auth.getToken');
    my $auth_token = make_request($URL_ROOT.'?'.$token_url)->{token};
    if (!$auth_token) {
        die 'Cannot get token';
    }
    $STATE{token} = $auth_token;
    my $req = sign_url(username => $SETTINGS{username},
                       password => $SETTINGS{password},
                       method => "auth.getMobileSession",
                       token => $auth_token);

    warn "[INFO]\tConnecting to Last.fm...";

    my $session_key = make_request($URL_ROOT, 1, $req)->{session}->{key};
    $STATE{session_key} = $session_key;
    return $session_key;
}

sub mpd_is_playing {
    my %status = split(/:\s|\n/, mpd_command("status"));
    return ($status{state} =~ /play/) ? 1 : 0;
}

sub update_current_song {
    my $song = mpd_command('currentsong');
    if ($song =~ /Title:\s+(.+)$/m) {
        warn "[INFO]\t Playing $1";
        my $old_song = $STATE{title};
        $STATE{title} = $1;
        ($STATE{artist}, $STATE{track}) = split(/\s+-\s+/, $1);
        if (!defined($old_song) or !($1 eq $old_song)) {
            $STATE{updated} = time;
            $STATE{scrobbled} = 0;
            update_now_playing();
        }
    }
}

sub scrobble {
    if ($STATE{artist} and $STATE{track}) {
        warn "[INFO]\tScrobbling track $STATE{artist} - $STATE{track}";
        my $req = sign_url(method => 'track.scrobble',
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
        my $req = sign_url(method => 'track.updateNowPlaying',
                           sk => $STATE{session_key},
                           artist => $STATE{artist}, track => $STATE{track});
        warn "[INFO]\tUpdating now playing $STATE{artist} - $STATE{track}";
        make_request($URL_ROOT, 1, $req);
    }
}

sub run {
    handshake unless $STATE{session_key};
    mpd_connect unless $STATE{mpd_socket};
    return unless mpd_is_playing();

    my $old_title = $STATE{title};
    my $last_updated = $STATE{updated};
    my ($artist, $track) = update_current_song;

    if ($last_updated and $STATE{title}) {
        say time - $STATE{updated};
    }
    return if !$last_updated or !$STATE{title} or $STATE{scrobbled}
              or ((time - $STATE{updated}) < $MIN_PLAY_TIME);

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
