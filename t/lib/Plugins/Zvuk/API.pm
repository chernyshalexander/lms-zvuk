package Plugins::Zvuk::API;

# Test shim: loads the real repo-root API.pm by relative path so that
# `use Plugins::Zvuk::API;` resolves under isolation tests without
# requiring the plugin to be installed into a real LMS @INC layout.

use strict;
use warnings;

require File::Spec;
require Cwd;

my $real = Cwd::abs_path(File::Spec->catfile(__FILE__, '..', '..', '..', '..', '..', 'API.pm'));
do $real or die "Failed to load real API.pm from $real: $@$!";

1;
