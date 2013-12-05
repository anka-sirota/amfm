package Logger; 

use 5.014;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw/debug error warning info/;

my %COLORS = (
    black => 30,
    red => 31,
    green => 32,
    yellow => 33,
    blue => 34,
    magenta => 35,
    cyan => 36,
    white => 37,
);

my %COLOR_LEVEL = (
    INFO => 'green',
    WARN => 'magenta',
    ERROR => 'red',
    DEBUG => 'yellow',
);

sub colorize {
    my ($level, $message) = @_;

    if ($level =~ /ERROR|DEBUG/ && -t STDERR || $level =~ /INFO|WARN/ && -t STDOUT) {
        my $color = $COLORS{$COLOR_LEVEL{$level}};
        return "\033[".$color."m[$level]\033[0m\t".$message;
    }
    return "[$level] $message";
}

sub log_message {
    my $level = shift;
    if ($level =~ /ERROR|DEBUG/) {
        warn colorize($level, join(' ', @_));
    }
    elsif ($level =~ /INFO|WARN/) {
        say colorize($level, join(' ', @_));
    }
}

sub info {
    log_message('INFO', @_);
}

sub error {
    log_message('ERROR', @_);
}

sub warning {
    log_message('WARN', @_);
}

sub debug {
    log_message('DEBUG', @_);
}

1;