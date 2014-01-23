package AMFM::Test;
use 5.014;
use warnings;
use lib './../lib/';
use Data::Dumper;
use AMFM;
use parent 'AMFM';

sub new {
    my $class = shift;
    my $title = shift;
    my %self = (
        title => $title,
        curl => WWW::Curl::Easy->new(),
    );
    return bless \%self, $class;
}

sub mpd_command {
    my ($self, $cmd) = @_;
    if ($cmd eq 'currentsong') {
        return "Title: $self->{title}";
     }
    else {
        die 'Unimplemented command';
    }
}

sub get_track_test {
    my $self = shift;
    my @track = $self->get_track();
    if (!defined($track[0])) {
        @track = ('', '');
    }
    return join ' <> ', @track;
}

42;
