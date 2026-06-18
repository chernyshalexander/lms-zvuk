package JSON::XS::VersionOneAndTwo;

use strict;
no strict 'refs';
use warnings;
use JSON::XS;

# Minimal mock for isolation tests, mirroring the real
# JSON::XS::VersionOneAndTwo's import-time symbol injection so that
# `use JSON::XS::VersionOneAndTwo;` exports encode_json/decode_json
# (and to_json/from_json aliases) into the caller's namespace.

sub import {
    my ($exporter, @imports) = @_;
    my ($caller) = caller;

    *{ $caller . '::encode_json' } = \&JSON::XS::encode_json;
    *{ $caller . '::to_json' }     = \&JSON::XS::encode_json;
    *{ $caller . '::decode_json' } = \&JSON::XS::decode_json;
    *{ $caller . '::from_json' }   = \&JSON::XS::decode_json;
}

1;
