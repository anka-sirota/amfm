#!/usr/bin/perl

use 5.014;
use warnings;
use lib './../lib/';
use AMFM;
my $cmd = shift(@ARGV);

my $scrobbler = AMFM->new;
$SIG{TERM} = $SIG{INT} = sub { $scrobbler->quit };

given ($cmd) {
    when("--start") {
        $scrobbler->daemonize;
    }
    when("--stop") {
        $scrobbler->stop;
    }
    when("--restart") {
        $scrobbler->stop;
        $scrobbler->daemonize;
    }
}
