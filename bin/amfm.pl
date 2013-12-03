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
    mpd_host => "localhost",
    mpd_port => "6600",
    autosubmit => 0,
    date_format => "%a %b %e %H:%M:%S %Y",
    token => undef,
    session_key => undef,
    mpd_socket => undef,
);

my $min_play_time = 30;
my $API_KEY = "7c04baa41513c100f7544a329ac97638";
my $secret = "c1e017252469c6387459e6e7b51d6f53";
my $URL_ROOT = "https://ws.audioscrobbler.com/2.0/";
my $curl = WWW::Curl::Easy->new();

sub sign_url {
    my %params = @_;
    $params{api_key} = $API_KEY;
    $params{format} = 'json';
    my $sign = (join '', map {(!($_ eq 'format' or $_ eq 'callback')) ? $_.$params{$_} : ''} sort keys %params).$secret;
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
    $SETTINGS{mpd_socket} = $socket;
    return $socket;
}

sub mpd_command {
    my $cmd = shift;
    my $socket = $SETTINGS{mpd_socket};
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
    return from_json($response);
}

sub handshake {
    my $token_url = sign_url(method => 'auth.getToken');
    my $auth_token = make_request($URL_ROOT.'?'.$token_url)->{token};
    if (!$auth_token) {
        die 'Cannot get token';
    }
    my $req = sign_url(username => $SETTINGS{username},
                       password => $SETTINGS{password},
                       method => "auth.getMobileSession",
                       token => $auth_token);

    warn "[INFO]\tConnecting to Last.fm...";

    my $session_key = make_request($URL_ROOT, 1, $req)->{session}->{key};
    $SETTINGS{session_key} = $session_key;
    return $session_key;
}

while (!$SETTINGS{session_key}) {
    handshake();
    sleep 1;
}

sub mpd_is_playing {
    my %status = split(/:\s|\n/, mpd_command("status"));
    return ($status{state} =~ /play/) ? 1 : 0;
}

sub update_now_playing {
    if (mpd_is_playing) {
        my $song = mpd_command('currentsong');
        if ($song =~ /Title:\s+(.+)$/m) {
            my ($artist, $track) = split(/\s+-\s+/, $1);
            #my ($artist, $track) = ($1, $2);
            my $req = sign_url(method => 'track.updateNowPlaying',
                               sk => $SETTINGS{session_key},
                               artist => $artist, track => $track);
            warn "[INFO]\tUpdating now playing..";
            my $session_key = make_request($URL_ROOT, 1, $req)->{session}->{key};
        }
    }
}
my $mpd_socket = mpd_connect();
update_now_playing();
$mpd_socket->close();
