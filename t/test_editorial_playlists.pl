#!/usr/bin/env perl
# Test script for editorial playlists functionality
# This script validates that the editorial playlists methods can be loaded
# and integrated properly into the plugin structure.
#
# Run: perl t/test_editorial_playlists.pl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;

my $failures = 0;
sub ok {
    my ($cond, $desc) = @_;
    if ($cond) {
        print "ok - $desc\n";
    } else {
        print "NOT OK - $desc\n";
        $failures++;
    }
}

my $client = Test::FakeClient->new(id => 'player1');

# ---------------------------------------------------------------------
# Test 1: Verify editorial playlists handler is accessible
# ---------------------------------------------------------------------
my $can_load_editorial = defined &Plugins::Zvuk::Plugin::handleEditorialPlaylists;
ok($can_load_editorial, "handleEditorialPlaylists method exists in Plugin.pm");

# ---------------------------------------------------------------------
# Test 2: Verify editorial playlists menu item appears in root menu
# ---------------------------------------------------------------------
{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
}

my $rootMenu;
Plugins::Zvuk::Plugin::_buildRootMenu($client, sub { $rootMenu = shift });

my ($editorialItem) = grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::Plugin::handleEditorialPlaylists } @{ $rootMenu->{items} };

ok(defined $editorialItem, "Root menu contains editorial playlists link");
ok($editorialItem->{name} ne '', "Editorial playlists menu item has a name");

# ---------------------------------------------------------------------
# Test 3: Verify API methods exist
# ---------------------------------------------------------------------
{
    no strict 'refs';
    my $has_get_ids = defined &{'Plugins::Zvuk::API::Async::getEditorialPlaylistIds'};
    my $has_get_metadata = defined &{'Plugins::Zvuk::API::Async::getEditorialPlaylistMetadata'};
    
    ok($has_get_ids, "getEditorialPlaylistIds method exists in API::Async");
    ok($has_get_metadata, "getEditorialPlaylistMetadata method exists in API::Async");
}

# ---------------------------------------------------------------------
# Test 4: Verify rendering function exists
# ---------------------------------------------------------------------
{
    no strict 'refs';
    my $has_render = defined &{'Plugins::Zvuk::Plugin::_renderEditorialPlaylist'};
    ok($has_render, "_renderEditorialPlaylist rendering helper exists");
}

# ---------------------------------------------------------------------
# Summary and manual testing checklist
# ---------------------------------------------------------------------
print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");

print "\nManual testing checklist:\n";
print "1. Start LMS and navigate to Plugins → Zvuk\n";
print "2. Verify 'Подборки' menu item appears\n";
print "3. Click 'Подборки' and verify playlist list loads\n";
print "4. Click individual playlist and verify tracks display\n";
print "5. Test error handling with invalid token\n";
print "6. Verify menu appears in different UI skins (Default, Material)\n";

exit($failures ? 1 : 0);
