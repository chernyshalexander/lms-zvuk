#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
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
require Plugins::Zvuk::UI::InfoMenu;
require Plugins::Zvuk::API::Async;

# -------------------------------------------------------------------
# Setup test client and account
# -------------------------------------------------------------------
my $client = Test::FakeClient->new(id => 'player1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
}

# -------------------------------------------------------------------
# Test 1: trackInfoMenu contains Like and Dislike for Zvuk tracks
# -------------------------------------------------------------------
my $menu = Plugins::Zvuk::UI::InfoMenu::trackInfoMenu(
	$client,
	'zvuk://12345',
	undef,
	{ track => 'Test Song', artist => 'Test Artist', artist_id => 201, album => 'Test Album', release_id => 301 }
);

ok($menu, 'trackInfoMenu returned a menu');
is($menu->{name}, 'PLUGIN_ZVUK_ON_ZVUK', 'Menu name is PLUGIN_ZVUK_ON_ZVUK');
my $items = $menu->{items};
ok($items && @$items, 'trackInfoMenu has items');

# Find like and dislike items
my ($like_item)    = grep { $_->{name} eq 'PLUGIN_ZVUK_LIKE_TRACK' } @$items;
my ($dislike_item) = grep { $_->{name} eq 'PLUGIN_ZVUK_DISLIKE_TRACK' } @$items;

ok($like_item, 'PLUGIN_ZVUK_LIKE_TRACK item exists in menu');
is($like_item->{type}, 'link', 'Like item has type => link');
is(ref($like_item->{url}), 'CODE', 'Like item URL is a CODE ref');
is($like_item->{passthrough}[1], '12345', 'Like item passes track ID in passthrough');
is($like_item->{passthrough}[2], 0, 'Like item is not episode');

ok($dislike_item, 'PLUGIN_ZVUK_DISLIKE_TRACK item exists in menu');
is($dislike_item->{type}, 'link', 'Dislike item has type => link');
is(ref($dislike_item->{url}), 'CODE', 'Dislike item URL is a CODE ref');
is($dislike_item->{passthrough}[1], '12345', 'Dislike item passes track ID in passthrough');
is($dislike_item->{passthrough}[2], 0, 'Dislike item is not episode');

# -------------------------------------------------------------------
# Test 2: Non-Zvuk tracks do NOT contain Like and Dislike items
# -------------------------------------------------------------------
my $non_zvuk_menu = Plugins::Zvuk::UI::InfoMenu::trackInfoMenu(
	$client,
	'file:///music/song.mp3',
	undef,
	{ track => 'Local Song', artist => 'Local Artist' }
);
ok($non_zvuk_menu, 'trackInfoMenu returned menu for local track');
my ($local_like)    = grep { $_->{name} eq 'PLUGIN_ZVUK_LIKE_TRACK' } @{ $non_zvuk_menu->{items} || [] };
my ($local_dislike) = grep { $_->{name} eq 'PLUGIN_ZVUK_DISLIKE_TRACK' } @{ $non_zvuk_menu->{items} || [] };
ok(!$local_like, 'Non-Zvuk track does not have Like item');
ok(!$local_dislike, 'Non-Zvuk track does not have Dislike item');

# -------------------------------------------------------------------
# Test 3: Like track dispatches GraphQL addItemToCollection mutation
# -------------------------------------------------------------------
my $async = Plugins::Zvuk::API::Async->new({ userId => 'acctA' });
my $last_gql;

no warnings 'redefine';
local *Plugins::Zvuk::API::Async::_graphql = sub {
	my ($self, $cb, $op, $gql, $vars) = @_;
	$last_gql = { op => $op, gql => $gql, vars => $vars };
	$cb->({ data => { collection => { addItem => 1 } } });
};
use warnings 'redefine';

my $like_result;
Plugins::Zvuk::UI::InfoMenu::_doLikeTrack(
	$client,
	sub { $like_result = shift; },
	{},
	$async,
	'12345',
	0
);

ok($like_result, '_doLikeTrack completed callback');
is($like_result->{items}[0]{name}, 'PLUGIN_ZVUK_DONE', '_doLikeTrack returns PLUGIN_ZVUK_DONE on success');
is($like_result->{items}[0]{type}, 'text', 'Result item is type text');
is($last_gql->{op}, 'addItemToCollection', 'likeTrack op name is addItemToCollection');
like($last_gql->{gql}, qr/collection\s*\{\s*addItem\(id:\s*\$id,\s*type:\s*\$type\)/, 'likeTrack GQL mutation uses collection.addItem');
is($last_gql->{vars}{id}, '12345', 'likeTrack passes track ID');
is($last_gql->{vars}{type}, 'track', 'likeTrack passes type track');

# -------------------------------------------------------------------
# Test 4: Unlike track dispatches GraphQL removeItemFromCollection mutation
# -------------------------------------------------------------------
my $unlike_result;
Plugins::Zvuk::UI::InfoMenu::_doUnlikeTrack(
	$client,
	sub { $unlike_result = shift; },
	{},
	$async,
	'12345',
	0
);

ok($unlike_result, '_doUnlikeTrack completed callback');
is($unlike_result->{items}[0]{name}, 'PLUGIN_ZVUK_DONE', '_doUnlikeTrack returns PLUGIN_ZVUK_DONE on success');
is($last_gql->{op}, 'removeItemFromCollection', 'unlikeTrack op name is removeItemFromCollection');
like($last_gql->{gql}, qr/collection\s*\{\s*removeItem\(id:\s*\$id,\s*type:\s*\$type\)/, 'unlikeTrack GQL mutation uses collection.removeItem');
is($last_gql->{vars}{id}, '12345', 'unlikeTrack passes track ID');
is($last_gql->{vars}{type}, 'track', 'unlikeTrack passes type track');

# -------------------------------------------------------------------
# Test 5: _doDislikeTrack alias dispatches identically to unlikeTrack
# -------------------------------------------------------------------
my $dislike_result;
Plugins::Zvuk::UI::InfoMenu::_doDislikeTrack(
	$client,
	sub { $dislike_result = shift; },
	{},
	$async,
	'12345',
	0
);

ok($dislike_result, '_doDislikeTrack completed callback');
is($dislike_result->{items}[0]{name}, 'PLUGIN_ZVUK_DONE', '_doDislikeTrack returns PLUGIN_ZVUK_DONE on success');
is($last_gql->{op}, 'removeItemFromCollection', '_doDislikeTrack executes removeItemFromCollection');
is($last_gql->{vars}{id}, '12345', '_doDislikeTrack passes track ID');
is($last_gql->{vars}{type}, 'track', '_doDislikeTrack passes type track');

# -------------------------------------------------------------------
# Test 6: Error handling when GraphQL returns an error
# -------------------------------------------------------------------
no warnings 'redefine';
local *Plugins::Zvuk::API::Async::_graphql = sub {
	my ($self, $cb, $op, $gql, $vars) = @_;
	$cb->({ error => 'Network timeout' });
};
use warnings 'redefine';

my $err_like_result;
Plugins::Zvuk::UI::InfoMenu::_doLikeTrack(
	$client,
	sub { $err_like_result = shift; },
	{},
	$async,
	'12345',
	0
);

ok($err_like_result, 'Error callback invoked for _doLikeTrack');
is($err_like_result->{items}[0]{name}, 'Error: Network timeout', 'Error message rendered on failure');

# -------------------------------------------------------------------
# Test 7: Episode liking and unliking
# -------------------------------------------------------------------
no warnings 'redefine';
local *Plugins::Zvuk::API::Async::_graphql = sub {
	my ($self, $cb, $op, $gql, $vars) = @_;
	$last_gql = { op => $op, gql => $gql, vars => $vars };
	$cb->({ data => { collection => { addItem => 1 } } });
};
use warnings 'redefine';

my $ep_like_result;
Plugins::Zvuk::UI::InfoMenu::_doLikeTrack(
	$client,
	sub { $ep_like_result = shift; },
	{},
	$async,
	'54321',
	1 # isEpisode
);

is($last_gql->{op}, 'addItemToCollection', 'likeEpisode op is addItemToCollection');
is($last_gql->{vars}{id}, '54321', 'likeEpisode passes episode ID');
is($last_gql->{vars}{type}, 'episode', 'likeEpisode passes type episode');

my $ep_unlike_result;
Plugins::Zvuk::UI::InfoMenu::_doUnlikeTrack(
	$client,
	sub { $ep_unlike_result = shift; },
	{},
	$async,
	'54321',
	1 # isEpisode
);

is($last_gql->{op}, 'removeItemFromCollection', 'unlikeEpisode op is removeItemFromCollection');
is($last_gql->{vars}{id}, '54321', 'unlikeEpisode passes episode ID');
is($last_gql->{vars}{type}, 'episode', 'unlikeEpisode passes type episode');

# -------------------------------------------------------------------
# Test 8: API client fallback when $api in passthrough is undef
# -------------------------------------------------------------------
my $fallback_result;
Plugins::Zvuk::UI::InfoMenu::_doLikeTrack(
	$client,
	sub { $fallback_result = shift; },
	{},
	undef, # missing $api
	'12345',
	0
);
ok($fallback_result, 'Fallback to _get_api_client succeeded');
is($fallback_result->{items}[0]{name}, 'PLUGIN_ZVUK_DONE', 'Fallback executed successfully');

# -------------------------------------------------------------------
# Test 9: Cache invalidation verification
# -------------------------------------------------------------------
use Digest::MD5 qw(md5_hex);
my $cache_key = "zvuk_gql:acctA:userTracks:" . md5_hex('{}');
Plugins::Zvuk::API->cache->set($cache_key, [{ id => 999 }], 300);
ok(Plugins::Zvuk::API->cache->get($cache_key), 'userTracks cache populated');

$async->likeTrack(sub {}, '12345');
ok(!Plugins::Zvuk::API->cache->get($cache_key), 'likeTrack invalidated userTracks cache');

Plugins::Zvuk::API->cache->set($cache_key, [{ id => 999 }], 300);
$async->unlikeTrack(sub {}, '12345');
ok(!Plugins::Zvuk::API->cache->get($cache_key), 'unlikeTrack invalidated userTracks cache');

# -------------------------------------------------------------------
# Test 10: menuInfoCLI integration with CLI query
# -------------------------------------------------------------------
{
	package Test::FakeCLIRequest;
	sub new { my ($cls, %args) = @_; return bless { %args }, $cls; }
	sub client { return $_[0]->{client}; }
	sub getParam { my ($self, $k) = @_; return $self->{params}{$k}; }
}

my $cli_request = Test::FakeCLIRequest->new(
	client => $client,
	params => {
		type => 'track',
		id   => '777888',
		url  => 'zvuk://777888',
	},
);

my $cli_feed;
{
	no warnings qw(redefine once);
	local *Slim::Control::XMLBrowser::cliQuery = sub {
		my ($cmd, $feed, $req) = @_;
		$cli_feed = $feed;
	};
	Plugins::Zvuk::UI::InfoMenu::menuInfoCLI($cli_request);
}
ok($cli_feed, 'menuInfoCLI dispatched to XMLBrowser::cliQuery');
my @cli_names = map { $_->{name} } @{ $cli_feed->{items} || [] };
ok((grep { $_ eq 'PLUGIN_ZVUK_LIKE_TRACK' } @cli_names), 'CLI feed includes PLUGIN_ZVUK_LIKE_TRACK');
ok((grep { $_ eq 'PLUGIN_ZVUK_DISLIKE_TRACK' } @cli_names), 'CLI feed includes PLUGIN_ZVUK_DISLIKE_TRACK');

# -------------------------------------------------------------------
# Test 11: Missing ID validation in handlers
# -------------------------------------------------------------------
my $missing_track_res;
Plugins::Zvuk::UI::InfoMenu::_doLikeTrack($client, sub { $missing_track_res = shift; }, {}, $async, undef, 0);
is($missing_track_res->{items}[0]{name}, 'Error: Missing track ID', '_doLikeTrack returns error on missing trackId');

my $missing_unlike_res;
Plugins::Zvuk::UI::InfoMenu::_doUnlikeTrack($client, sub { $missing_unlike_res = shift; }, {}, $async, undef, 0);
is($missing_unlike_res->{items}[0]{name}, 'Error: Missing track ID', '_doUnlikeTrack returns error on missing trackId');

my $missing_album_res;
Plugins::Zvuk::UI::InfoMenu::_doLikeRelease($client, sub { $missing_album_res = shift; }, {}, $async, undef);
is($missing_album_res->{items}[0]{name}, 'Error: Missing album ID', '_doLikeRelease returns error on missing releaseId');

my $missing_unalbum_res;
Plugins::Zvuk::UI::InfoMenu::_doUnlikeRelease($client, sub { $missing_unalbum_res = shift; }, {}, $async, undef);
is($missing_unalbum_res->{items}[0]{name}, 'Error: Missing album ID', '_doUnlikeRelease returns error on missing releaseId');

# -------------------------------------------------------------------
# Test 12: Episode context menu in menuInfoCLI
# -------------------------------------------------------------------
my $cli_ep_request = Test::FakeCLIRequest->new(
	client => $client,
	params => {
		type => 'episode',
		id   => '998877',
		url  => 'zvuk://episode:998877',
	},
);

my $cli_ep_feed;
{
	no warnings qw(redefine once);
	local *Slim::Control::XMLBrowser::cliQuery = sub {
		my ($cmd, $feed, $req) = @_;
		$cli_ep_feed = $feed;
	};
	Plugins::Zvuk::UI::InfoMenu::menuInfoCLI($cli_ep_request);
}
ok($cli_ep_feed, 'menuInfoCLI dispatched episode to XMLBrowser::cliQuery');
my @cli_ep_names = map { $_->{name} } @{ $cli_ep_feed->{items} || [] };
ok((grep { $_ eq 'PLUGIN_ZVUK_LIKE_TRACK' } @cli_ep_names), 'CLI episode feed includes PLUGIN_ZVUK_LIKE_TRACK');
ok((grep { $_ eq 'PLUGIN_ZVUK_DISLIKE_TRACK' } @cli_ep_names), 'CLI episode feed includes PLUGIN_ZVUK_DISLIKE_TRACK');
ok(!(grep { $_ eq 'PLUGIN_ZVUK_TRACK_RADIO' } @cli_ep_names), 'CLI episode feed does not include radio items');

# -------------------------------------------------------------------
# Test 13: Extended cache invalidation for episode and artist
# -------------------------------------------------------------------
my $ep_cache_key = "zvuk_gql:acctA:userPaginatedEpisodes:" . md5_hex('{}');
Plugins::Zvuk::API->cache->set($ep_cache_key, [{ id => 555 }], 300);
ok(Plugins::Zvuk::API->cache->get($ep_cache_key), 'userPaginatedEpisodes cache populated');
$async->likeEpisode(sub {}, '555');
ok(!Plugins::Zvuk::API->cache->get($ep_cache_key), 'likeEpisode invalidated userPaginatedEpisodes cache');

my $artist_cache_key = "zvuk_gql:acctA:userCollectionArtists:" . md5_hex('{}');
Plugins::Zvuk::API->cache->set($artist_cache_key, [{ id => 333 }], 300);
ok(Plugins::Zvuk::API->cache->get($artist_cache_key), 'userCollectionArtists cache populated');
$async->likeArtist(sub {}, '333');
ok(!Plugins::Zvuk::API->cache->get($artist_cache_key), 'likeArtist invalidated userCollectionArtists cache');

done_testing();
