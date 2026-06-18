package Plugins::Zvuk::WaveSettings;

# Test shim: loads the real repo-root WaveSettings.pm by relative path so
# that `use Plugins::Zvuk::WaveSettings;` resolves under isolation tests.

use strict;
use warnings;

require File::Spec;
require Cwd;

my $real = Cwd::abs_path(File::Spec->catfile(__FILE__, '..', '..', '..', '..', '..', 'WaveSettings.pm'));
do $real or die "Failed to load real WaveSettings.pm from $real: $@$!";

1;
