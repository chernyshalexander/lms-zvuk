package Plugins::Zvuk::StreamManager;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Time::HiRes qw(time);

use Plugins::Zvuk::API;
use Plugins::Zvuk::WaveSettings;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

my $STREAM_COUNTER = 0;

# -------------------------------------------------------------------
# Stream Lifecycle Management
# -------------------------------------------------------------------

sub startStream {
	my ($class, $client, $mode, $params) = @_;
	return unless $client && $mode;
	$params ||= {};

	$log->info("StreamManager: starting stream mode='$mode'");

	$STREAM_COUNTER++;

	# Atomic unified state
	my $stream = {
		mode       => $mode,
		is_loading => 0,
		stream_id  => $STREAM_COUNTER,
		context    => { %$params },
	};
	$client->pluginData(zvuk_stream => $stream);

	# Backwards-compatibility sync of active mode flags
	$client->pluginData(zvuk_wave_active    => ($mode eq 'wave'    ? 1 : 0));
	$client->pluginData(zvuk_radio_active   => ($mode eq 'radio'   ? 1 : 0));
	$client->pluginData(zvuk_atlas_active   => ($mode eq 'atlas'   ? 1 : 0));
	$client->pluginData(zvuk_gigamix_active => ($mode eq 'gigamix' ? 1 : 0));

	# Sync mode-specific context and clean other modes' context
	if ($mode eq 'wave') {
		$client->pluginData(zvuk_wave_settings   => $params->{settings}) if exists $params->{settings};
		$client->pluginData(zvuk_wave_last_track => undef);

		$client->pluginData(zvuk_radio_entity_id   => undef);
		$client->pluginData(zvuk_radio_entity_type => undef);
		$client->pluginData(zvuk_radio_cursor      => undef);
		$client->pluginData(zvuk_radio_loading     => 0);
		$client->pluginData(zvuk_atlas_island_id   => undef);
		$client->pluginData(zvuk_atlas_cursor      => undef);
		$client->pluginData(zvuk_atlas_loading     => 0);
		$client->pluginData(zvuk_gigamix_cursor    => undef);
		$client->pluginData(zvuk_gigamix_prompt    => undef);
	} elsif ($mode eq 'radio') {
		$client->pluginData(zvuk_radio_entity_id   => $params->{id});
		$client->pluginData(zvuk_radio_entity_type => $params->{type});
		$client->pluginData(zvuk_radio_cursor      => $params->{cursor} // 0);
		$client->pluginData(zvuk_radio_loading     => 0);

		$client->pluginData(zvuk_wave_last_track   => undef);
		$client->pluginData(zvuk_atlas_island_id   => undef);
		$client->pluginData(zvuk_atlas_cursor      => undef);
		$client->pluginData(zvuk_atlas_loading     => 0);
		$client->pluginData(zvuk_gigamix_cursor    => undef);
		$client->pluginData(zvuk_gigamix_prompt    => undef);
	} elsif ($mode eq 'atlas') {
		$client->pluginData(zvuk_atlas_island_id => $params->{island_id});
		$client->pluginData(zvuk_atlas_cursor    => $params->{cursor});
		$client->pluginData(zvuk_atlas_loading   => 0);

		$client->pluginData(zvuk_wave_last_track   => undef);
		$client->pluginData(zvuk_radio_entity_id   => undef);
		$client->pluginData(zvuk_radio_entity_type => undef);
		$client->pluginData(zvuk_radio_cursor      => undef);
		$client->pluginData(zvuk_radio_loading     => 0);
		$client->pluginData(zvuk_gigamix_cursor    => undef);
		$client->pluginData(zvuk_gigamix_prompt    => undef);
	} elsif ($mode eq 'gigamix') {
		$client->pluginData(zvuk_gigamix_cursor => $params->{cursor});
		$client->pluginData(zvuk_gigamix_prompt => $params->{prompt});

		$client->pluginData(zvuk_wave_last_track   => undef);
		$client->pluginData(zvuk_radio_entity_id   => undef);
		$client->pluginData(zvuk_radio_entity_type => undef);
		$client->pluginData(zvuk_radio_cursor      => undef);
		$client->pluginData(zvuk_radio_loading     => 0);
		$client->pluginData(zvuk_atlas_island_id   => undef);
		$client->pluginData(zvuk_atlas_cursor      => undef);
		$client->pluginData(zvuk_atlas_loading     => 0);
	}

	return $stream;
}

sub stopStream {
	my ($class, $client) = @_;
	return unless $client;

	$log->debug("StreamManager: stopping active stream");

	$client->pluginData(zvuk_stream => {
		mode       => undef,
		is_loading => 0,
		stream_id  => 0,
		context    => {},
	});

	# Clear legacy active flags
	$client->pluginData(zvuk_wave_active    => 0);
	$client->pluginData(zvuk_radio_active   => 0);
	$client->pluginData(zvuk_atlas_active   => 0);
	$client->pluginData(zvuk_gigamix_active => 0);

	# Clear legacy context fields
	$client->pluginData(zvuk_radio_entity_id   => undef);
	$client->pluginData(zvuk_radio_entity_type => undef);
	$client->pluginData(zvuk_radio_cursor      => undef);
	$client->pluginData(zvuk_radio_loading     => 0);

	$client->pluginData(zvuk_atlas_island_id   => undef);
	$client->pluginData(zvuk_atlas_cursor      => undef);
	$client->pluginData(zvuk_atlas_loading     => 0);

	$client->pluginData(zvuk_gigamix_cursor    => undef);
	$client->pluginData(zvuk_gigamix_prompt    => undef);

	$client->pluginData(zvuk_wave_last_track   => undef);
	$client->pluginData(zvuk_wave_settings     => undef);
}

sub getActiveMode {
	my ($class, $client) = @_;
	return unless $client;

	my $stream = $client->pluginData('zvuk_stream');
	if ($stream && ref $stream eq 'HASH' && $stream->{mode}) {
		return $stream->{mode};
	}

	# Legacy flag fallback
	return 'wave'    if $client->pluginData('zvuk_wave_active');
	return 'radio'   if $client->pluginData('zvuk_radio_active');
	return 'atlas'   if $client->pluginData('zvuk_atlas_active');
	return 'gigamix' if $client->pluginData('zvuk_gigamix_active');

	return undef;
}

sub isLoading {
	my ($class, $client) = @_;
	return 0 unless $client;

	my $stream = $client->pluginData('zvuk_stream');
	if ($stream && ref $stream eq 'HASH' && $stream->{is_loading}) {
		return 1;
	}

	# Legacy loading flags fallback
	return 1 if $client->pluginData('zvuk_radio_loading');
	return 1 if $client->pluginData('zvuk_atlas_loading');

	return 0;
}

sub _setLoading {
	my ($class, $client, $loading) = @_;
	return unless $client;

	my $stream = $client->pluginData('zvuk_stream');
	if (!$stream || ref $stream ne 'HASH') {
		$stream = {
			mode       => $class->getActiveMode($client),
			is_loading => 0,
			context    => {},
		};
		$client->pluginData(zvuk_stream => $stream);
	}
	$stream->{is_loading} = $loading ? 1 : 0;

	# Sync legacy flags
	my $mode = $stream->{mode} || $class->getActiveMode($client);
	if ($mode && $mode eq 'radio') {
		$client->pluginData(zvuk_radio_loading => ($loading ? 1 : 0));
	} elsif ($mode && $mode eq 'atlas') {
		$client->pluginData(zvuk_atlas_loading => ($loading ? 1 : 0));
	}
}

sub updateContext {
	my ($class, $client, $updates) = @_;
	return unless $client && $updates && ref $updates eq 'HASH';

	my $stream = $client->pluginData('zvuk_stream');
	if (!$stream || ref $stream ne 'HASH') {
		$stream = {
			mode       => $class->getActiveMode($client),
			is_loading => 0,
			context    => {},
		};
		$client->pluginData(zvuk_stream => $stream);
	}
	$stream->{context} ||= {};
	while (my ($k, $v) = each %$updates) {
		$stream->{context}{$k} = $v;
	}

	# Sync corresponding legacy keys
	my $mode = $stream->{mode} || $class->getActiveMode($client);
	if (exists $updates->{cursor}) {
		if ($mode && $mode eq 'radio') {
			$client->pluginData(zvuk_radio_cursor => $updates->{cursor});
		} elsif ($mode && $mode eq 'atlas') {
			$client->pluginData(zvuk_atlas_cursor => $updates->{cursor});
		} elsif ($mode && $mode eq 'gigamix') {
			$client->pluginData(zvuk_gigamix_cursor => $updates->{cursor});
		}
	}
	if (exists $updates->{prompt} && $mode && $mode eq 'gigamix') {
		$client->pluginData(zvuk_gigamix_prompt => $updates->{prompt});
	}
}

sub getContext {
	my ($class, $client) = @_;
	return {} unless $client;

	my $stream = $client->pluginData('zvuk_stream');
	if ($stream && ref $stream eq 'HASH' && $stream->{context}) {
		return $stream->{context};
	}
	return {};
}

# -------------------------------------------------------------------
# Queue Extension & Race Condition Prevention
# -------------------------------------------------------------------

sub checkAndExtendQueue {
	my ($class, $client) = @_;
	return unless $client;

	my $mode = $class->getActiveMode($client);
	return unless $mode;

	# GigaMix respects gigamix_autoplay pref unless explicitly launched as a stream
	if ($mode eq 'gigamix') {
		my $ctx = $class->getContext($client);
		my $is_stream = ($ctx && $ctx->{is_stream}) ? 1 : 0;
		my $autoplay = $prefs && $prefs->get('gigamix_autoplay');
		unless ($is_stream || $autoplay) {
			return;
		}
	}

	# Check queue boundary (<= 2 tracks remaining)
	my $playlist_size = Slim::Player::Playlist::count($client);
	my $current_index = Slim::Player::Source::playingSongIndex($client);
	return unless defined $playlist_size && defined $current_index;
	return unless ($playlist_size - $current_index) <= 2;

	# Guard against concurrent loading across ALL modes
	if ($class->isLoading($client)) {
		$log->debug("StreamManager: batch already loading for mode '$mode', skipping duplicate request");
		return;
	}

	$class->extendQueue($client, $mode);
}

sub extendQueue {
	my ($class, $client, $mode) = @_;
	return unless $client;
	$mode ||= $class->getActiveMode($client);
	return unless $mode;

	if ($class->isLoading($client)) {
		$log->debug("StreamManager: batch already loading for mode '$mode', skipping duplicate request");
		return;
	}

	$class->_setLoading($client, 1);

	if ($mode eq 'wave') {
		$class->_extendWave($client);
	} elsif ($mode eq 'radio') {
		$class->_extendRadio($client);
	} elsif ($mode eq 'atlas') {
		$class->_extendAtlas($client);
	} elsif ($mode eq 'gigamix') {
		$class->_extendGigaMix($client);
	} else {
		$log->warn("StreamManager: unknown stream mode '$mode'");
		$class->_setLoading($client, 0);
	}
}

# -------------------------------------------------------------------
# Mode Drivers
# -------------------------------------------------------------------

sub _extendWave {
	my ($class, $client) = @_;
	return unless $client;

	my $stream    = $client->pluginData('zvuk_stream');
	my $stream_id = ($stream && ref $stream eq 'HASH') ? $stream->{stream_id} : undef;

	my $content_input;
	my $last = $client->pluginData('zvuk_wave_last_track');
	if ($last && $last->{id}) {
		my $elapsed       = time() - ($last->{started} || time());
		my $play_duration = ($last->{duration} && $elapsed > $last->{duration}) ? $last->{duration} : $elapsed;
		my $is_skipped    = ($last->{duration} && $play_duration < ($last->{duration} * 0.5)) ? \1 : \0;

		$content_input = {
			trackId       => $last->{id},
			trackDuration => int($last->{duration} || 0),
			playDuration  => int($play_duration),
			isSkipped     => $is_skipped,
		};
	}

	my $wave_settings = $client->pluginData('zvuk_wave_settings')
		// ($class->getContext($client)->{settings});
	my $api = $class->_getAPIHandler($client);
	unless ($api) {
		$class->_setLoading($client, 0);
		return;
	}
	my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
	$wave_settings ||= Plugins::Zvuk::WaveSettings::loadSettings($account_id);

	$api->getPersonalWave(sub {
		my $items = shift || [];

		# Verify stream is still active, still in wave mode, and hasn't changed instance
		my $curr = $client->pluginData('zvuk_stream');
		unless ($curr && ref $curr eq 'HASH'
			&& defined $curr->{mode} && $curr->{mode} eq 'wave'
			&& (!defined $stream_id || ($curr->{stream_id} // 0) == $stream_id))
		{
			$log->info("StreamManager: wave stream aborted or changed while request in flight, discarding batch");
			return;
		}

		$class->_setLoading($client, 0);

		return unless $items && @$items;

		$log->info("StreamManager: automatically loaded " . scalar(@$items) . " more wave tracks");
		Plugins::Zvuk::API->cacheTrackMetadata($items);

		for my $track (@$items) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}
	}, $wave_settings, $content_input);
}

sub _extendRadio {
	my ($class, $client) = @_;
	return unless $client;

	my $stream    = $client->pluginData('zvuk_stream');
	my $stream_id = ($stream && ref $stream eq 'HASH') ? $stream->{stream_id} : undef;

	my $ctx    = $class->getContext($client);
	my $id     = $client->pluginData('zvuk_radio_entity_id')   // $ctx->{id};
	my $type   = $client->pluginData('zvuk_radio_entity_type') // $ctx->{type};
	my $cursor = $client->pluginData('zvuk_radio_cursor')      // $ctx->{cursor} // 0;

	unless (defined $id && defined $type) {
		$class->_setLoading($client, 0);
		return;
	}

	my $api = $class->_getAPIHandler($client);
	unless ($api) {
		$class->_setLoading($client, 0);
		return;
	}

	$log->info("StreamManager: auto-loading more radio tracks for $type $id at cursor $cursor");

	$api->getRecommenderRadio(sub {
		my $res = shift || {};

		# Verify stream is still active, still in radio mode, and hasn't changed instance
		my $curr = $client->pluginData('zvuk_stream');
		unless ($curr && ref $curr eq 'HASH'
			&& defined $curr->{mode} && $curr->{mode} eq 'radio'
			&& (!defined $stream_id || ($curr->{stream_id} // 0) == $stream_id))
		{
			$log->info("StreamManager: radio stream aborted or changed while request in flight, discarding batch");
			return;
		}

		$class->_setLoading($client, 0);

		if ($res->{error}) {
			$log->error("Radio auto-load failed: $res->{error}");
			$class->stopStream($client);
			return;
		}

		my $tracks = $res->{tracks} || [];
		unless (@$tracks) {
			$log->info("Radio complete: no more tracks available from Zvuk");
			$class->stopStream($client);
			return;
		}

		my $new_cursor = $res->{cursor};
		$class->updateContext($client, { cursor => $new_cursor });
		$client->pluginData(zvuk_radio_cursor => $new_cursor) if defined $new_cursor;

		Plugins::Zvuk::API->cacheTrackMetadata($tracks);
		$log->info("Radio: auto-extended playlist with " . scalar(@$tracks) . " tracks, next cursor: " . ($new_cursor // 'none'));

		for my $track (@$tracks) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}
	}, $id, $type, 3, $cursor);
}

sub _extendAtlas {
	my ($class, $client) = @_;
	return unless $client;

	my $stream    = $client->pluginData('zvuk_stream');
	my $stream_id = ($stream && ref $stream eq 'HASH') ? $stream->{stream_id} : undef;

	my $ctx       = $class->getContext($client);
	my $island_id = $client->pluginData('zvuk_atlas_island_id') // $ctx->{island_id};
	my $cursor    = $client->pluginData('zvuk_atlas_cursor')    // $ctx->{cursor};

	unless (defined $island_id) {
		$class->_setLoading($client, 0);
		return;
	}

	my $api = $class->_getAPIHandler($client);
	unless ($api) {
		$class->_setLoading($client, 0);
		return;
	}

	$log->info("StreamManager: auto-loading more atlas tracks for island $island_id at cursor " . ($cursor // 'none'));

	$api->getAtlasIslandWave(sub {
		my ($res, $err) = @_;

		# Verify stream is still active, still in atlas mode, and hasn't changed instance
		my $curr = $client->pluginData('zvuk_stream');
		unless ($curr && ref $curr eq 'HASH'
			&& defined $curr->{mode} && $curr->{mode} eq 'atlas'
			&& (!defined $stream_id || ($curr->{stream_id} // 0) == $stream_id))
		{
			$log->info("StreamManager: atlas stream aborted or changed while request in flight, discarding batch");
			return;
		}

		$class->_setLoading($client, 0);

		if ($err || !$res) {
			$log->error("Atlas auto-load failed: " . ($err || 'no response'));
			$class->stopStream($client);
			return;
		}

		my $tracks = ($res && ref $res eq 'HASH' && $res->{tracks}) ? $res->{tracks} : [];
		unless (@$tracks) {
			$log->info("Atlas wave complete: no more tracks available from Zvuk");
			$class->stopStream($client);
			return;
		}

		my $new_cursor = $res->{next_cursor};
		$class->updateContext($client, { cursor => $new_cursor });
		$client->pluginData(zvuk_atlas_cursor => $new_cursor);

		Plugins::Zvuk::API->cacheTrackMetadata($tracks);
		$log->info("Atlas: auto-extended playlist with " . scalar(@$tracks) . " tracks, next cursor: " . ($new_cursor // 'none'));

		for my $track (@$tracks) {
			next unless $track && ref $track eq 'HASH';
			my $tid = $track->{id} || $track->{track_id};
			next unless $tid;
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $tid]
			);
		}
	}, $island_id, 3, $cursor);
}

sub _extendGigaMix {
	my ($class, $client) = @_;
	return unless $client;

	my $stream    = $client->pluginData('zvuk_stream');
	my $stream_id = ($stream && ref $stream eq 'HASH') ? $stream->{stream_id} : undef;

	my $ctx    = $class->getContext($client);
	my $cursor = $client->pluginData('zvuk_gigamix_cursor') // $ctx->{cursor};
	my $prompt = $client->pluginData('zvuk_gigamix_prompt') // $ctx->{prompt};

	# Honest completion: when cursor is null / missing, stop cleanly
	unless (defined $cursor && length($cursor) && defined $prompt) {
		$log->info("StreamManager: GigaMix stream finished (cursor is null). Clean stop.");
		$class->stopStream($client);
		$class->_setLoading($client, 0);
		Slim::Control::Request::notifyFromArray($client, [
			'notify', cstring($client, 'PLUGIN_ZVUK_GIGAMIX_FINISHED')
		]);
		return;
	}

	my $api = $class->_getAPIHandler($client);
	unless ($api) {
		$class->_setLoading($client, 0);
		$class->stopStream($client);
		return;
	}

	$log->info("StreamManager: GigaMix autoplay loading page with cursor='$cursor'");

	$api->getGenerativePlaylistPage(sub {
		my $result = shift || {};

		# Verify stream is still active, still in gigamix mode, and hasn't changed instance
		my $curr = $client->pluginData('zvuk_stream');
		unless ($curr && ref $curr eq 'HASH'
			&& defined $curr->{mode} && $curr->{mode} eq 'gigamix'
			&& (!defined $stream_id || ($curr->{stream_id} // 0) == $stream_id))
		{
			$log->info("StreamManager: gigamix stream aborted or changed while request in flight, discarding batch");
			return;
		}

		$class->_setLoading($client, 0);

		if ($result->{error}) {
			$log->error("GigaMix autoplay: failed to load more tracks: $result->{error}");
			$class->stopStream($client);
			Slim::Control::Request::notifyFromArray($client, [
				'notify', 'GigaMix autoplay error: ' . $result->{error}
			]);
			return;
		}

		my $tracks = $result->{tracks} || [];
		my $new_cursor = $result->{cursor};

		unless (@$tracks) {
			$log->info("GigaMix autoplay: no more tracks available");
			$class->stopStream($client);
			Slim::Control::Request::notifyFromArray($client, [
				'notify', cstring($client, 'PLUGIN_ZVUK_GIGAMIX_FINISHED')
			]);
			return;
		}

		# Add tracks to playlist
		Plugins::Zvuk::API->cacheTrackMetadata($tracks);
		for my $track (@$tracks) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}

		# CRITICAL: Update cursor. If $new_cursor is undef/null, it is explicitly set to undef!
		# NEVER retain stale cursor!
		$class->updateContext($client, { cursor => $new_cursor });
		$client->pluginData(zvuk_gigamix_cursor => $new_cursor);

		if (!defined $new_cursor || !length($new_cursor)) {
			$log->info("GigaMix: received final batch of " . scalar(@$tracks) . " tracks (cursor is null). Will complete when played.");
		} else {
			$log->info("GigaMix: auto-extended playlist with " . scalar(@$tracks) . " tracks, next cursor: $new_cursor");
		}
	}, { cursor => $cursor, limit => 5 });
}

# -------------------------------------------------------------------
# External Playlist Change Isolation & Event Hook
# -------------------------------------------------------------------

sub isStreamURL {
	my ($class, $url) = @_;
	return 0 unless defined $url;
	return 1 if $url =~ m{^zvuk://wave(?:[?:]|$)};
	return 1 if $url =~ m{^zvuk://radio:};
	return 1 if $url =~ m{^zvuk://atlas:};
	return 1 if $url =~ m{^zvuk://gigamix:};
	return 0;
}

sub onPlaylistChange {
	my ($class, $request) = @_;
	return unless $request;
	my $client = $request->client();
	return unless $client;

	my $action    = $request->getRequest(0) // '';
	my $subaction = $request->getRequest(1) // '';

	# 1. Stop playback
	if ($action eq 'stop') {
		$class->stopStream($client);
		return;
	}

	# 2. Playlist clear
	if ($action eq 'playlist' && $subaction eq 'clear') {
		$class->stopStream($client);
		return;
	}

	# 3. Non-stream URL or album is played or loaded
	if ($action eq 'playlist') {
		if ($subaction eq 'loadalbum' || $subaction eq 'playalbum') {
			$log->info("StreamManager: external album command '$subaction' executed, resetting active stream");
			$class->stopStream($client);
			return;
		}
		if ($subaction eq 'play' || $subaction eq 'loadtracks' || $subaction eq 'open') {
			my $url = $request->getRequest(2);
			if (defined $url && !$class->isStreamURL($url)) {
				$log->info("StreamManager: external URL '$url' played, resetting active stream");
				$class->stopStream($client);
				return;
			}
		}
	}
}

# -------------------------------------------------------------------
# API Client Helper
# -------------------------------------------------------------------

sub _getAPIHandler {
	my ($class, $client) = @_;
	if (ref $client && eval { require Plugins::Zvuk::Plugin; Plugins::Zvuk::Plugin->can('_get_api_client') }) {
		my $api = Plugins::Zvuk::Plugin::_get_api_client($client);
		return $api if $api;
	}
	my $userId = Plugins::Zvuk::API->getSomeUserId();
	return Plugins::Zvuk::API::Async->new({ userId => $userId });
}

1;
