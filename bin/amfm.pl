#!/usr/bin/perl

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

my %STATE = (
    artist => undef,
    track => undef,
    token => undef,
    session_key => undef,
    mpd_socket => undef,
    updated => undef,
    scrobbled => 0,
    running => 1,
    colorize => 1,
);

$SIG{TERM} = $SIG{INT} = sub {
        warning("Closing connection to MPD");
        $STATE{running} = 0;
        $STATE{mpd_socket}->close() if $STATE{mpd_socket};
    };

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
        PeerHost => $MPD_HOST, 
        PeerPort => $MPD_PORT,
        Proto => 'tcp',
    ) or die "Could not create socket: $!\n";

    my $data = <$socket>;
    if (!$data) {
        info("Cannot connect to MPD");
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
        error($curl->strerror($retcode));
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
    my $token_url = compose_signed_url(method => 'auth.getToken');
    info("Requesting an auth token from Last.fm");
    $STATE{token} = make_request($URL_ROOT.'?'.$token_url)->{token};
    if (!$STATE{token}) {
        error('Cannot get token');
        die;
    }
    my $req = compose_signed_url(username => $USERNAME,
                       password => $PASSWORD,
                       method => "auth.getMobileSession",
                       token => $STATE{token});

    info("Requesting a session key from Last.fm");

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
        $song =~ s/[-_.\[\]\(\)0-9]{2,}//g;
        ($artist, $track) = split(/\s+-\s+/, $song);
        if (!($artist and $track)) {
            ($artist, $track) = split(/-/, $song);
        }
        # filter out possible garbage
        my $title = '[a-zA-Z0-9_\t\n\f\r\cK]{3,}';
        return () unless $artist and $track and $artist =~ /$title/ and $track =~ /$title/;
    }
    return ($artist, $track);
}

sub update_current_song {
    my ($artist, $track) = get_track();
    if ($artist and $track) {
        if (!defined($STATE{track}) or !($STATE{track} eq $track)
         or !defined($STATE{artist}) or !($STATE{artist} eq $artist)) {
            info("Playing $track by $artist");
            ($STATE{artist}, $STATE{track}) = ($artist, $track);
            $STATE{updated} = time;
            $STATE{scrobbled} = 0;
            update_now_playing();
        }
    }
}

sub scrobble {
    if ($STATE{artist} and $STATE{track}) {
        info("Scrobbling track $STATE{track} by $STATE{artist}");
        my $req = compose_signed_url(method => 'track.scrobble',
                           timestamp => time,
                           sk => $STATE{session_key},
                           artist => $STATE{artist}, track => $STATE{track});
        debug("$req");
        make_request($URL_ROOT, 1, $req); 
    }
    $STATE{scrobbled} = 1;
}

sub update_now_playing {
    if ($STATE{artist} and $STATE{track}) {
        info("Updating now playing $STATE{track} by $STATE{artist}");
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

    return if !$last_updated or !$STATE{artist} or $STATE{scrobbled}
              or !$STATE{track} or ((time - $STATE{updated}) < $MIN_PLAY_TIME);

    scrobble;
}

sub main {
    while ($STATE{running}) {
        run();
        sleep $TICK;
    }
}

sub daemonize {
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

    $STATE{colorize} = 0;
    open(STDIN, "</dev/null");
    open(STDOUT, ">$LOG_FILE");
    open(STDERR, ">$ERR_FILE");
    main;
}
main;
#daemonize;
