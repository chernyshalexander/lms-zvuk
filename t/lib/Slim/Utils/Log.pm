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

sub info {
    my ($self, $msg) = @_;
    # Suppress info output in tests
}

sub warn {
    my ($self, $msg) = @_;
    # Suppress warn output in tests
}

sub error {
    my ($self, $msg) = @_;
    # Suppress error output in tests
}

sub is_debug { return 0; }

1;
