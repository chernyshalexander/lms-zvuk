package Slim::Player::Protocols::HTTPS;

use strict;
use warnings;

# Minimal mock for isolation tests. Real module implements the HTTPS
# streaming protocol handler base class; ProtocolHandler.pm only needs
# this to exist as a base class to load successfully.

1;
