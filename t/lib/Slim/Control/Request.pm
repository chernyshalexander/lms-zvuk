package Slim::Control::Request;

use strict;
use warnings;

# Minimal mock for isolation tests. Real module implements the LMS
# request/notification bus; tests don't exercise initPlugin's
# subscribe() wiring.

sub subscribe {
    my ($cb, $notifications) = @_;
    return 1;
}

1;
