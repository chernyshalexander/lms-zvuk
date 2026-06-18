package Slim::Web::Pages;

use strict;
use warnings;

# Minimal mock for isolation tests. Real module registers raw HTTP routes
# for the web UI; tests don't exercise initPlugin's web-route wiring.

sub addRawFunction {
    my ($class, $path, $handler) = @_;
    return 1;
}

1;
