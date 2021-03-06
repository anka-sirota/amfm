package AMFM::Test;
use 5.014;
use warnings;
use lib './../lib/';
use Data::Dumper;
use AMFM;
use parent 'AMFM';

sub new {
    my ($class, $title) = @_;
    my %self = (
        title => $title,
        curl => WWW::Curl::Easy->new(),
    );
    return bless \%self, $class;
}

sub get_track_test {
    my $self = shift;
    my @track = $self->parse_title($self->{title});
    if (!defined($track[0])) {
        @track = ('', '');
    }
    return join ' <> ', @track;
}

42;
