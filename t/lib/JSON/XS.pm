package JSON::XS;

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();

# Minimal mock for isolation tests. Real JSON::XS is a compiled module
# not available in this sandbox; we delegate to the pure-Perl JSON::PP
# (core module) which has a compatible encode_json/decode_json API,
# including support for \1 / \0 boolean scalar refs.

our @EXPORT = qw(encode_json decode_json);
our $VERSION = '4.03';

sub encode_json { return JSON::PP::encode_json(@_); }
sub decode_json { return JSON::PP::decode_json(@_); }

sub new { return bless {}, shift }
sub utf8        { return $_[0] }
sub canonical   { return $_[0] }
sub allow_nonref { return $_[0] }
sub pretty      { return $_[0] }

sub encode { my $self = shift; return JSON::PP::encode_json(@_); }
sub decode { my $self = shift; return JSON::PP::decode_json(@_); }

1;
