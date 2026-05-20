package Slim::Utils::Log;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT = qw(logger);

sub logger {
    return bless {}, 'Slim::Utils::Log';
}

sub debug {
    my ($self, $msg) = @_;
    # Suppress debug output in tests
}

1;
