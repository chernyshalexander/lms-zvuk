package Plugins::Zvuk::ProtocolHandler;

# Test shim: loads the real repo-root ProtocolHandler.pm by relative path
# so that `use Plugins::Zvuk::ProtocolHandler;` resolves under isolation
# tests, mirroring the existing t/lib/Plugins/Zvuk/WaveSettings.pm pattern.

use strict;
use warnings;

require File::Spec;
require Cwd;

my $real = Cwd::abs_path(File::Spec->catfile(__FILE__, '..', '..', '..', '..', '..', 'ProtocolHandler.pm'));
do $real or die "Failed to load real ProtocolHandler.pm from $real: $@$!";

1;
