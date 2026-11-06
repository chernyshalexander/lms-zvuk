#!/usr/bin/env perl
# Test script verifying genre menu nextWindow behavior for VFD button players (e.g. Squeezebox Boom)
# vs Jive/Web clients.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::UI::Wave;
require Plugins::Zvuk::WaveSettings;

my $client = Test::FakeClient->new(id => 'boom_player_1');

# Test 1: isButton => 1 (Hardware VFD player button input, e.g. Squeezebox Boom)
{
    my $menu;
    Plugins::Zvuk::UI::Wave::handleGenresMenu($client, sub { $menu = shift }, { isButton => 1 });

    ok(ref $menu eq 'HASH' && ref $menu->{items} eq 'ARRAY', "handleGenresMenu returns menu hash for button player");

    my @familyItems = grep { $_->{passthrough} && $_->{passthrough}[0]{family} } @{ $menu->{items} };
    ok(scalar(@familyItems) > 0, "family items exist in the first menu level");

    my $hasNextWindowRefresh = grep { ($_->{nextWindow} // '') eq 'refresh' } @familyItems;
    ok(!$hasNextWindowRefresh, "family items for button player (isButton=1) do NOT contain nextWindow => 'refresh' (prevents Slim::Buttons mode pop crash)");

    # second level (genres of one family) must follow the same rule
    my $familyMenu;
    Plugins::Zvuk::UI::Wave::handleGenreFamily($client, sub { $familyMenu = shift }, { isButton => 1 },
        { family => $familyItems[0]{passthrough}[0]{family} });
    my @genreItems = grep { $_->{passthrough} && $_->{passthrough}[0]{genre} } @{ $familyMenu->{items} };
    ok(scalar(@genreItems) > 0, "genre items exist in the second menu level");
    ok(!(grep { ($_->{nextWindow} // '') eq 'refresh' } @genreItems),
        "genre items for button player also omit nextWindow => 'refresh'");
}

# Test 2: Standard/Web/Jive client (isButton is false)
{
    my $menu;
    Plugins::Zvuk::UI::Wave::handleGenresMenu($client, sub { $menu = shift }, {});

    my @familyItems = grep { $_->{passthrough} && $_->{passthrough}[0]{family} } @{ $menu->{items} };
    # Navigation items must NOT carry nextWindow => 'refresh': on Jive/SqueezePlay
    # that makes the client re-request the current window instead of opening the
    # returned child feed, so tapping a family appeared to do nothing.
    my $anyRefresh = grep { ($_->{nextWindow} // '') eq 'refresh' } @familyItems;
    ok(!$anyRefresh, "family items never set nextWindow => 'refresh' (they navigate into the family)");

    my $familyMenu;
    Plugins::Zvuk::UI::Wave::handleGenreFamily($client, sub { $familyMenu = shift }, {},
        { family => $familyItems[0]{passthrough}[0]{family} });
    my @genreItems = grep { $_->{passthrough} && $_->{passthrough}[0]{genre} } @{ $familyMenu->{items} };
    my $allGenresRefresh = (grep { ($_->{nextWindow} // '') eq 'refresh' } @genreItems) == scalar(@genreItems);
    ok($allGenresRefresh, "genre items for non-button UI retain nextWindow => 'refresh'");
}

# Test 3: Toggle genre on button player via handleGenreToggle
{
    my $familiesMenu;
    Plugins::Zvuk::UI::Wave::handleGenresMenu($client, sub { $familiesMenu = shift }, { isButton => 1 });
    my ($firstFamily) = grep { $_->{passthrough} && $_->{passthrough}[0]{family} } @{ $familiesMenu->{items} };
    my $familyId = $firstFamily->{passthrough}[0]{family};

    my $menuBefore;
    Plugins::Zvuk::UI::Wave::handleGenreFamily($client, sub { $menuBefore = shift }, { isButton => 1 },
        { family => $familyId });
    my ($firstItem) = grep { $_->{passthrough} && $_->{passthrough}[0]{genre} } @{ $menuBefore->{items} };
    my $genreName = $firstItem->{passthrough}[0]{genre};

    my $menuAfter;
    Plugins::Zvuk::UI::Wave::handleGenreToggle($client, sub { $menuAfter = shift }, { isButton => 1 },
        { genre => $genreName, family => $familyId });

    ok(ref $menuAfter eq 'HASH', "handleGenreToggle callback returns updated menu");
    my ($toggledItem) = grep { $_->{passthrough} && $_->{passthrough}[0]{genre} eq $genreName } @{ $menuAfter->{items} };
    like($toggledItem->{name}, qr/\[x\]/, "toggled genre item display updated to checked [x]");
    ok(!exists $toggledItem->{nextWindow} || $toggledItem->{nextWindow} ne 'refresh', "refreshed genre item for button player still omits nextWindow => 'refresh'");

    # Toggle back
    Plugins::Zvuk::UI::Wave::handleGenreToggle($client, sub { $menuAfter = shift }, { isButton => 1 },
        { genre => $genreName, family => $familyId });
    ($toggledItem) = grep { $_->{passthrough} && $_->{passthrough}[0]{genre} eq $genreName } @{ $menuAfter->{items} };
    like($toggledItem->{name}, qr/\[ \]/, "toggled back genre item display updated to unchecked [ ]");
}

# Test 4: Start Wave menu item behavior for VFD button player vs standard UI
{
    my $waveItemsButton = Plugins::Zvuk::UI::Wave::_getWaveMenuItems($client, { isButton => 1 });
    my ($startItemButton) = grep { $_->{play} && $_->{play} eq 'zvuk://wave' } @$waveItemsButton;

    is(ref $startItemButton->{url}, 'CODE', "Start Wave menu item on button player uses CODE ref for url (enables rotary knob press playback)");

    # Test handleStartWave execution and button mode stack cleanup
    my @executedCmds;
    {
        no warnings 'once', 'redefine';
        local *Test::FakeClient::execute = sub {
            my ($self, $cmd) = @_;
            push @executedCmds, $cmd;
        };

        my @modeStack = ('xmlbrowser'); # Simulate temporary xmlbrowser mode pushed by onRight
        local *Slim::Buttons::Common::mode = sub { return $modeStack[-1]; };
        local *Slim::Buttons::Common::popMode = sub { return pop @modeStack; };
        local *Slim::Buttons::Common::pushModeLeft = sub { my ($c, $m) = @_; push @modeStack, $m; };

        Plugins::Zvuk::UI::Wave::handleStartWave($client, sub {}, { isButton => 1 });

        is(scalar(@executedCmds), 1, "handleStartWave executes playlist play command");
        is_deeply($executedCmds[0], ['playlist', 'play', 'zvuk://wave', 'PLUGIN_ZVUK_MENU_WAVE_START'], "executed command is 'playlist play zvuk://wave'");
        is($modeStack[-1], 'playlist', "mode stack cleanly ends in playlist mode");
        is(scalar(@modeStack), 1, "temporary xmlbrowser mode was popped before pushing playlist mode (prevents empty screen & stack underflow)");
    }

    my $waveItemsWeb = Plugins::Zvuk::UI::Wave::_getWaveMenuItems($client, {});
    my ($startItemWeb) = grep { $_->{play} && $_->{play} eq 'zvuk://wave' } @$waveItemsWeb;
    ok(!ref $startItemWeb->{url}, "Start Wave menu item on non-button UI retains scalar url 'zvuk://wave'");
}

done_testing();
