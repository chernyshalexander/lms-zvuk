package Slim::Plugin::OPMLBased;

use strict;
use warnings;

# Minimal mock for isolation tests. Real module wires OPML feed handlers
# into the LMS menu/CLI system; tests only need Plugin.pm to load and to
# call SUPER::initPlugin without exercising real server internals.

sub initPlugin {
    my $class = shift;
    return 1;
}

1;
