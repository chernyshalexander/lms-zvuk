#!/usr/bin/env perl
# Regression test for COMPARISON_REPORT.md P1.3: recommendations menu
# restructure. Verifies:
#  1. handleRecommendations hands the already-fetched artists/releases/
#     playlists down via passthrough to each category handler.
#  2. handleRecommendationArtists/Albums/Playlists use that passthrough
#     data instead of re-issuing getMusicRecommendations (the "4x call"
#     regression noted in COMPARISON_REPORT.md §4 P1.3).
#  3. Those handlers still fall back to a fresh API call when invoked
#     without passthrough (e.g. a deep link / bookmark).
#
# Run: perl t/test_recommendations_menu.pl
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

my $client = Test::FakeClient->new(id => 'player1');

# ---------------------------------------------------------------------
# Fake API object that records how many times getMusicRecommendations
# was actually called against the network/GraphQL layer.
# ---------------------------------------------------------------------
package Test::FakeRecommendationsAPI;
my $call_count = 0;
sub new { return bless {}, shift; }
sub getMusicRecommendations {
    my ($self, $cb, $args) = @_;
    $call_count++;
    $cb->({
        totalCount => 3,
        artists    => [{ id => 1, title => 'Artist A' }],
        releases   => [{ id => 2, title => 'Album B' }],
        playlists  => [{ id => 3, title => 'Playlist C' }],
    });
}
package main;

{
    no strict 'refs';
    no warnings 'redefine';
    local *{'Plugins::Zvuk::Plugin::_get_api_client'} = sub { return Test::FakeRecommendationsAPI->new; };

    # -------------------------------------------------------------
    # handleRecommendations must attach passthrough data per category.
    # -------------------------------------------------------------
    $call_count = 0;
    my $menu;
    Plugins::Zvuk::Plugin::handleRecommendations($client, sub { $menu = shift });

    is($call_count, 1, "handleRecommendations issues exactly one getMusicRecommendations call");

    my ($artistsItem)   = grep { $_->{url} == \&Plugins::Zvuk::Plugin::handleRecommendationArtists } @{ $menu->{items} };
    my ($albumsItem)    = grep { $_->{url} == \&Plugins::Zvuk::Plugin::handleRecommendationAlbums } @{ $menu->{items} };
    my ($playlistsItem) = grep { $_->{url} == \&Plugins::Zvuk::Plugin::handleRecommendationPlaylists } @{ $menu->{items} };

    ok(defined $artistsItem && $artistsItem->{passthrough}[0]{artists}[0]{title} eq 'Artist A',
        "Artists category item carries fetched artists via passthrough");
    ok(defined $albumsItem && $albumsItem->{passthrough}[0]{releases}[0]{title} eq 'Album B',
        "Albums category item carries fetched releases via passthrough");
    ok(defined $playlistsItem && $playlistsItem->{passthrough}[0]{playlists}[0]{title} eq 'Playlist C',
        "Playlists category item carries fetched playlists via passthrough");

    # -------------------------------------------------------------
    # Drilling into a category with passthrough must NOT re-fetch.
    # -------------------------------------------------------------
    $call_count = 0;
    my $artistsMenu;
    Plugins::Zvuk::Plugin::handleRecommendationArtists(
        $client, sub { $artistsMenu = shift }, {}, $artistsItem->{passthrough}[0]
    );
    is($call_count, 0, "handleRecommendationArtists uses passthrough without calling the API again");
    like($artistsMenu->{items}[0]{name}, qr/Artist A/, "handleRecommendationArtists renders the passed-through artist");

    # -------------------------------------------------------------
    # Without passthrough (deep link), it must still fall back to the API.
    # -------------------------------------------------------------
    $call_count = 0;
    my $fallbackMenu;
    Plugins::Zvuk::Plugin::handleRecommendationAlbums($client, sub { $fallbackMenu = shift }, {}, undef);
    is($call_count, 1, "handleRecommendationAlbums falls back to the API when no passthrough is given");
    like($fallbackMenu->{items}[0]{name}, qr/Album B/, "fallback path still renders correctly");
}

# ---------------------------------------------------------------------
# Root menu must nest Personalized Playlists + Recommendations under one
# "Рекомендации" outline instead of two separate top-level entries.
# ---------------------------------------------------------------------
{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
}

my $rootMenu;
Plugins::Zvuk::Plugin::_buildRootMenu($client, sub { $rootMenu = shift });

my ($recoOutline) = grep { ref($_->{items}) eq 'ARRAY'
    && grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::Plugin::handlePersonalizedPlaylists } @{ $_->{items} }
} @{ $rootMenu->{items} };

ok(defined $recoOutline && $recoOutline->{type} eq 'outline',
    "root menu has one outline folding in Personalized Playlists + Recommendations");
ok((grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::Plugin::handleRecommendations } @{ $recoOutline->{items} }) ? 1 : 0,
    "that outline also contains the Recommendations (dynamicBlock) link");

my @topLevelPersonalized = grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::Plugin::handlePersonalizedPlaylists } @{ $rootMenu->{items} };
is(scalar(@topLevelPersonalized), 0,
    "Personalized Playlists is no longer a separate top-level root menu entry");

done_testing();
