#!/usr/bin/perl

use 5.014;
use warnings;
use lib './../lib/';
use AMFM;

my $scrobbler = AMFM->new;
$SIG{TERM} = $SIG{INT} = sub { $scrobbler->quit };
$scrobbler->main;
