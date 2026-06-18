package Slim::Networking::SimpleAsyncHTTP;

use strict;
use warnings;

# Minimal mock for isolation tests. Real module performs async HTTP I/O;
# tests stub out the network call entirely and never invoke get()/post(),
# or they override these methods to simulate a response.

sub new {
    my ($class, $cbSuccess, $cbError, $opts) = @_;
    return bless {
        cbSuccess => $cbSuccess,
        cbError   => $cbError,
        opts      => $opts || {},
    }, $class;
}

sub get {
    my ($self, $url, %headers) = @_;
    # No-op by default; tests that need a response should mock/override.
    return;
}

sub post {
    my ($self, $url, %headers) = @_;
    return;
}

1;
