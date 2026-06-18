package Slim::Utils::Strings;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(string cstring);

# Minimal mock for isolation tests. Real module resolves localized phrase
# tokens from strings.txt/install.xml; tests only need a stable echo so
# assertions can match on the key itself.

sub string {
    my ($key) = @_;
    return $key;
}

sub cstring {
    my ($client, $key) = @_;
    return $key;
}

1;
