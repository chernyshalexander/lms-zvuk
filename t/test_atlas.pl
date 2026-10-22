#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';
binmode Test::More->builder->output, ':utf8';
binmode Test::More->builder->failure_output, ':utf8';
binmode Test::More->builder->todo_output, ':utf8';

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::API;
require Plugins::Zvuk::API::Atlas;
require Plugins::Zvuk::API::Async;
require Plugins::Zvuk::UI::Atlas;
require Plugins::Zvuk::ProtocolHandler;
require Plugins::Zvuk::Plugin;

# Set up test prefs and client
my $client = Test::FakeClient->new(id => 'player_atlas_1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
		user_atlas => { token => '0123456789abcdef0123456789abcdef', name => 'Atlas User' },
	};
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'user_atlas';
}

# Load fixture data if available, or fallback to mock
my $capture_dir = "$Bin/../.research/atlas-research/capture";
my $map_json_content;
if (-f "$capture_dir/api_v1_map_full.json") {
	open my $fh, '<:raw', "$capture_dir/api_v1_map_full.json" or die $!;
	local $/;
	$map_json_content = <$fh>;
	close $fh;
}

my $islands_json_content;
if (-f "$capture_dir/api_v1_map_islands_coldrock.json") {
	open my $fh, '<:raw', "$capture_dir/api_v1_map_islands_coldrock.json" or die $!;
	local $/;
	$islands_json_content = <$fh>;
	close $fh;
}

my $wave_json_content;
if (-f "$capture_dir/verify_wave_jazz_r2.json") {
	open my $fh, '<:raw', "$capture_dir/verify_wave_jazz_r2.json" or die $!;
	local $/;
	$wave_json_content = <$fh>;
	close $fh;
}

my $wave_3tracks_json;
if ($wave_json_content) {
	my $decoded = JSON::XS::decode_json($wave_json_content);
	if ($decoded->{tracks} && ref $decoded->{tracks} eq 'ARRAY') {
		my @first3 = @{ $decoded->{tracks} }[0 .. 2];
		$decoded->{tracks} = \@first3;
		$wave_3tracks_json = JSON::XS::encode_json($decoded);
	}
}

# ===================================================================
# SECTION 1: Atlas API Client (Plugins::Zvuk::API::Atlas)
# ===================================================================

# Test 1.1: getMap - Endpoint, Headers, Cookie Auth, NO x-auth-token
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $map_json_content }
	);
	Plugins::Zvuk::API->cache->clear();

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($map_res, $map_err);
	$atlas->getMap(sub {
		($map_res, $map_err) = @_;
	});

	is($map_err, undef, 'T1.1: getMap succeeded without error');
	ok(ref $map_res eq 'HASH', 'T1.1: getMap returned hash ref');
	is($map_res->{user_id}, 777701291, 'T1.1: parsed user_id correctly');
	is(scalar(@{ $map_res->{islands} }), 79, 'T1.1: parsed all 79 islands from taste map');
	is(scalar(@{ $map_res->{trees} }), 2, 'T1.1: parsed 2 connected component trees');

	# Check request details
	my $last_req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	ok($last_req, 'T1.1: HTTP request was captured');
	my ($url, %headers) = @{ $last_req->{args} };
	is($url, 'https://atlas.zvuk.com/api/v1/map', 'T1.1: Target URL is https://atlas.zvuk.com/api/v1/map');
	is($headers{'accept'}, 'application/json', 'T1.1: accept header is application/json');
	is($headers{'cookie'}, 'auth=0123456789abcdef0123456789abcdef; in_webkit=true', 'T1.1: Cookie header contains auth=<token>; in_webkit=true');
	ok(!exists $headers{'x-auth-token'}, 'T1.1: CRITICAL: x-auth-token header is NOT present (rejected by atlas)');
	like($headers{'referer'}, qr{atlas\.zvuk\.com}, 'T1.1: Referer header contains atlas.zvuk.com');
	is($headers{'connection'}, 'close', 'T1.1: Connection header is close');
	ok($last_req->{opts}->{request}, 'T1.1: HTTP::Request object passed in SimpleAsyncHTTP opts');
	is($last_req->{opts}->{request}->protocol, 'HTTP/1.1', 'T1.1: Request protocol is explicitly HTTP/1.1 (avoids HTTP 426 Upgrade Required)');

	# Test 1.2: Cache Hit on second getMap
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	my ($cached_res, $cached_err);
	$atlas->getMap(sub {
		($cached_res, $cached_err) = @_;
	});
	is($cached_err, undef, 'T1.2: cached getMap returned without error');
	is(scalar(@{ $cached_res->{islands} }), 79, 'T1.2: cached getMap returned 79 islands');
	is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 0, 'T1.2: No HTTP request made on cache hit (served from Slim::Utils::Cache)');
}

# Test 1.3: getIslandTracks
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $islands_json_content }
	);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($isl_res, $isl_err);
	my $island_id = '1511fc72-2331-59d2-913f-9ce8ed2b04ad';
	$atlas->getIslandTracks(sub {
		($isl_res, $isl_err) = @_;
	}, $island_id);

	is($isl_err, undef, 'T1.3: getIslandTracks succeeded without error');
	is($isl_res->{title}, 'Холодный рок', 'T1.3: title parsed correctly');
	is(scalar(@{ $isl_res->{tracks} }), 50, 'T1.3: 50 island tracks returned');

	my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	my ($url, %headers) = @{ $req->{args} };
	is($url, "https://atlas.zvuk.com/api/v1/map/islands/$island_id", 'T1.3: target URL matches island_id');
	is($headers{'cookie'}, 'auth=0123456789abcdef0123456789abcdef; in_webkit=true', 'T1.3: Cookie header passed');
}

# Test 1.4: startIslandWave (PUT)
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => '{"island_alive":true,"island_id":"621ceafb-995c-5510-b601-5d4b14f02c08"}' }
	);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($start_res, $start_err);
	my $island_id = '621ceafb-995c-5510-b601-5d4b14f02c08';
	$atlas->startIslandWave(sub {
		($start_res, $start_err) = @_;
	}, $island_id);

	is($start_err, undef, 'T1.4: startIslandWave succeeded');
	ok($start_res->{island_alive}, 'T1.4: returned island_alive = true');

	my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	is($req->{method}, 'PUT', 'T1.4: HTTP method is PUT');
	my ($url, @rest) = @{ $req->{args} };
	my $body = pop @rest;
	my %headers = @rest;
	is($url, "https://atlas.zvuk.com/api/v1/map/islands/$island_id/wave", 'T1.4: Target is PUT wave URL');
	is($headers{'content-type'}, 'application/json', 'T1.4: Content-Type is application/json');
	ok($req->{opts}->{request}, 'T1.4: HTTP::Request object passed in SimpleAsyncHTTP opts for PUT');
	is($req->{opts}->{request}->protocol, 'HTTP/1.1', 'T1.4: PUT Request protocol is explicitly HTTP/1.1');
}

# Test 1.5: getIslandWave (GET with limit and cursor)
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $wave_json_content }
	);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($wave_res, $wave_err);
	my $island_id = '621ceafb-995c-5510-b601-5d4b14f02c08';
	$atlas->getIslandWave(sub {
		($wave_res, $wave_err) = @_;
	}, $island_id, 20, 'cursor_token_abc');

	is($wave_err, undef, 'T1.5: getIslandWave succeeded');
	is(scalar(@{ $wave_res->{tracks} }), 20, 'T1.5: 20 wave tracks returned');
	ok(defined $wave_res->{next_cursor} && length($wave_res->{next_cursor}), 'T1.5: next_cursor present');

	my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	my ($url, %headers) = @{ $req->{args} };
	like($url, qr{/api/v1/map/islands/$island_id/wave\?cursor=cursor_token_abc&limit=20}, 'T1.5: URL contains cursor and limit query params');
}

# Test 1.5b: getIslandWave default limit is 3 when limit is omitted
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $wave_3tracks_json || $wave_json_content }
	);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($wave_res, $wave_err);
	my $island_id = '621ceafb-995c-5510-b601-5d4b14f02c08';
	$atlas->getIslandWave(sub {
		($wave_res, $wave_err) = @_;
	}, $island_id);

	is($wave_err, undef, 'T1.5b: getIslandWave without limit parameter succeeded');
	my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	my ($url) = @{ $req->{args} };
	like($url, qr{/api/v1/map/islands/$island_id/wave\?limit=3}, 'T1.5b: Default limit is 3 when omitted');
}

# Test 1.6: Automatic Token Refresh on HTTP 401
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	Plugins::Zvuk::API->cache->clear();
	Plugins::Zvuk::API::Atlas->_resetThrottlerForTesting();
	Plugins::Zvuk::API::Async::_resetThrottlerForTesting();

	# Scenario: 401 on map request -> refreshToken succeeds -> retry with new token succeeds
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 401, message => 'Unauthorized' },
		{ code => 200, content => '{"token":"refreshed_token_xyz987"}' }, # refresh POST
		{ code => 200, content => $map_json_content },                   # retried map GET
	);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($auth_res, $auth_err);
	$atlas->getMap(sub {
		($auth_res, $auth_err) = @_;
	});

	is($auth_err, undef, 'T1.6: getMap succeeded after automatic 401 refresh');
	is(scalar(@{ $auth_res->{islands} }), 79, 'T1.6: retrieved map data after refresh');

	# Check that prefs were updated with new token
	my $updated_tok = Plugins::Zvuk::API->getToken('user_atlas');
	is($updated_tok, 'refreshed_token_xyz987', 'T1.6: User token in prefs updated to refreshed token');

	# Verify retried request sent the new token in Cookie header
	my $retry_req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	my ($retry_url, %retry_headers) = @{ $retry_req->{args} };
	is($retry_headers{'cookie'}, 'auth=refreshed_token_xyz987; in_webkit=true', 'T1.6: Retried request sent updated Cookie');
}

# Test 1.7: Cursor with base64 special characters (+, /, =) is properly URL-escaped
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $wave_json_content }
	);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my $island_id = '621ceafb-995c-5510-b601-5d4b14f02c08';
	my $base64_cursor = 'eyJ+v2/test==';

	my ($wave_res, $wave_err);
	$atlas->getIslandWave(sub {
		($wave_res, $wave_err) = @_;
	}, $island_id, 20, $base64_cursor);

	is($wave_err, undef, 'T1.7: getIslandWave with base64 cursor succeeded');
	my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	my ($url) = @{ $req->{args} };
	like($url, qr{cursor=eyJ%2Bv2%2Ftest%3D%3D}, 'T1.7: Base64 cursor characters (+, /, =) properly URL-escaped with uri_escape');
}

# Test 1.8: HTTP 403 status without 'error' key handled as error
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	Plugins::Zvuk::API->cache->clear();
	Plugins::Zvuk::API::Atlas->_resetThrottlerForTesting();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 403, content => '{"message":"Access denied"}' }
	);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($err_res, $err_msg, $err_code);
	$atlas->getMap(sub {
		($err_res, $err_msg, $err_code) = @_;
	});

	is($err_res, undef, 'T1.8: HTTP 403 without error key returns undef data');
	like($err_msg, qr{Access denied|403}, 'T1.8: HTTP 403 correctly recognized as error');
	is($err_code, 403, 'T1.8: HTTP 403 status code returned');
}

# Test 1.9: JSON parse error retains real HTTP status code (e.g. 502 HTML) and triggers retries
{
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Utils::Timers::SCHEDULED = ();
	Plugins::Zvuk::API->cache->clear();
	Plugins::Zvuk::API::Atlas->_resetThrottlerForTesting();

	my $html_502 = '<html><head><title>502 Bad Gateway</title></head><body>Bad Gateway</body></html>';
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = map { { code => 502, content => $html_502 } } (1 .. 6);

	my $atlas = Plugins::Zvuk::API::Atlas->new({ userId => 'user_atlas' });
	my ($err_res, $err_msg, $err_code);
	$atlas->getMap(sub {
		($err_res, $err_msg, $err_code) = @_;
	});

	ok(scalar(@Slim::Utils::Timers::SCHEDULED) == 1, 'T1.9: 502 HTML error is recognized as retryable (not hardcoded 400) and schedules timer');

	# Fire retry timers until max attempts exhausted
	while (@Slim::Utils::Timers::SCHEDULED) {
		Slim::Utils::Timers::fireAll();
	}

	is($err_res, undef, 'T1.9: 502 HTML error returns undef data after retries');
	is($err_code, 502, 'T1.9: Real HTTP 502 code retained instead of hardcoded 400');
}

# Test 1.10: Client eviction in clearClient
{
	my $c1 = Plugins::Zvuk::API::Atlas->new({ userId => 'user_evict_test' });
	ok(defined $c1, 'T1.10: Atlas client instantiated');
	Plugins::Zvuk::Plugin::_clear_api_client('user_evict_test');
	my $c2 = Plugins::Zvuk::API::Atlas->new({ userId => 'user_evict_test' });
	# Since client was evicted, a new instance is constructed
	isnt("$c1", "$c2", 'T1.10: _clear_api_client successfully evicted cached Atlas client instance');
}

# ===================================================================
# SECTION 2: Multi-client LMS Navigation UI (Plugins::Zvuk::UI::Atlas)
# ===================================================================

# Test 2.1: Root menu integration
{
	my $root_menu;
	Plugins::Zvuk::Plugin::_buildRootMenu($client, sub { $root_menu = shift; });
	ok(ref $root_menu eq 'HASH' && ref $root_menu->{items} eq 'ARRAY', 'T2.1: Root menu built successfully');

	my ($atlas_item) = grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::UI::Atlas::handleAtlasMenu } @{ $root_menu->{items} };
	ok(defined $atlas_item, 'T2.1: Root menu contains Taste Atlas (PLUGIN_ZVUK_ATLAS) menu item');
	ok(defined $atlas_item->{name} && length($atlas_item->{name}), 'T2.1: Atlas item has localized display name');
}

# Test 2.2: Root Atlas menu structure (All Islands, Genre Families, Moods, Random Island, Web Map)
{
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $map_json_content }
	);
	Plugins::Zvuk::API->cache->clear();

	my $atlas_menu;
	# Test with weblink_capable client
	my $web_client = Test::FakeClient->new(id => 'web_client_1');
	{
		no warnings 'redefine', 'once';
		local *Slim::Utils::Misc::canFollowWeblinks = sub { return 1; };
		Plugins::Zvuk::UI::Atlas::handleAtlasMenu($client, sub { $atlas_menu = shift; }, {});
	}

	ok(ref $atlas_menu eq 'HASH' && ref $atlas_menu->{items} eq 'ARRAY', 'T2.2: handleAtlasMenu returns menu');
	my @items = @{ $atlas_menu->{items} };

	my ($all_isl) = grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::UI::Atlas::handleAllIslands } @items;
	ok(defined $all_isl, 'T2.2: Menu contains "All Islands" item');

	my ($genres_item) = grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::UI::Atlas::handleGenresMenu } @items;
	ok(defined $genres_item, 'T2.2: Menu contains "By Genre Families" item');

	my ($moods_item) = grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::UI::Atlas::handleMoodsMenu } @items;
	ok(defined $moods_item, 'T2.2: Menu contains "By Moods" item');

	my ($random_item) = grep { ($_->{play} // '') eq 'zvuk://atlas:random' } @items;
	ok(defined $random_item, 'T2.2: Menu contains "Random Island (I am feeling lucky)" item');
	is($random_item->{url}, 'zvuk://atlas:random', 'T2.2: Random Island has zvuk://atlas:random URL for weblink/jive client');

	# And for button player, it uses CODE ref
	my $btn_atlas_menu;
	Plugins::Zvuk::UI::Atlas::handleAtlasMenu($client, sub { $btn_atlas_menu = shift; }, { isButton => 1 });
	my ($btn_random_item) = grep { ($_->{play} // '') eq 'zvuk://atlas:random' } @{ $btn_atlas_menu->{items} };
	ok(ref($btn_random_item->{url}) eq 'CODE' && $btn_random_item->{url} == \&Plugins::Zvuk::UI::Atlas::handleStartRandomIslandWave,
		'T2.2: Random Island uses CODE ref for button player');

	# Test 2.3: All Islands sorting by share / track_count
	my $all_islands_menu;
	Plugins::Zvuk::UI::Atlas::handleAllIslands($client, sub { $all_islands_menu = shift; }, {});
	ok(ref $all_islands_menu eq 'HASH', 'T2.3: handleAllIslands returned menu');
	is(scalar(@{ $all_islands_menu->{items} }), 79, 'T2.3: All 79 islands displayed');

	my $first_island = $all_islands_menu->{items}[0];
	like($first_island->{name}, qr/Одинокая классика/, 'T2.3: Top island by share (Одинокая классика, 6.7%) is first');
	is($first_island->{play}, 'zvuk://atlas:b97564c8-6b97-5a31-8078-e2dcd7748a27', 'T2.3: play URL is zvuk://atlas:<id>');
	ok(defined $first_island->{image}, 'T2.3: Island artwork cover is present');
}

# Test 2.4: Genre Families grouping (53 genres)
{
	my $genres_menu;
	Plugins::Zvuk::UI::Atlas::handleGenresMenu($client, sub { $genres_menu = shift; }, {});
	ok(ref $genres_menu eq 'HASH', 'T2.4: handleGenresMenu returned menu');

	my @genres = @{ $genres_menu->{items} };
	is(scalar(@genres), 53, 'T2.4: Exactly 53 unique genre families generated');

	# Top genre should be Rock or Jazz (based on track sum)
	my ($rock_genre) = grep { $_->{passthrough}[0]{genre} eq 'рок' } @genres;
	ok(defined $rock_genre, 'T2.4: "рок" genre family exists');
	like($rock_genre->{name}, qr/Рок\s*\(5/, 'T2.4: Rock genre shows 5 islands count');

	# Drilldown into Genre: handleGenreIslands
	my $genre_islands;
	Plugins::Zvuk::UI::Atlas::handleGenreIslands($client, sub { $genre_islands = shift; }, {}, { genre => 'рок' });
	is(scalar(@{ $genre_islands->{items} }), 5, 'T2.4: Rock genre contains exactly 5 islands');
	my ($cold_rock) = grep { $_->{passthrough}[0]{island_id} eq '1511fc72-2331-59d2-913f-9ce8ed2b04ad' } @{ $genre_islands->{items} };
	ok(defined $cold_rock, 'T2.4: "Холодный рок" island is inside rock genre folder');
}

# Test 2.5: Moods grouping (36 moods)
{
	my $moods_menu;
	Plugins::Zvuk::UI::Atlas::handleMoodsMenu($client, sub { $moods_menu = shift; }, {});
	ok(ref $moods_menu eq 'HASH', 'T2.5: handleMoodsMenu returned menu');

	my @moods = @{ $moods_menu->{items} };
	is(scalar(@moods), 36, 'T2.5: Exactly 36 unique mood folders generated');

	# Drilldown into Mood: handleMoodIslands
	my $mood_islands;
	Plugins::Zvuk::UI::Atlas::handleMoodIslands($client, sub { $mood_islands = shift; }, {}, { mood => 'одиночество' });
	ok(scalar(@{ $mood_islands->{items} }) >= 1, 'T2.5: Mood drilldown returned islands');
	my ($lonely_classical) = grep { $_->{passthrough}[0]{island_id} eq 'b97564c8-6b97-5a31-8078-e2dcd7748a27' } @{ $mood_islands->{items} };
	ok(defined $lonely_classical, 'T2.5: "Одинокая классика" is inside "одиночество" mood folder');
}

# Test 2.6: Island Detail and Track List
{
	my $island_detail;
	Plugins::Zvuk::UI::Atlas::handleIslandDetail($client, sub { $island_detail = shift; }, {}, { island_id => '1511fc72-2331-59d2-913f-9ce8ed2b04ad' });
	ok(ref $island_detail eq 'HASH', 'T2.6: handleIslandDetail returned menu');
	my @detail_items = @{ $island_detail->{items} };

	my ($play_stream_item) = grep { ($_->{play} // '') eq 'zvuk://atlas:1511fc72-2331-59d2-913f-9ce8ed2b04ad' } @detail_items;
	ok(defined $play_stream_item, 'T2.6: Island detail has "Play Island Wave" item');

	my ($tracks_item) = grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::Zvuk::UI::Atlas::handleIslandTrackList } @detail_items;
	ok(defined $tracks_item, 'T2.6: Island detail has "Island Tracks" item');

	# Test track list fetching
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $islands_json_content }
	);
	my $tracks_menu;
	Plugins::Zvuk::UI::Atlas::handleIslandTrackList($client, sub { $tracks_menu = shift; }, {}, { island_id => '1511fc72-2331-59d2-913f-9ce8ed2b04ad' });
	is(scalar(@{ $tracks_menu->{items} }), 50, 'T2.6: handleIslandTrackList returned 50 playable tracks');
	my $first_track = $tracks_menu->{items}[0];
	is($first_track->{url}, 'zvuk://47730977', 'T2.6: Track URL format is zvuk://<id>');
	is($first_track->{play}, 'zvuk://47730977', 'T2.6: Track play format is zvuk://<id>');
	is($first_track->{type}, 'audio', 'T2.6: Track type is audio');

	# Verify track metadata was cached
	my $cached_meta = Plugins::Zvuk::API->cache->get('zvuk_meta_47730977');
	ok(defined $cached_meta, 'T2.6: Track metadata cached in Slim::Utils::Cache');
	is($cached_meta->{title}, 'Satisfied', 'T2.6: Track title cached correctly');
	is($cached_meta->{artist}, 'Skunk Anansie', 'T2.6: Track artist cached correctly');

	# Verify metadata enrichment: when full GraphQL track info arrives with duration and album, cache is updated
	is($cached_meta->{duration}, 0, 'T2.6b: Initial Atlas track duration was 0');
	is($cached_meta->{album}, '', 'T2.6b: Initial Atlas track album was empty');

	Plugins::Zvuk::API->cacheTrackMetadata([
		{ id => 47730977, title => 'Satisfied', artist => 'Skunk Anansie', duration => 215, release => { title => 'Stoosh', id => 9999 } }
	]);
	my $enriched_meta = Plugins::Zvuk::API->cache->get('zvuk_meta_47730977');
	is($enriched_meta->{duration}, 215, 'T2.6b: Duration enriched in cache');
	is($enriched_meta->{secs}, 215, 'T2.6b: Secs enriched in cache');
	is($enriched_meta->{album}, 'Stoosh', 'T2.6b: Album enriched in cache');
}

# Test 2.7: Vintage Button / Rotary Knob Players (Squeezebox Boom / Classic)
{
	# 1. Verify no nextWindow => 'refresh' in menus for button players
	my $button_all_islands;
	Plugins::Zvuk::UI::Atlas::handleAllIslands($client, sub { $button_all_islands = shift; }, { isButton => 1 });
	my @refresh_items = grep { ($_->{nextWindow} // '') eq 'refresh' } @{ $button_all_islands->{items} };
	is(scalar(@refresh_items), 0, 'T2.7: Button player items do NOT contain nextWindow => refresh (prevents mode pop crash)');

	# 2. Island detail on button player uses CODE ref for playback
	my $button_detail;
	Plugins::Zvuk::UI::Atlas::handleIslandDetail($client, sub { $button_detail = shift; }, { isButton => 1 }, { island_id => '1511fc72-2331-59d2-913f-9ce8ed2b04ad' });
	my ($btn_play_item) = grep { ($_->{play} // '') eq 'zvuk://atlas:1511fc72-2331-59d2-913f-9ce8ed2b04ad' } @{ $button_detail->{items} };
	ok(ref $btn_play_item->{url} eq 'CODE', 'T2.7: Play stream item uses CODE ref for button player (enables rotary knob click)');

	# 3. Test handleStartIslandWave pops mode and executes playlist play
	my @executed_cmds;
	no warnings 'once';
	local *Test::FakeClient::execute = sub {
		my ($self, $cmd) = @_;
		push @executed_cmds, $cmd;
	};

	my @mode_stack = ('xmlbrowser');
	no warnings 'redefine', 'once';
	local *Slim::Buttons::Common::mode = sub { return $mode_stack[-1]; };
	local *Slim::Buttons::Common::popMode = sub { return pop @mode_stack; };
	local *Slim::Buttons::Common::pushModeLeft = sub { my ($c, $m) = @_; push @mode_stack, $m; };

	Plugins::Zvuk::UI::Atlas::handleStartIslandWave($client, sub {}, { isButton => 1 }, { island_id => '1511fc72-2331-59d2-913f-9ce8ed2b04ad' });

	is(scalar(@executed_cmds), 1, 'T2.7: handleStartIslandWave executed 1 command');
	is($executed_cmds[0][1], 'play', 'T2.7: Command is play');
	is($executed_cmds[0][2], 'zvuk://atlas:1511fc72-2331-59d2-913f-9ce8ed2b04ad', 'T2.7: Target is zvuk://atlas:<id>');
	is($mode_stack[-1], 'playlist', 'T2.7: Cleanly transitioned to playlist mode');

	# 4. Test handleStartRandomIslandWave on button player
	@executed_cmds = ();
	@mode_stack = ('xmlbrowser');
	Plugins::Zvuk::UI::Atlas::handleStartRandomIslandWave($client, sub {}, { isButton => 1 });
	is(scalar(@executed_cmds), 1, 'T2.7: handleStartRandomIslandWave executed command');
	like($executed_cmds[0][2], qr{^zvuk://atlas:[0-9a-fA-F-]+$}, 'T2.7: Random island played valid zvuk://atlas:<id>');
}

# ===================================================================
# SECTION 3: Actionability & Playback (ProtocolHandler.pm)
# ===================================================================

# Test 3.1: ProtocolHandler format and URL recognition
{
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{quality} = 'flac';
	is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://atlas:621ceafb-995c-5510-b601-5d4b14f02c08'), undef,
		'T3.1: getFormatForURL returns undef for zvuk://atlas:<id> (recognized as playlist container)');
	is_deeply(Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://atlas:621ceafb-995c-5510-b601-5d4b14f02c08'), {},
		'T3.1: getMetadataFor returns empty hash for container');
	is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://47730977'), 'flc',
		'T3.1: getFormatForURL returns audio format for track URL');
}

# Test 3.2: explodePlaylist for zvuk://atlas:<island_id>
{
	Plugins::Zvuk::API::Atlas->_resetThrottlerForTesting();
	Plugins::Zvuk::API::Async->_resetThrottlerForTesting();
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => '{"island_alive":true}' },               # PUT start wave
		{ code => 200, content => $wave_3tracks_json || $wave_json_content }, # GET wave tracks
	);

	my $exploded_urls;
	my $island_id = '621ceafb-995c-5510-b601-5d4b14f02c08';
	Plugins::Zvuk::ProtocolHandler->explodePlaylist($client, "zvuk://atlas:$island_id", sub {
		$exploded_urls = shift;
	});

	ok(ref $exploded_urls eq 'ARRAY', 'T3.2: explodePlaylist returned array of URLs');
	is(scalar(@$exploded_urls), 3, 'T3.2: Returned 3 track URLs for wave (3-track batching like Wave)');
	is($exploded_urls->[0], 'zvuk://34015579', 'T3.2: First URL is zvuk://34015579');

	# Check explode request sent limit=3
	my $last_req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	my ($url) = @{ $last_req->{args} };
	like($url, qr{limit=3}, 'T3.2: Explode request sent limit=3 (3-track batching like Wave)');

	# Check client state flags in pluginData
	is($client->pluginData('zvuk_atlas_active'), 1, 'T3.2: zvuk_atlas_active set to 1');
	is($client->pluginData('zvuk_atlas_island_id'), $island_id, 'T3.2: zvuk_atlas_island_id stored');
	ok(defined $client->pluginData('zvuk_atlas_cursor'), 'T3.2: zvuk_atlas_cursor stored');
	is($client->pluginData('zvuk_wave_active'), 0, 'T3.2: other modes cleared (wave_active = 0)');
	is($client->pluginData('zvuk_radio_active'), 0, 'T3.2: other modes cleared (radio_active = 0)');
}

# Test 3.3: Auto-extend Atlas Wave when queue is low
{
	Plugins::Zvuk::API::Atlas->_resetThrottlerForTesting();
	Plugins::Zvuk::API::Async->_resetThrottlerForTesting();
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	@Slim::Control::Request::EXECUTED_REQUESTS = ();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $wave_3tracks_json || $wave_json_content }
	);

	my $initial_cursor = $client->pluginData('zvuk_atlas_cursor');
	Plugins::Zvuk::ProtocolHandler::_loadMoreAtlasTracks($client);

	# Check request made with cursor
	my $last_req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[-1];
	my ($url) = @{ $last_req->{args} };
	like($url, qr{/api/v1/map/islands/621ceafb-995c-5510-b601-5d4b14f02c08/wave\?}, 'T3.3: Sent wave auto-load request');
	like($url, qr{cursor=}, 'T3.3: Included cursor in request');
	like($url, qr{limit=3}, 'T3.3: Auto-extend request sent limit=3 (3-track batching like Wave)');

	# Check that tracks were appended to LMS playlist
	is(scalar(@Slim::Control::Request::EXECUTED_REQUESTS), 3, 'T3.3: Appended 3 tracks via playlist add (3-track batching like Wave)');
	is($Slim::Control::Request::EXECUTED_REQUESTS[0]{cmd}[1], 'add', 'T3.3: Request command was playlist add');
	is($Slim::Control::Request::EXECUTED_REQUESTS[0]{cmd}[2], 'zvuk://34015579', 'T3.3: Added track URL is zvuk://34015579');
}

# Test 3.4: _onStop clears Atlas flags
{
	ok($client->pluginData('zvuk_atlas_active') == 1, 'T3.4: Pre-condition: atlas_active is 1');

	my $req = Test::FakeRequest->new(
		client => $client,
		cmd    => ['stop'],
	);
	Plugins::Zvuk::Plugin::_onStop($req);

	is($client->pluginData('zvuk_atlas_active'), 0, 'T3.4: zvuk_atlas_active cleared to 0 on stop');
	is($client->pluginData('zvuk_atlas_island_id'), undef, 'T3.4: zvuk_atlas_island_id reset to undef');
	is($client->pluginData('zvuk_atlas_cursor'), undef, 'T3.4: zvuk_atlas_cursor reset to undef');
}

# Test 3.5: explodePlaylist for zvuk://atlas:random resolves map and launches random island wave
{
	Plugins::Zvuk::API::Atlas->_resetThrottlerForTesting();
	Plugins::Zvuk::API::Async->_resetThrottlerForTesting();
	@Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
	Plugins::Zvuk::API->cache->clear();
	@Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
		{ code => 200, content => $map_json_content },                        # GET map to pick random island
		{ code => 200, content => '{"island_alive":true}' },                  # PUT start wave
		{ code => 200, content => $wave_3tracks_json || $wave_json_content }, # GET wave tracks
	);

	my $exploded_random_urls;
	Plugins::Zvuk::ProtocolHandler->explodePlaylist($client, 'zvuk://atlas:random', sub {
		$exploded_random_urls = shift;
	});

	ok(ref $exploded_random_urls eq 'ARRAY', 'T3.5: explodePlaylist for zvuk://atlas:random returned array of URLs');
	is(scalar(@$exploded_random_urls), 3, 'T3.5: Returned 3 tracks for random island wave');
	is($client->pluginData('zvuk_atlas_active'), 1, 'T3.5: zvuk_atlas_active set to 1');
	like($client->pluginData('zvuk_atlas_island_id'), qr/^[0-9a-fA-F-]+$/, 'T3.5: Random island ID selected and stored');
	ok(defined $client->pluginData('zvuk_atlas_cursor'), 'T3.5: Cursor stored for auto-extension');
}

# ===================================================================
# SECTION 4: Localization & Web Canvas Verification
# ===================================================================

# Test 4.1: strings.txt Taste Atlas English menu notice
{
	my $strings_file = "$repo_root/strings.txt";
	ok(-f $strings_file, 'T4.1: strings.txt exists');

	open my $sfh, '<:utf8', $strings_file or die "Cannot open strings.txt: $!";
	my %parsed_strings;
	my $current_token;
	while (my $line = <$sfh>) {
		chomp $line;
		if ($line =~ /^([A-Z0-9_]+)$/) {
			$current_token = $1;
		} elsif ($current_token && $line =~ /^\t(EN|RU)\t(.*)$/) {
			$parsed_strings{$current_token}{$1} = $2;
		}
	}
	close $sfh;

	my @atlas_menu_tokens = qw(
		PLUGIN_ZVUK_ATLAS_ALL_ISLANDS
		PLUGIN_ZVUK_ATLAS_GENRES
		PLUGIN_ZVUK_ATLAS_MOODS
		PLUGIN_ZVUK_ATLAS_RANDOM
		PLUGIN_ZVUK_ATLAS_WEB_MAP
	);

	for my $tok (@atlas_menu_tokens) {
		ok(exists $parsed_strings{$tok}, "T4.1: $tok exists in strings.txt");
		like($parsed_strings{$tok}{EN}, qr/\(in Russian\)$/, "T4.1: $tok has '(in Russian)' suffix in English");
		unlike($parsed_strings{$tok}{RU}, qr/\(in Russian\)/, "T4.1: $tok Russian text does NOT have '(in Russian)' suffix");
	}
}

# Test 4.2: HTML/EN/plugins/zvuk/atlasStandalone.html ASCII-cleanliness & Canvas Styles
{
	my $html_file = "$repo_root/HTML/EN/plugins/zvuk/atlasStandalone.html";
	ok(-f $html_file, 'T4.2: atlasStandalone.html exists');

	open my $hfh, '<:raw', $html_file or die "Cannot open atlasStandalone.html: $!";
	local $/;
	my $html_content = <$hfh>;
	close $hfh;

	# Verify 100% ASCII clean (prevents LMS Template Toolkit encoding crash)
	my @non_ascii = ($html_content =~ /([^\x00-\x7F])/g);
	is(scalar(@non_ascii), 0, 'T4.2: atlasStandalone.html is 100% ASCII-clean');

	# Verify quadrant opacity values (0.14 - 0.16)
	like($html_content, qr/rgba\(239,\s*68,\s*68,\s*0\.14\)/, 'T4.2: Q2 Drive tint is 0.14');
	like($html_content, qr/rgba\(245,\s*158,\s*11,\s*0\.14\)/, 'T4.2: Q1 Joy tint is 0.14');
	like($html_content, qr/rgba\(59,\s*130,\s*246,\s*0\.16\)/, 'T4.2: Q3 Melancholy tint is 0.16');
	like($html_content, qr/rgba\(16,\s*185,\s*129,\s*0\.14\)/, 'T4.2: Q4 Calm tint is 0.14');

	# Verify 2-pass vector stroke halo
	like($html_content, qr/ctx\.strokeText\(isl\.title,\s*p\.x,\s*textY\)/, 'T4.2: Implements ctx.strokeText halo');
	like($html_content, qr/ctx\.strokeStyle\s*=\s*'rgba\(13,\s*17,\s*23,\s*0\.95\)'/, 'T4.2: Dark halo stroke style');
	like($html_content, qr/ctx\.miterLimit\s*=\s*2/, 'T4.2: miterLimit is set to 2');
	like($html_content, qr/ctx\.lineJoin\s*=\s*'round'/, 'T4.2: lineJoin is round');
}

done_testing();

