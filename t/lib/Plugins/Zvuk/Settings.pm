package Plugins::Zvuk::Settings;

# Test shim: loads the real repo-root Settings.pm by relative path so
# that `use Plugins::Zvuk::Settings;` resolves under isolation tests,
# mirroring the existing t/lib/Plugins/Zvuk/WaveSettings.pm pattern.

use strict;
use warnings;

require File::Spec;
require Cwd;

my $real = Cwd::abs_path(File::Spec->catfile(__FILE__, '..', '..', '..', '..', '..', 'Settings.pm'));
do $real or die "Failed to load real Settings.pm from $real: $@$!";

1;
