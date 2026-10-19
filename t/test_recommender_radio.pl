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
require Plugins::Zvuk::ProtocolHandler;
require Plugins::Zvuk::Browse::InfoMenu;
require Plugins::Zvuk::API::Async;

# Set up test prefs and client
my $client = Test::FakeClient->new(id => 'player_radio_1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
		user1 => { token => 'test_token_123', name => 'Test User' },
	};
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'user1';
}

# -------------------------------------------------------------------
# Test 1: API/Async.pm getRecommenderRadio GraphQL dispatch
# -------------------------------------------------------------------
my $async = Plugins::Zvuk::API::Async->new({ userId => 'user1' });
my $last_gql;

no warnings 'redefine';
local *Plugins::Zvuk::API::Async::_graphql = sub {
	my ($self, $cb, $op, $gql, $vars, $opts) = @_;
	$last_gql = { op => $op, gql => $gql, vars => $vars, opts => $opts };
	$cb->({
		recommenderRadio => {
			cursor => 20,
			tracks => [
				{
					id       => 101,
					title    => 'Radio Track 1',
					duration => 180,
					artists  => [{ id => 201, title => 'Artist 1' }],
					release  => { id => 301, title => 'Release 1' },
				},
				{
					id       => 102,
					title    => 'Radio Track 2',
					duration => 200,
					artists  => [{ id => 202, title => 'Artist 2' }],
					release  => { id => 302, title => 'Release 2' },
				},
			],
		},
	});
};
use warnings 'redefine';

my $radio_result;
$async->getRecommenderRadio(sub { $radio_result = shift; }, 555, 'track', 20, 0);

is($last_gql->{op}, 'recommenderRadio', 'T1: op name is recommenderRadio');
like($last_gql->{gql}, qr/query\s+recommenderRadio/, 'T1: query definition has recommenderRadio');
is($last_gql->{vars}{id}, '555', 'T1: passes correct entity ID string');
is($last_gql->{vars}{type}, 'TRACK', 'T1: normalized entity type to uppercase TRACK');
is($last_gql->{vars}{first}, 20, 'T1: first limit is 20');
is($last_gql->{vars}{cursor}, 0, 'T1: cursor is 0');
is($last_gql->{opts}{ttl}, 0, 'T1: cache ttl is 0');
is(scalar(@{ $radio_result->{tracks} }), 2, 'T1: returned 2 tracks');
is($radio_result->{cursor}, 20, 'T1: returned next cursor 20');

# Test album type mapping to RELEASE
$async->getRecommenderRadio(sub {}, 777, 'album', 15, 20);
is($last_gql->{vars}{type}, 'RELEASE', 'T1b: album mapped to RELEASE entity type');
is($last_gql->{vars}{first}, 15, 'T1b: first limit 15 passed');
is($last_gql->{vars}{cursor}, 20, 'T1b: cursor 20 passed');

# -------------------------------------------------------------------
# Test 2: ProtocolHandler format and URL recognition
# -------------------------------------------------------------------
is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://radio:track:555'), undef,
	'T2: getFormatForURL returns undef for radio:track');
is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://radio:artist:201'), undef,
	'T2: getFormatForURL returns undef for radio:artist');
is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://radio:release:301'), undef,
	'T2: getFormatForURL returns undef for radio:release');
is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://wave'), undef,
	'T2: getFormatForURL returns undef for zvuk://wave');
is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://101'), 'mp3',
	'T2: getFormatForURL returns audio format for track URL');

is_deeply(Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://radio:track:555'), {},
	'T2b: getMetadataFor returns empty hash for radio container URL');

# -------------------------------------------------------------------
# Test 3: explodePlaylist for zvuk://radio:track:555
# -------------------------------------------------------------------
$client->pluginData(zvuk_wave_active => 1);
$client->pluginData(zvuk_gigamix_active => 1);

my $exploded_urls;
Plugins::Zvuk::ProtocolHandler->explodePlaylist($client, 'zvuk://radio:track:555', sub {
	$exploded_urls = shift;
});

is_deeply($exploded_urls, ['zvuk://101', 'zvuk://102'], 'T3: exploded into track URLs');
is($client->pluginData('zvuk_radio_active'), 1, 'T3: zvuk_radio_active set to 1');
is($client->pluginData('zvuk_radio_entity_id'), '555', 'T3: entity_id stored on client');
is($client->pluginData('zvuk_radio_entity_type'), 'TRACK', 'T3: entity_type stored on client');
is($client->pluginData('zvuk_radio_cursor'), 20, 'T3: cursor stored on client');
is($client->pluginData('zvuk_wave_active'), 0, 'T3: wave_active reset to 0');
is($client->pluginData('zvuk_gigamix_active'), 0, 'T3: gigamix_active reset to 0');

# Verify tracks were cached in metadata cache
my $cached_meta = Plugins::Zvuk::API->cache->get('zvuk_meta_101');
ok($cached_meta, 'T3b: track 101 cached in metadata cache');
is($cached_meta->{title}, 'Radio Track 1', 'T3b: correct cached title');
is($cached_meta->{artist}, 'Artist 1', 'T3b: correct cached artist');

# -------------------------------------------------------------------
# Test 4: Auto-pagination (_loadMoreRadioTracks)
# -------------------------------------------------------------------
my @executed_requests;
no warnings qw(redefine once);
local *Slim::Control::Request::executeRequest = sub {
	my ($cli, $cmd) = @_;
	push @executed_requests, { client => $cli, cmd => $cmd };
};

local *Plugins::Zvuk::API::Async::_graphql = sub {
	my ($self, $cb, $op, $gql, $vars, $opts) = @_;
	$last_gql = { op => $op, gql => $gql, vars => $vars };
	$cb->({
		recommenderRadio => {
			cursor => 40,
			tracks => [
				{
					id       => 103,
					title    => 'Radio Track 3',
					duration => 190,
					artists  => [{ id => 203, title => 'Artist 3' }],
				},
				{
					id       => 104,
					title    => 'Radio Track 4',
					duration => 210,
					artists  => [{ id => 204, title => 'Artist 4' }],
				},
			],
		},
	});
};
use warnings 'redefine';

Plugins::Zvuk::ProtocolHandler::_loadMoreRadioTracks($client);

is($last_gql->{vars}{first}, 3, 'T4: loaded more tracks with limit 3');
is($last_gql->{vars}{cursor}, 20, 'T4: loaded more tracks with cursor 20');
is($client->pluginData('zvuk_radio_cursor'), 40, 'T4: cursor updated to 40');
is(scalar(@executed_requests), 2, 'T4: executed 2 playlist add requests');
is_deeply($executed_requests[0]{cmd}, ['playlist', 'add', 'zvuk://103'], 'T4: added track 103');
is_deeply($executed_requests[1]{cmd}, ['playlist', 'add', 'zvuk://104'], 'T4: added track 104');
is($client->pluginData('zvuk_radio_loading'), 0, 'T4: loading flag cleared');

# -------------------------------------------------------------------
# Test 5: State reset on stop
# -------------------------------------------------------------------
my $fake_stop_request = Test::FakeRequest->new(
	client => $client,
	cmd    => ['stop'],
);
Plugins::Zvuk::Plugin::_onStop($fake_stop_request);

is($client->pluginData('zvuk_radio_active'), 0, 'T5: zvuk_radio_active reset to 0');
is($client->pluginData('zvuk_radio_entity_id'), undef, 'T5: entity_id reset to undef');
is($client->pluginData('zvuk_radio_entity_type'), undef, 'T5: entity_type reset to undef');
is($client->pluginData('zvuk_radio_cursor'), undef, 'T5: cursor reset to undef');

# -------------------------------------------------------------------
# Test 6: Browse/InfoMenu.pm trackInfoMenu and artistInfoMenu
# -------------------------------------------------------------------
my $track_menu = Plugins::Zvuk::Browse::InfoMenu::trackInfoMenu(
	$client,
	'zvuk://101',
	undef,
	{ track => 'Radio Track 1', artist => 'Artist 1', artist_id => 201, album => 'Release 1', release_id => 301 }
);

ok($track_menu, 'T6: trackInfoMenu returned a menu');
is($track_menu->{name}, 'PLUGIN_ZVUK_ON_ZVUK', 'T6: trackInfoMenu is named PLUGIN_ZVUK_ON_ZVUK');
is($track_menu->{type}, 'outline', 'T6: trackInfoMenu has type outline');
my $t_items = $track_menu->{items};
is(scalar(@$t_items), 3, 'T6: trackInfoMenu has 3 items (track radio, artist radio, album radio)');
is($t_items->[0]{name}, 'PLUGIN_ZVUK_TRACK_RADIO', 'T6: item 1 is Track Radio');
is($t_items->[0]{itemActions}{go}{cmd}[1], 'play', 'T6: item 1 action is playlist play');
is($t_items->[0]{itemActions}{go}{params}{url}, 'zvuk://radio:track:101', 'T6: item 1 URL is zvuk://radio:track:101');

like($t_items->[1]{name}, qr/PLUGIN_ZVUK_ARTIST_RADIO/, 'T6: item 2 is Artist Radio');
is($t_items->[1]{itemActions}{go}{params}{url}, 'zvuk://radio:artist:201', 'T6: item 2 URL is zvuk://radio:artist:201');

like($t_items->[2]{name}, qr/PLUGIN_ZVUK_ALBUM_RADIO/, 'T6: item 3 is Album Radio');
is($t_items->[2]{itemActions}{go}{params}{url}, 'zvuk://radio:release:301', 'T6: item 3 URL is zvuk://radio:release:301');

# Test artistInfoMenu
my $artist_menu = Plugins::Zvuk::Browse::InfoMenu::artistInfoMenu(
	$client,
	'zvuk://artist:201',
	undef,
	{ artist => 'Artist 1' }
);
ok($artist_menu, 'T6b: artistInfoMenu returned a menu');
is($artist_menu->{name}, 'PLUGIN_ZVUK_ON_ZVUK', 'T6b: artistInfoMenu is named PLUGIN_ZVUK_ON_ZVUK');
is($artist_menu->{type}, 'outline', 'T6b: artistInfoMenu has type outline');
is($artist_menu->{items}[0]{name}, 'PLUGIN_ZVUK_ARTIST_RADIO', 'T6b: item is Artist Radio');
is($artist_menu->{items}[0]{itemActions}{go}{params}{url}, 'zvuk://radio:artist:201', 'T6b: URL is zvuk://radio:artist:201');

# -------------------------------------------------------------------
# Test 7: Plugin.pm handleArtist menu contains Artist Radio
# -------------------------------------------------------------------
my $artist_page;
Plugins::Zvuk::Plugin::handleArtist($client, sub { $artist_page = shift; }, {}, { id => 201 });
ok($artist_page, 'T7: handleArtist returned page');
is($artist_page->{items}[0]{name}, 'PLUGIN_ZVUK_ARTIST_RADIO', 'T7: first item in Artist page is Artist Radio');
is($artist_page->{items}[0]{itemActions}{go}{params}{url}, 'zvuk://radio:artist:201', 'T7: launches zvuk://radio:artist:201');
is($artist_page->{items}[1]{name}, 'SONGS', 'T7: second item is Songs');
is($artist_page->{items}[2]{name}, 'ALBUMS', 'T7: third item is Albums');

# -------------------------------------------------------------------
# Test 8: _renderTrack contains info itemActions
# -------------------------------------------------------------------
my $rendered_track = Plugins::Zvuk::Plugin::_renderTrack({
	id       => 101,
	title    => 'Radio Track 1',
	duration => 180,
	artists  => [{ id => 201, title => 'Artist 1' }],
	release  => { id => 301, title => 'Release 1' },
}, 1);

ok($rendered_track->{itemActions}, 'T8: track has itemActions');
ok($rendered_track->{itemActions}{info}, 'T8: track has info action');
is_deeply($rendered_track->{itemActions}{info}{command}, ['zvuk_info', 'items'], 'T8: info command is zvuk_info items');
is($rendered_track->{itemActions}{info}{fixedParams}{type}, 'track', 'T8: fixedParams type is track');
is($rendered_track->{itemActions}{info}{fixedParams}{id}, 101, 'T8: fixedParams id is 101');
is($rendered_track->{itemActions}{info}{fixedParams}{artist_id}, 201, 'T8: fixedParams artist_id is 201');
is($rendered_track->{itemActions}{info}{fixedParams}{release_id}, 301, 'T8: fixedParams release_id is 301');

done_testing();
