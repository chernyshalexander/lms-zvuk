package Plugins::Zvuk::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Networking::Async::HTTP;
use Time::HiRes qw(time);

use Plugins::Zvuk::API;
use Plugins::Zvuk::API::Async;
use Plugins::Zvuk::WaveSettings;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');
my @pendingMeta;

sub new {
	my ($class, $args) = @_;

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	$log->info("Remote streaming Zvuk track: $streamUrl");

	return $class->SUPER::new({
		url    => $streamUrl,
		song   => $args->{song},
		client => $args->{client},
	});
}

sub register {
	my $class = shift;
	Slim::Player::ProtocolHandlers->registerHandler('zvuk', $class);
}

# Both bare track URLs (zvuk://<id>) and typed media URLs
# (zvuk://episode:<id>) share the same numeric media-content ID space.
sub _parseZvukId {
	my ($url) = @_;
	my ($id) = $url =~ m{zvuk://(?:\w+:)?(\d+)};
	return $id;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->track()->url;
	my $id  = _parseZvukId($url);

	if (!$id) {
		$errorCb->('Invalid Zvuk ID');
		return;
	}

	my $client = $song->master();
	$log->info("Resolving Zvuk stream for track ID: $id");

	# auto-load next batch of wave tracks when approaching end of queue
	if ($client) {
		my $is_wave = $client->pluginData('zvuk_wave_active');
		if ($is_wave) {
			my $playlist_size = Slim::Player::Playlist::count($client);
			my $current_index = Slim::Player::Source::playingSongIndex($client);
			if (defined $playlist_size && defined $current_index
					&& ($playlist_size - $current_index) <= 2) {
				_loadMoreWaveTracks($client);
			}
		}
	}

	# auto-load next batch of GigaMix tracks when approaching end of queue if autoplay enabled
	if ($client && $prefs->get('gigamix_autoplay')) {
		my $is_gigamix = $client->pluginData('zvuk_gigamix_active');
		if ($is_gigamix) {
			my $playlist_size = Slim::Player::Playlist::count($client);
			my $current_index = Slim::Player::Source::playingSongIndex($client);
			if (defined $playlist_size && defined $current_index
					&& ($playlist_size - $current_index) <= 2) {
				_loadMoreGigaMixTracks($client);
			}
		}
	}

	# auto-load next batch of radio tracks when approaching end of queue
	if ($client) {
		my $is_radio = $client->pluginData('zvuk_radio_active');
		if ($is_radio) {
			my $playlist_size = Slim::Player::Playlist::count($client);
			my $current_index = Slim::Player::Source::playingSongIndex($client);
			if (defined $playlist_size && defined $current_index
					&& ($playlist_size - $current_index) <= 2) {
				_loadMoreRadioTracks($client);
			}
		}
	}

	# auto-load next batch of atlas tracks when approaching end of queue
	if ($client) {
		my $is_atlas = $client->pluginData('zvuk_atlas_active');
		if ($is_atlas) {
			my $playlist_size = Slim::Player::Playlist::count($client);
			my $current_index = Slim::Player::Source::playingSongIndex($client);
			if (defined $playlist_size && defined $current_index
					&& ($playlist_size - $current_index) <= 2) {
				_loadMoreAtlasTracks($client);
			}
		}
	}

	my $prefQuality = Plugins::Zvuk::API->getQuality();

	_getAPIHandler($client)->getStream(sub {
		my $data = shift;

		if (!$data || !ref $data || !@$data) {
			$log->error("getStream error for track $id: no response or empty");
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		my $content = $data->[0];
		my $stream  = $content->{stream};
		my $duration = $content->{duration};

		if ($duration) {
			$song->duration($duration);
			Slim::Music::Info::setDuration($song->track, $duration);
		}

		# Record current track info for Wave feedback loop
		if ($client && $client->pluginData('zvuk_wave_active')) {
			$client->pluginData(zvuk_wave_last_track => {
				id       => $id,
				started  => time(),
				duration => $duration || 0,
			});
		}

		my $streamUrl;
		my $format = 'mp3';

		if ($prefQuality eq 'flac') {
			if ($stream->{flac}) {
				$streamUrl = $stream->{flac};
				$format = 'flc';
			} else {
				$streamUrl = $stream->{high} || $stream->{mid};
			}
		} elsif ($prefQuality eq 'high') {
			$streamUrl = $stream->{high} || $stream->{mid};
		} else {
			$streamUrl = $stream->{mid} || $stream->{high};
		}

		if (!$streamUrl) {
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		# 2. Set bitrate estimate
		my $bitrate = ($format eq 'flc') ? 900_000 : ($prefQuality eq 'mid' ? 128_000 : 320_000);
		Slim::Music::Info::setBitrate($song->track, $bitrate);

		$log->info("Resolved Zvuk stream ($format) for track $id: $streamUrl");

		$song->streamUrl($streamUrl);
		$song->pluginData(format => $format);
		$song->track->content_type($format);

		# Update cache with format type for immediate metadata display
		my $cached_meta = Plugins::Zvuk::API->cache->get("zvuk_meta_$id") || {};
		$cached_meta->{type} = $format;
		$cached_meta->{_cached_quality} = Plugins::Zvuk::API->getQuality();
		Plugins::Zvuk::API->cache->set("zvuk_meta_$id", $cached_meta, Plugins::Zvuk::API::DEFAULT_TTL);

		# Parse remote header to get accurate duration/bitrate before playback starts
		# This ensures progress bar and time display are available immediately in SqueezePlay
		require Slim::Utils::Scanner::Remote;

		my $parseCallback = sub {
			$client->currentPlaylistUpdateTime(Time::HiRes::time());
			# Ensure parseRemoteHeader didn't override the format (especially for FLAC)
			$song->track->content_type($format);
			Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

			$successCb->();
		};

		my $errorCallback = sub {
			my ($error) = @_;
			$log->warn("Could not parse $format header for track $id: $error");
			$successCb->();
		};

		Slim::Utils::Scanner::Remote::parseRemoteHeader(
			$song->track, $streamUrl, $format,
			$parseCallback, $errorCallback
		);

	}, [$id]);
}


sub getMetadataFor {
	my ($class, $client, $url) = @_;

	return {} if $url =~ m{^zvuk://(?:album|playlist|artist|radio|atlas):} || $url eq 'zvuk://wave';

	my $id = _parseZvukId($url);
	return {} unless $id;

	my $meta = Plugins::Zvuk::API->cache->get("zvuk_meta_$id");
	if ($meta) {
		my $quality = Plugins::Zvuk::API->getQuality();
		if ($meta->{_cached_quality} && $meta->{_cached_quality} ne $quality) {
			# Quality setting changed since cache was set — invalidate cached type
			delete $meta->{type};
			delete $meta->{_cached_quality};
		}
		$meta->{type} //= $quality eq 'flac' ? 'flc' : 'mp3';
		return $meta;
	}

	my $icon = $class->getIcon();

	my $now = time();
	@pendingMeta = grep { $_->{time} + 60 > $now } @pendingMeta;

	if (!(grep { $_->{id} == $id } @pendingMeta) && scalar(@pendingMeta) < 10) {
		push @pendingMeta, { id => $id, time => $now };
		_getAPIHandler($client)->getTracks(sub {
			my $tracks = shift;
			@pendingMeta = grep { $_->{id} != $id } @pendingMeta;
			return unless $tracks && @$tracks;
			Plugins::Zvuk::API->cacheTrackMetadata($tracks);
			$client->currentPlaylistUpdateTime(time()) if $client;
			Slim::Control::Request::notifyFromArray($client, ['newmetadata']) if $client;
		}, [$id]);
	}

	# Return format type based on quality preference
	# getMetadataFor is called for all tracks in playlist, not just current,
	# so we use the user's quality preference to determine the format
	my $quality = Plugins::Zvuk::API->getQuality();
	my $type = $quality eq 'flac' ? 'flc' : 'mp3';

	return { type => $type, icon => $icon };
}

sub canDirectStream { 0 }

sub canSeek {
	return 1;
}

sub audioScrobblerSource {
	return 'P';
}

sub formatOverride {
	my ($class, $song) = @_;
	return $song->pluginData('format')
		|| (Plugins::Zvuk::API->getQuality() eq 'flac' ? 'flc' : 'mp3');
}

sub getHeaders {
	my ($class, $song) = @_;
	my $headers = $class->SUPER::getHeaders($song) || {};
	$headers->{'User-Agent'} = Plugins::Zvuk::API::USER_AGENT;
	return $headers;
}

sub getFormatForURL {
	my ($class, $url) = @_;
	return if $url =~ m{^zvuk://(?:album|playlist|artist|radio|atlas):} || $url eq 'zvuk://wave';
	my $prefQuality = Plugins::Zvuk::API->getQuality();
	return $prefQuality eq 'flac' ? 'flc' : 'mp3';
}

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack());
}

sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	# Handle Atlas Island Wave (specific island UUID or random)
	if ($url =~ m{^zvuk://atlas:(random|[0-9a-fA-F-]+)}) {
		my $island_id = $1;
		if ($island_id eq 'random') {
			my $api = _getAPIHandler($client);
			if ($api) {
				return $api->getAtlasMap(sub {
					my ($map, $err) = @_;
					my $islands = ($map && ref $map eq 'HASH' && $map->{islands}) ? $map->{islands} : [];
					if (@$islands) {
						my $chosen = $islands->[int(rand(scalar(@$islands)))];
						return _explodeAtlas($client, $chosen->{id}, $cb);
					}
					$log->error("No islands available for random atlas wave: " . ($err || 'empty'));
					$cb->([]);
				});
			}
			return $cb->([]);
		}
		return _explodeAtlas($client, $island_id, $cb);
	}

	# Handle Recommender Radio
	if ($url =~ m{^zvuk://radio:(\w+):(\d+)}) {
		my ($entity_type, $entity_id) = ($1, $2);
		return _explodeRadio($client, $entity_type, $entity_id, $cb);
	}

	my ($type, $id) = $url =~ m{zvuk://(\w+)(?::(\d+))?};
	return $cb->([$url]) unless $type;

	# Handle Personal Wave radio
	if ($type eq 'wave') {
		return _explodeWave($client, $cb);
	}

	return $cb->([$url]) unless $id;

	my %dispatch = (
		album    => 'Plugins::Zvuk::Plugin::handleAlbum',
		playlist => 'Plugins::Zvuk::Plugin::handlePlaylist',
		artist   => 'Plugins::Zvuk::Plugin::handleArtistTracks',
	);

	return $cb->([$url]) unless $dispatch{$type};

	my $handler = $dispatch{$type};
	no strict 'refs';
	$handler->($client, sub {
		my $result = shift;
		my $items = $result->{items} || [];
		my @urls = map { $_->{url} || $_->{play} } grep { $_->{url} || $_->{play} } @$items;
		$cb->(\@urls);
	}, {}, { id => $id });
	use strict 'refs';
}

sub _explodeWave {
	my ($client, $cb) = @_;
	return unless $client;

	$log->info("Loading Personal Wave");

	# Get current account ID
	my $api = _getAPIHandler($client);
	my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

	# Load wave settings for this account
	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);

	# Store in pluginData for later use
	$client->pluginData(zvuk_wave_settings => $wave_settings) if $client;

	$client->pluginData(zvuk_wave_active => 1) if $client;
	$client->pluginData(zvuk_wave_last_track => undef) if $client;

	_getAPIHandler($client)->getPersonalWave(sub {
		my $items = shift || [];
		return unless $items && @$items;

		$log->info("Got " . scalar(@$items) . " wave tracks");
		Plugins::Zvuk::API->cacheTrackMetadata($items);

		my @urls = map { 'zvuk://' . $_->{id} } @$items;
		$cb->(\@urls);
	}, $wave_settings);
}

sub _explodeRadio {
	my ($client, $type, $id, $cb) = @_;

	$type = uc($type // 'TRACK');
	$type = 'RELEASE' if $type eq 'ALBUM';

	$log->info("Starting Recommender Radio for $type $id");

	if ($client) {
		$client->pluginData(zvuk_wave_active => 0);
		$client->pluginData(zvuk_gigamix_active => 0);
		$client->pluginData(zvuk_radio_active => 1);
		$client->pluginData(zvuk_radio_entity_id => $id);
		$client->pluginData(zvuk_radio_entity_type => $type);
		$client->pluginData(zvuk_radio_cursor => 0);
		$client->pluginData(zvuk_radio_loading => 0);
	}

	my $api = _getAPIHandler($client);
	$api->getRecommenderRadio(sub {
		my $res = shift || {};
		my $tracks = $res->{tracks} || [];
		my $cursor = $res->{cursor};

		if (!@$tracks) {
			$log->warn("No tracks returned for radio $type $id");
			$client->pluginData(zvuk_radio_active => 0) if $client;
			return $cb->([]);
		}

		$client->pluginData(zvuk_radio_cursor => $cursor) if $client && defined $cursor;
		$log->info("Got " . scalar(@$tracks) . " radio tracks, cursor: " . ($cursor // 'none'));
		Plugins::Zvuk::API->cacheTrackMetadata($tracks);

		my @urls = map { 'zvuk://' . $_->{id} } @$tracks;
		$cb->(\@urls);
	}, $id, $type, 3, 0);
}

sub _explodeAtlas {
	my ($client, $island_id, $cb) = @_;

	$log->info("Starting Atlas Island Wave for island $island_id");

	if ($client) {
		$client->pluginData(zvuk_wave_active     => 0);
		$client->pluginData(zvuk_gigamix_active  => 0);
		$client->pluginData(zvuk_radio_active    => 0);
		$client->pluginData(zvuk_atlas_active    => 1);
		$client->pluginData(zvuk_atlas_island_id => $island_id);
		$client->pluginData(zvuk_atlas_cursor    => undef);
		$client->pluginData(zvuk_atlas_loading   => 0);
	}

	my $api = _getAPIHandler($client);
	unless ($api) {
		$log->error("No API handler available for client");
		$client->pluginData(zvuk_atlas_active => 0) if $client;
		return $cb->([]);
	}

	my $fetchWave = sub {
		$api->getAtlasIslandWave(sub {
			my ($res, $err) = @_;
			my $tracks = ($res && ref $res eq 'HASH' && $res->{tracks}) ? $res->{tracks} : [];
			my $cursor = $res ? $res->{next_cursor} : undef;

			if (!@$tracks) {
				$log->warn("No tracks returned for atlas island wave $island_id: " . ($err || 'empty'));
				$client->pluginData(zvuk_atlas_active => 0) if $client;
				return $cb->([]);
			}

			$client->pluginData(zvuk_atlas_cursor => $cursor) if $client && defined $cursor;
			$log->info("Got " . scalar(@$tracks) . " atlas wave tracks, cursor: " . ($cursor // 'none'));

			Plugins::Zvuk::API->cacheTrackMetadata($tracks);

			my @urls = map { 'zvuk://' . ($_->{id} || $_->{track_id}) } grep { $_ && ref $_ eq 'HASH' && ($_->{id} || $_->{track_id}) } @$tracks;
			$cb->(\@urls);
		}, $island_id, 3);
	};

	# Optionally notify backend of wave start (PUT)
	if ($api->can('startAtlasIslandWave')) {
		$api->startAtlasIslandWave(sub {
			my ($res, $err) = @_;
			if ($err) {
				$log->debug("startAtlasIslandWave notice: $err (proceeding with GET wave)");
			}
			$fetchWave->();
		}, $island_id);
	} else {
		$fetchWave->();
	}
}

sub isRemote { 1 }

sub getIcon {
	my ( $class, $url ) = @_;
	return Plugins::Zvuk::Plugin->_pluginDataFor('icon');
}

sub _loadMoreWaveTracks {
	my ($client) = @_;
	return unless $client;

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

	# Load stored wave settings (or use defaults)
	my $wave_settings = $client->pluginData('zvuk_wave_settings');
	my $api = _getAPIHandler($client);
	my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
	$wave_settings ||= Plugins::Zvuk::WaveSettings::loadSettings($account_id);

	_getAPIHandler($client)->getPersonalWave(sub {
		my $items = shift || [];
		return unless $items && @$items;

		$log->info("automatically loaded " . scalar(@$items) . " more tracks");
		Plugins::Zvuk::API->cacheTrackMetadata($items);

		for my $track (@$items) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}
	}, $wave_settings, $content_input);
}

sub _loadMoreGigaMixTracks {
	my ($client) = @_;
	return unless $client;

	my $cursor = $client->pluginData('zvuk_gigamix_cursor');
	my $prompt = $client->pluginData('zvuk_gigamix_prompt');
	return unless $cursor && $prompt;

	my $api = _getAPIHandler($client);
	return unless $api;

	$api->getGenerativePlaylistPage(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("GigaMix autoplay: failed to load more tracks: $result->{error}");

			# Clear GigaMix context on error
			$client->pluginData('zvuk_gigamix_active', 0);

			# Show notification to user about the error
			Slim::Control::Request::notifyFromArray($client, [
				'notify', 'GigaMix autoplay error: ' . $result->{error}
			]);
			return;
		}

		my $tracks = $result->{tracks} || [];
		unless (@$tracks) {
			$log->info("GigaMix autoplay: no more tracks available");

			# Clear GigaMix context when no more tracks are available
			$client->pluginData('zvuk_gigamix_active', 0);

			# Notify user that GigaMix has ended
			Slim::Control::Request::notifyFromArray($client, [
				'notify', 'GigaMix playlist complete - no more tracks available'
			]);
			return;
		}

		# Add tracks to playlist
		Plugins::Zvuk::API->cacheTrackMetadata($tracks);

		foreach my $track (@$tracks) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}

		# Update cursor for next auto-extend
		if ($result->{cursor}) {
			$client->pluginData('zvuk_gigamix_cursor', $result->{cursor});
		}

		$log->info("GigaMix: auto-extended playlist with " . scalar(@$tracks) . " tracks");
	}, { cursor => $cursor, limit => 5 });
}

sub _loadMoreRadioTracks {
	my ($client) = @_;
	return unless $client;

	if ($client->pluginData('zvuk_radio_loading')) {
		$log->debug("Radio batch already loading, skipping duplicate request");
		return;
	}

	my $id     = $client->pluginData('zvuk_radio_entity_id');
	my $type   = $client->pluginData('zvuk_radio_entity_type');
	my $cursor = $client->pluginData('zvuk_radio_cursor') // 0;
	return unless defined $id && defined $type;

	my $api = _getAPIHandler($client);
	return unless $api;

	$client->pluginData(zvuk_radio_loading => 1);
	$log->info("Auto-loading more radio tracks for $type $id at cursor $cursor");

	$api->getRecommenderRadio(sub {
		my $res = shift || {};
		$client->pluginData(zvuk_radio_loading => 0) if $client;

		if ($res->{error}) {
			$log->error("Radio auto-load failed: $res->{error}");
			$client->pluginData(zvuk_radio_active => 0) if $client;
			return;
		}

		my $tracks = $res->{tracks} || [];
		unless (@$tracks) {
			$log->info("Radio complete: no more tracks available from Zvuk");
			$client->pluginData(zvuk_radio_active => 0) if $client;
			return;
		}

		my $new_cursor = $res->{cursor};
		$client->pluginData(zvuk_radio_cursor => $new_cursor) if $client && defined $new_cursor;

		Plugins::Zvuk::API->cacheTrackMetadata($tracks);
		$log->info("Radio: auto-extended playlist with " . scalar(@$tracks) . " tracks, next cursor: " . ($new_cursor // 'none'));

		for my $track (@$tracks) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}
	}, $id, $type, 3, $cursor);
}

sub _loadMoreAtlasTracks {
	my ($client) = @_;
	return unless $client;

	if ($client->pluginData('zvuk_atlas_loading')) {
		$log->debug("Atlas batch already loading, skipping duplicate request");
		return;
	}

	my $island_id = $client->pluginData('zvuk_atlas_island_id');
	my $cursor    = $client->pluginData('zvuk_atlas_cursor');
	return unless defined $island_id;

	my $api = _getAPIHandler($client);
	return unless $api;

	$client->pluginData(zvuk_atlas_loading => 1);
	$log->info("Auto-loading more atlas tracks for island $island_id at cursor " . ($cursor // 'none'));

	$api->getAtlasIslandWave(sub {
		my ($res, $err) = @_;
		$client->pluginData(zvuk_atlas_loading => 0) if $client;

		if ($err || !$res) {
			$log->error("Atlas auto-load failed: " . ($err || 'no response'));
			$client->pluginData(zvuk_atlas_active => 0) if $client;
			return;
		}

		my $tracks = ($res && ref $res eq 'HASH' && $res->{tracks}) ? $res->{tracks} : [];
		unless (@$tracks) {
			$log->info("Atlas wave complete: no more tracks available from Zvuk");
			$client->pluginData(zvuk_atlas_active => 0) if $client;
			return;
		}

		my $new_cursor = $res->{next_cursor};
		$client->pluginData(zvuk_atlas_cursor => $new_cursor) if $client;

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

sub _getAPIHandler {
	my ($client) = @_;

	if (ref $client) {
		# Delegate to Plugin.pm's resolver instead of keeping our own
		# pluginData-cached copy: that cache never got invalidated on
		# account switch, so Wave/streaming kept using the old account.
		return Plugins::Zvuk::Plugin::_get_api_client($client);
	} else {
		my $userId = Plugins::Zvuk::API->getSomeUserId();
		return Plugins::Zvuk::API::Async->new({ userId => $userId });
	}
}

1;
