#!/usr/bin/env perl
# t/test_stream_manager.pl
# Phase 3: StreamManager and Stream Lifecycle Unification test suite
# Tests:
#  1. Atomic state transitions & backwards-compatibility sync
#  2. External album / playlist change isolation
#  3. GigaMix stream launching, auto-extension, and clean termination (honest completion)
#  4. Race condition protection (is_loading across all 4 modes)
#
# Run: prove -I. -It t/test_stream_manager.t

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
require Plugins::Zvuk::API::Async;
require Plugins::Zvuk::ProtocolHandler;
require Plugins::Zvuk::UI::GigaMix;
require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::StreamManager;

# Setup mock client & prefs
my $client = Test::FakeClient->new(id => 'sm_player_1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
		user_test => { token => '11112222333344445555666677778888', name => 'Test User' },
	};
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'user_test';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{gigamix_autoplay} = 1;
}

# =========================================================================
# 1. Atomic State Transitions & Legacy Sync
# =========================================================================
subtest 'Atomic state transitions and legacy sync' => sub {
	my $sm = 'Plugins::Zvuk::StreamManager';

	# Initial state is clean
	$sm->stopStream($client);
	is($sm->getActiveMode($client), undef, 'Initial active mode is undef');
	is($sm->isLoading($client), 0, 'Initial isLoading is 0');
	is_deeply($sm->getContext($client), {}, 'Initial context is empty');

	# Start Wave stream
	$sm->startStream($client, 'wave', { settings => { mood => 'energetic' } });
	is($sm->getActiveMode($client), 'wave', 'Mode is wave');
	is($client->pluginData('zvuk_wave_active'), 1, 'zvuk_wave_active is 1');
	is($client->pluginData('zvuk_radio_active'), 0, 'zvuk_radio_active is 0');
	is($client->pluginData('zvuk_atlas_active'), 0, 'zvuk_atlas_active is 0');
	is($client->pluginData('zvuk_gigamix_active'), 0, 'zvuk_gigamix_active is 0');
	is_deeply($client->pluginData('zvuk_wave_settings'), { mood => 'energetic' }, 'Wave settings synced');

	# Transition: Wave -> Radio (cleanly replaces context)
	$sm->startStream($client, 'radio', { id => 5001, type => 'TRACK', cursor => 15 });
	is($sm->getActiveMode($client), 'radio', 'Transition to radio successful');
	is($client->pluginData('zvuk_wave_active'), 0, 'Previous wave_active cleared to 0');
	is($client->pluginData('zvuk_radio_active'), 1, 'zvuk_radio_active set to 1');
	is($client->pluginData('zvuk_radio_entity_id'), 5001, 'radio entity_id stored');
	is($client->pluginData('zvuk_radio_entity_type'), 'TRACK', 'radio entity_type stored');
	is($client->pluginData('zvuk_radio_cursor'), 15, 'radio cursor stored');

	# Transition: Radio -> Atlas
	$sm->startStream($client, 'atlas', { island_id => 'island-abc', cursor => 'cur_atl' });
	is($sm->getActiveMode($client), 'atlas', 'Transition to atlas successful');
	is($client->pluginData('zvuk_radio_active'), 0, 'Previous radio_active cleared to 0');
	is($client->pluginData('zvuk_radio_entity_id'), undef, 'Previous radio entity_id cleared');
	is($client->pluginData('zvuk_atlas_active'), 1, 'zvuk_atlas_active set to 1');
	is($client->pluginData('zvuk_atlas_island_id'), 'island-abc', 'atlas island_id stored');
	is($client->pluginData('zvuk_atlas_cursor'), 'cur_atl', 'atlas cursor stored');

	# Transition: Atlas -> GigaMix
	$sm->startStream($client, 'gigamix', { prompt => 'Lo-Fi Chill', cursor => 'cur_giga' });
	is($sm->getActiveMode($client), 'gigamix', 'Transition to gigamix successful');
	is($client->pluginData('zvuk_atlas_active'), 0, 'Previous atlas_active cleared to 0');
	is($client->pluginData('zvuk_atlas_island_id'), undef, 'Previous atlas island_id cleared');
	is($client->pluginData('zvuk_gigamix_active'), 1, 'zvuk_gigamix_active set to 1');
	is($client->pluginData('zvuk_gigamix_prompt'), 'Lo-Fi Chill', 'gigamix prompt stored');
	is($client->pluginData('zvuk_gigamix_cursor'), 'cur_giga', 'gigamix cursor stored');

	# Stop stream completely
	$sm->stopStream($client);
	is($sm->getActiveMode($client), undef, 'Active mode is undef after stopStream');
	is($client->pluginData('zvuk_wave_active'), 0, 'wave_active is 0');
	is($client->pluginData('zvuk_radio_active'), 0, 'radio_active is 0');
	is($client->pluginData('zvuk_atlas_active'), 0, 'atlas_active is 0');
	is($client->pluginData('zvuk_gigamix_active'), 0, 'gigamix_active is 0');
	is($client->pluginData('zvuk_gigamix_prompt'), undef, 'gigamix prompt cleared');
	is($client->pluginData('zvuk_gigamix_cursor'), undef, 'gigamix cursor cleared');

	# Backwards-compatibility fallback test:
	# If legacy external caller directly set zvuk_wave_active without zvuk_stream
	$client->pluginData(zvuk_stream => undef);
	$client->pluginData(zvuk_wave_active => 1);
	is($sm->getActiveMode($client), 'wave', 'Fallback: legacy zvuk_wave_active recognized');

	$client->pluginData(zvuk_wave_active => 0);
	$client->pluginData(zvuk_radio_loading => 1);
	is($sm->isLoading($client), 1, 'Fallback: legacy zvuk_radio_loading recognized');

	# Clean up
	$sm->stopStream($client);
};

# =========================================================================
# 2. External Album / Playlist Change Isolation
# =========================================================================
subtest 'External album and playlist change isolation' => sub {
	my $sm = 'Plugins::Zvuk::StreamManager';

	# Helper to create fake LMS request
	my $make_req = sub {
		my (@cmd) = @_;
		return Test::FakeRequest->new(client => $client, cmd => \@cmd);
	};

	# 1. Stop command resets stream
	$sm->startStream($client, 'wave', {});
	is($sm->getActiveMode($client), 'wave', 'Wave active before stop');
	Plugins::Zvuk::Plugin::_onStop($make_req->('stop'));
	is($sm->getActiveMode($client), undef, 'Stream stopped cleanly on stop event');

	# 2. Playlist clear command resets stream
	$sm->startStream($client, 'radio', { id => 101, type => 'TRACK' });
	is($sm->getActiveMode($client), 'radio', 'Radio active before playlist clear');
	Plugins::Zvuk::Plugin::_onStop($make_req->('playlist', 'clear'));
	is($sm->getActiveMode($client), undef, 'Stream stopped cleanly on playlist clear event');

	# 3. Playing an external album URL resets active stream
	$sm->startStream($client, 'atlas', { island_id => 'isl-1' });
	is($sm->getActiveMode($client), 'atlas', 'Atlas active before album play');
	Plugins::Zvuk::Plugin::_onStop($make_req->('playlist', 'play', 'zvuk://album:12345'));
	is($sm->getActiveMode($client), undef, 'Stream stopped when non-stream album URL is played');

	# 4. Playing an external local file URL resets active stream
	$sm->startStream($client, 'gigamix', { prompt => 'Rock', cursor => 'c1' });
	is($sm->getActiveMode($client), 'gigamix', 'GigaMix active before local play');
	Plugins::Zvuk::Plugin::_onStop($make_req->('playlist', 'play', 'file:///var/music/song.flac'));
	is($sm->getActiveMode($client), undef, 'Stream stopped when local file URL is played');

	# 5. Playing a stream URL does NOT reset the active stream
	$sm->startStream($client, 'wave', {});
	Plugins::Zvuk::Plugin::_onStop($make_req->('playlist', 'play', 'zvuk://wave'));
	is($sm->getActiveMode($client), 'wave', 'Stream URL (zvuk://wave) does not reset active stream');

	# 6. Exploding an external album via ProtocolHandler cleanly resets stream
	$sm->startStream($client, 'radio', { id => 202, type => 'ARTIST' });
	is($sm->getActiveMode($client), 'radio', 'Radio active before explode album');

	no warnings qw(once redefine);
	local *Plugins::Zvuk::Plugin::handleAlbum = sub {
		my ($cli, $cb, $args, $params) = @_;
		$cb->({ items => [{ url => 'zvuk://301' }, { url => 'zvuk://302' }] });
	};

	my $exploded_album;
	Plugins::Zvuk::ProtocolHandler->explodePlaylist($client, 'zvuk://album:999', sub {
		$exploded_album = shift;
	});

	is($sm->getActiveMode($client), undef, 'Stream stopped when explodePlaylist is called on album');
	is_deeply($exploded_album, ['zvuk://301', 'zvuk://302'], 'Album tracks returned correctly');

	# 7. Playlist loadalbum / playalbum CLI commands reset stream
	$sm->startStream($client, 'wave', {});
	is($sm->getActiveMode($client), 'wave', 'Wave active before loadalbum');
	Plugins::Zvuk::Plugin::_onStop($make_req->('playlist', 'loadalbum', 'Rock', 'Queen', 'Opera'));
	is($sm->getActiveMode($client), undef, 'Stream stopped when playlist loadalbum executed');

	$sm->startStream($client, 'atlas', { island_id => 'isl-playalbum' });
	is($sm->getActiveMode($client), 'atlas', 'Atlas active before playalbum');
	Plugins::Zvuk::Plugin::_onStop($make_req->('playlist', 'playalbum', 'Jazz', 'Davis', 'Blue'));
	is($sm->getActiveMode($client), undef, 'Stream stopped when playlist playalbum executed');

	# 8. In-flight request stream isolation: aborted/stopped stream discards tracks
	$sm->startStream($client, 'wave', {});
	my $wave_cb;
	local *Plugins::Zvuk::API::Async::getPersonalWave = sub {
		my ($self, $cb) = @_;
		$wave_cb = $cb;
	};
	$sm->extendQueue($client, 'wave');
	is($sm->isLoading($client), 1, 'Wave extension request in flight');
	ok(defined $wave_cb, 'Captured in-flight callback');

	# User switches to external album while Wave request is in flight
	$sm->stopStream($client);
	is($sm->getActiveMode($client), undef, 'Stream stopped while request in flight');

	@Slim::Control::Request::EXECUTED_REQUESTS = ();
	# Now the deferred Wave API response arrives
	$wave_cb->([{ id => 9991 }, { id => 9992 }]);

	# Verify: ZERO tracks added to playlist, stream remains stopped
	is(scalar(@Slim::Control::Request::EXECUTED_REQUESTS), 0, 'In-flight Wave tracks DISCARDED after stream stopped (no leak into album!)');
	is($sm->getActiveMode($client), undef, 'Stream mode remains undef');
	is($sm->isLoading($client), 0, 'isLoading remains 0');

	# 9. Cross-mode switch with in-flight request: Wave -> Radio
	$sm->startStream($client, 'wave', {});
	my $old_wave_cb;
	local *Plugins::Zvuk::API::Async::getPersonalWave = sub {
		my ($self, $cb) = @_;
		$old_wave_cb = $cb;
	};
	$sm->extendQueue($client, 'wave');

	# User switches to Radio while Wave request is in flight
	$sm->startStream($client, 'radio', { id => 444, type => 'TRACK' });
	my $radio_cb;
	local *Plugins::Zvuk::API::Async::getRecommenderRadio = sub {
		my ($self, $cb) = @_;
		$radio_cb = $cb;
	};
	$sm->extendQueue($client, 'radio');
	is($sm->getActiveMode($client), 'radio', 'Active mode is now radio');
	is($sm->isLoading($client), 1, 'Radio is loading');

	@Slim::Control::Request::EXECUTED_REQUESTS = ();
	# Stale Wave request returns now
	$old_wave_cb->([{ id => 8881 }]);
	is(scalar(@Slim::Control::Request::EXECUTED_REQUESTS), 0, 'Stale Wave tracks NOT appended to Radio stream');
	is($sm->isLoading($client), 1, 'Radio isLoading NOT corrupted by stale Wave callback');

	# Radio request completes
	$radio_cb->({ tracks => [{ id => 4441 }], cursor => 1 });
	is(scalar(@Slim::Control::Request::EXECUTED_REQUESTS), 1, 'Radio track appended properly');
	is($Slim::Control::Request::EXECUTED_REQUESTS[0]{cmd}[2], 'zvuk://4441', 'Added track 4441');
	is($sm->isLoading($client), 0, 'Radio isLoading cleared after its own callback');

	$sm->stopStream($client);
};

# =========================================================================
# 3. GigaMix Stream: Start, Auto-Extension, and Clean Termination
# =========================================================================
subtest 'GigaMix stream lifecycle, auto-extension and clean termination' => sub {
	my $sm = 'Plugins::Zvuk::StreamManager';
	$sm->stopStream($client);

	# A. Protocol Handler URL format & metadata
	is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://gigamix:Synthwave%20Drive'), undef,
		'getFormatForURL returns undef for gigamix URL (treated as playlist container)');
	is(Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://gigamix:'), undef,
		'getFormatForURL returns undef for empty prompt gigamix URL');
	is_deeply(Plugins::Zvuk::ProtocolHandler->getMetadataFor($client, 'zvuk://gigamix:Synthwave%20Drive'), {},
		'getMetadataFor returns empty hash for gigamix URL');
	is(Plugins::Zvuk::ProtocolHandler->canDirectStream('zvuk://gigamix:test'), 0,
		'canDirectStream returns 0');

	# A2. Empty prompt explosion handling
	no warnings qw(once redefine);
	local *Plugins::Zvuk::API::Async::getGenerativePlaylist = sub {
		my ($self, $cb, $args) = @_;
		$cb->({ tracks => [{ id => 9901 }] });
	};
	my $empty_prompt_res;
	Plugins::Zvuk::ProtocolHandler->explodePlaylist($client, 'zvuk://gigamix:', sub {
		$empty_prompt_res = shift;
	});
	is_deeply($empty_prompt_res, ['zvuk://9901'], 'Empty prompt zvuk://gigamix: handled correctly');
	$sm->stopStream($client);

	# B. GigaMix Menu rendering adds "Play GigaMix Stream" item at top
	my $rendered_menu;
	Plugins::Zvuk::UI::GigaMix::_renderGigaMixPlaylist($client, sub { $rendered_menu = shift }, {
		genId        => 'gen_test_1',
		playlistName => 'Cyberpunk Beats',
		cursor       => 'cursor_page_1',
		tracks       => [
			{ id => 701, title => 'Track 1' },
			{ id => 702, title => 'Track 2' },
		],
	}, 'Cyberpunk Beats');

	ok($rendered_menu && $rendered_menu->{items}, 'Menu items returned');
	my $first_item = $rendered_menu->{items}[0];
	is($first_item->{name}, 'PLUGIN_ZVUK_GIGAMIX_PLAY_STREAM', 'Top item is Play GigaMix Stream');
	is($first_item->{line1}, 'PLUGIN_ZVUK_GIGAMIX_PLAY_STREAM', 'Top item has line1 set');
	is($first_item->{url}, 'zvuk://gigamix:Cyberpunk%20Beats', 'Top item URL is zvuk://gigamix:Cyberpunk%20Beats');
	is($first_item->{play}, 'zvuk://gigamix:Cyberpunk%20Beats', 'Top item play is zvuk://gigamix:Cyberpunk%20Beats');
	like($rendered_menu->{items}[1]{name}, qr/^Track 1/, 'Track 1 preserved below stream launcher');

	# C. Explode GigaMix Stream (zvuk://gigamix:Cyberpunk%20Beats)
	my $gql_calls = 0;
	local *Plugins::Zvuk::API::Async::getGenerativePlaylist = sub {
		my ($self, $cb, $args) = @_;
		$gql_calls++;
		is($args->{queryText}, 'Cyberpunk Beats', 'Correct prompt passed to getGenerativePlaylist');
		$cb->({
			playlistName => 'Cyberpunk Beats',
			cursor       => 'cursor_page_2',
			tracks       => [
				{ id => 701, title => 'Track 1' },
				{ id => 702, title => 'Track 2' },
			],
		});
	};

	my $exploded_stream;
	Plugins::Zvuk::ProtocolHandler->explodePlaylist($client, 'zvuk://gigamix:Cyberpunk%20Beats', sub {
		$exploded_stream = shift;
	});

	is($gql_calls, 1, 'getGenerativePlaylist called once on explode');
	is_deeply($exploded_stream, ['zvuk://701', 'zvuk://702'], 'Initial batch of 2 tracks returned');
	is($sm->getActiveMode($client), 'gigamix', 'StreamManager active mode is gigamix');
	is($client->pluginData('zvuk_gigamix_active'), 1, 'zvuk_gigamix_active is 1');
	is($client->pluginData('zvuk_gigamix_cursor'), 'cursor_page_2', 'Next cursor stored');
	is($client->pluginData('zvuk_gigamix_prompt'), 'Cyberpunk Beats', 'Prompt stored');

	# D. Auto-extend GigaMix queue (page with next cursor)
	@Slim::Control::Request::EXECUTED_REQUESTS = ();
	my $page_calls = 0;
	local *Plugins::Zvuk::API::Async::getGenerativePlaylistPage = sub {
		my ($self, $cb, $args) = @_;
		$page_calls++;
		is($args->{cursor}, 'cursor_page_2', 'Correct cursor passed to getGenerativePlaylistPage');
		$cb->({
			cursor => 'cursor_page_3',
			tracks => [
				{ id => 703, title => 'Track 3' },
				{ id => 704, title => 'Track 4' },
			],
		});
	};

	$sm->extendQueue($client, 'gigamix');
	is($page_calls, 1, 'Page 1 auto-extended');
	is(scalar(@Slim::Control::Request::EXECUTED_REQUESTS), 2, '2 tracks added via playlist add');
	is($Slim::Control::Request::EXECUTED_REQUESTS[0]{cmd}[2], 'zvuk://703', 'Added track 703');
	is($Slim::Control::Request::EXECUTED_REQUESTS[1]{cmd}[2], 'zvuk://704', 'Added track 704');
	is($client->pluginData('zvuk_gigamix_cursor'), 'cursor_page_3', 'Cursor updated to cursor_page_3');

	# E. Auto-extend with final page: returns tracks, but cursor is NULL (end of generation)
	@Slim::Control::Request::EXECUTED_REQUESTS = ();
	local *Plugins::Zvuk::API::Async::getGenerativePlaylistPage = sub {
		my ($self, $cb, $args) = @_;
		$page_calls++;
		is($args->{cursor}, 'cursor_page_3', 'Requested final page with cursor_page_3');
		$cb->({
			cursor => undef, # NULL cursor indicates end of stream
			tracks => [
				{ id => 705, title => 'Final Track 5' },
			],
		});
	};

	$sm->extendQueue($client, 'gigamix');
	is(scalar(@Slim::Control::Request::EXECUTED_REQUESTS), 1, 'Final track appended so user can hear it');
	is($Slim::Control::Request::EXECUTED_REQUESTS[0]{cmd}[2], 'zvuk://705', 'Added track 705');
	is($client->pluginData('zvuk_gigamix_cursor'), undef, 'CRITICAL: cursor is undef, stale cursor NOT retained');

	# F. Clean termination: user finishes playing final tracks, queue boundary reached again
	@Slim::Control::Request::NOTIFICATIONS = ();
	@Slim::Control::Request::EXECUTED_REQUESTS = ();
	my $extra_api_calls = 0;
	local *Plugins::Zvuk::API::Async::getGenerativePlaylistPage = sub {
		$extra_api_calls++;
	};

	$sm->extendQueue($client, 'gigamix');

	is($extra_api_calls, 0, 'No more API calls attempted when cursor is null');
	is($sm->getActiveMode($client), undef, 'GigaMix stream cleanly stopped (mode is undef)');
	is($client->pluginData('zvuk_gigamix_active'), 0, 'zvuk_gigamix_active is 0');
	is(scalar(@Slim::Control::Request::NOTIFICATIONS), 1, 'Completion notification sent');
	is($Slim::Control::Request::NOTIFICATIONS[0]{args}[1], 'PLUGIN_ZVUK_GIGAMIX_FINISHED',
		'Notification matches PLUGIN_ZVUK_GIGAMIX_FINISHED');

	# G. Verify NO looping with stale cursor even when queue boundary is met
	local $Slim::Player::Playlist::MOCK_COUNT = 4;
	local $Slim::Player::Source::MOCK_PLAYING_INDEX = 3; # 4 - 3 = 1 <= 2
	$sm->checkAndExtendQueue($client);
	is($extra_api_calls, 0, 'Subsequent checkAndExtendQueue does nothing (no infinite loop)');

	# H. Test gigamix_autoplay preference vs is_stream mode
	# Case H1: normal playlist add (is_stream = 0), autoplay = 0 -> blocked
	$sm->startStream($client, 'gigamix', { prompt => 'Lo-Fi', cursor => 'cur_h', is_stream => 0 });
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{gigamix_autoplay} = 0;
	my $h_calls = 0;
	local *Plugins::Zvuk::API::Async::getGenerativePlaylistPage = sub { $h_calls++ };
	$sm->checkAndExtendQueue($client);
	is($h_calls, 0, 'checkAndExtendQueue blocked when is_stream=0 and gigamix_autoplay=0');

	# Case H2: normal playlist add (is_stream = 0), autoplay = 1 -> allowed
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{gigamix_autoplay} = 1;
	$sm->checkAndExtendQueue($client);
	is($h_calls, 1, 'checkAndExtendQueue allowed when is_stream=0 and gigamix_autoplay=1');

	# Case H3: explicit stream (is_stream = 1), autoplay = 0 -> allowed!
	$sm->startStream($client, 'gigamix', { prompt => 'Lo-Fi', cursor => 'cur_h2', is_stream => 1 });
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{gigamix_autoplay} = 0;
	$sm->checkAndExtendQueue($client);
	is($h_calls, 2, 'checkAndExtendQueue allowed for explicit stream even when gigamix_autoplay=0');

	# Clean up
	$sm->stopStream($client);
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{gigamix_autoplay} = 1;
};

# =========================================================================
# 4. Race Condition Protection (is_loading across all 4 modes)
# =========================================================================
subtest 'Race condition protection with is_loading' => sub {
	my $sm = 'Plugins::Zvuk::StreamManager';
	$sm->stopStream($client);

	# Test 4a: Radio mode concurrency protection
	$sm->startStream($client, 'radio', { id => 888, type => 'TRACK', cursor => 0 });

	no warnings qw(once redefine);
	my @radio_pending_cbs;
	local *Plugins::Zvuk::API::Async::getRecommenderRadio = sub {
		my ($self, $cb, $id, $type, $limit, $cursor) = @_;
		push @radio_pending_cbs, $cb; # defer callback execution
	};

	# Configure playlist boundary so checkAndExtendQueue actually triggers
	local $Slim::Player::Playlist::MOCK_COUNT = 5;
	local $Slim::Player::Source::MOCK_PLAYING_INDEX = 4; # 5 - 4 = 1 <= 2

	# First call starts loading
	is($sm->isLoading($client), 0, 'Initially not loading');
	$sm->extendQueue($client, 'radio');
	is($sm->isLoading($client), 1, 'Now isLoading is 1 while async request in flight');
	is(scalar(@radio_pending_cbs), 1, 'Dispatched 1 request to API');

	# Second and third concurrent calls must be blocked
	$sm->extendQueue($client, 'radio');
	$sm->checkAndExtendQueue($client);
	is(scalar(@radio_pending_cbs), 1, 'Concurrent calls were BLOCKED (still 1 request dispatched)');

	# Resolve deferred request
	my $radio_cb = shift @radio_pending_cbs;
	$radio_cb->({ tracks => [{ id => 901 }], cursor => 1 });

	is($sm->isLoading($client), 0, 'isLoading reset to 0 after response processed');

	# Next call is allowed again
	$sm->extendQueue($client, 'radio');
	is(scalar(@radio_pending_cbs), 1, 'New request permitted after previous finished');
	(shift @radio_pending_cbs)->({ tracks => [], cursor => 2 });

	# Test 4b: Atlas mode concurrency protection
	$sm->startStream($client, 'atlas', { island_id => 'isl-race', cursor => 'c1' });
	my @atlas_pending_cbs;
	local *Plugins::Zvuk::API::Async::getAtlasIslandWave = sub {
		my ($self, $cb, $island_id, $limit, $cursor) = @_;
		push @atlas_pending_cbs, $cb;
	};

	$sm->extendQueue($client, 'atlas');
	is($sm->isLoading($client), 1, 'Atlas is_loading set to 1');
	$sm->extendQueue($client, 'atlas');
	$sm->checkAndExtendQueue($client);
	is(scalar(@atlas_pending_cbs), 1, 'Atlas duplicate call blocked');
	(shift @atlas_pending_cbs)->({ tracks => [{ id => 902 }], next_cursor => 'c2' });
	is($sm->isLoading($client), 0, 'Atlas is_loading cleared');

	# Test 4c: Wave mode concurrency protection
	$sm->startStream($client, 'wave', {});
	my @wave_pending_cbs;
	local *Plugins::Zvuk::API::Async::getPersonalWave = sub {
		my ($self, $cb, $settings, $input) = @_;
		push @wave_pending_cbs, $cb;
	};

	$sm->extendQueue($client, 'wave');
	is($sm->isLoading($client), 1, 'Wave is_loading set to 1');
	$sm->extendQueue($client, 'wave');
	$sm->checkAndExtendQueue($client);
	is(scalar(@wave_pending_cbs), 1, 'Wave duplicate call blocked');
	(shift @wave_pending_cbs)->([{ id => 903 }]);
	is($sm->isLoading($client), 0, 'Wave is_loading cleared');

	# Test 4d: GigaMix mode concurrency protection
	$sm->startStream($client, 'gigamix', { prompt => 'Jazz', cursor => 'cur1', is_stream => 1 });
	my @giga_pending_cbs;
	local *Plugins::Zvuk::API::Async::getGenerativePlaylistPage = sub {
		my ($self, $cb, $args) = @_;
		push @giga_pending_cbs, $cb;
	};

	$sm->extendQueue($client, 'gigamix');
	is($sm->isLoading($client), 1, 'GigaMix is_loading set to 1');
	$sm->extendQueue($client, 'gigamix');
	$sm->checkAndExtendQueue($client);
	is(scalar(@giga_pending_cbs), 1, 'GigaMix duplicate call blocked');
	(shift @giga_pending_cbs)->({ tracks => [{ id => 904 }], cursor => 'cur2' });
	is($sm->isLoading($client), 0, 'GigaMix is_loading cleared');

	# Test 4e: Queue boundary check verification (diff > 2 vs diff <= 2)
	my $boundary_calls = 0;
	local *Plugins::Zvuk::API::Async::getPersonalWave = sub {
		my ($self, $cb) = @_;
		$boundary_calls++;
		$cb->([{ id => 999 }]);
	};
	$sm->startStream($client, 'wave', {});

	# Index far from queue end: count = 10, current = 2 -> diff = 8 > 2
	$Slim::Player::Playlist::MOCK_COUNT = 10;
	$Slim::Player::Source::MOCK_PLAYING_INDEX = 2;
	$sm->checkAndExtendQueue($client);
	is($boundary_calls, 0, 'Queue boundary check: no extension when >2 tracks remain (diff=8)');

	# Index at boundary: count = 10, current = 8 -> diff = 2 <= 2
	$Slim::Player::Source::MOCK_PLAYING_INDEX = 8;
	$sm->checkAndExtendQueue($client);
	is($boundary_calls, 1, 'Queue boundary check: extension triggered when <=2 tracks remain (diff=2)');

	$sm->stopStream($client);
};

done_testing();
