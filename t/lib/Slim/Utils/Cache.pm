package Slim::Utils::Cache;

use strict;
use warnings;
use Exporter qw(import);

# Minimal in-memory cache mock used in isolation tests.
# Real Slim::Utils::Cache persists to disk; tests only need get/set semantics.

my %store;

sub new {
    return bless {}, 'Slim::Utils::Cache';
}

sub get {
    my ($self, $key) = @_;
    return $store{$key};
}

sub set {
    my ($self, $key, $value, $ttl) = @_;
    $store{$key} = $value;
    return 1;
}

sub remove {
    my ($self, $key) = @_;
    delete $store{$key};
}

sub clear {
    %store = ();
}

1;
