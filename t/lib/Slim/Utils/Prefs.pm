package Slim::Utils::Prefs;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT = qw(preferences);
our %MOCK_PREFS;

sub preferences {
    return bless {}, 'Slim::Utils::Prefs';
}

sub get {
    my ($self, $key) = @_;
    return $main::MOCK_PREFS{$key};
}

sub set {
    my ($self, $key, $value) = @_;
    $main::MOCK_PREFS{$key} = $value;
}

1;
