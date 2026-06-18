package Plugins::Zvuk::API::Async;

# Test shim: loads the real repo-root API/Async.pm by relative path so
# that `use Plugins::Zvuk::API::Async;` resolves under isolation tests,
# mirroring the existing t/lib/Plugins/Zvuk/WaveSettings.pm pattern.

use strict;
use warnings;

require File::Spec;
require Cwd;

my $real = Cwd::abs_path(File::Spec->catfile(__FILE__, '..', '..', '..', '..', '..', '..', 'API', 'Async.pm'));
do $real or die "Failed to load real API/Async.pm from $real: $@$!";

1;
