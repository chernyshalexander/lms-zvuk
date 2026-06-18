package Async;

# Test shim: loads the real repo-root API/Async.pm (package
# Plugins::Zvuk::API::Async) by relative path, mirroring the existing
# `require WaveSettings;` pattern used in t/wave_settings_test.pl.

use strict;
use warnings;

require File::Spec;
require Cwd;

my $real = Cwd::abs_path(File::Spec->catfile(__FILE__, '..', '..', '..', 'API', 'Async.pm'));
do $real or die "Failed to load real API/Async.pm from $real: $@$!";

1;
