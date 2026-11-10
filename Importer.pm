package Plugins::Zvuk::Importer;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::OnlineLibraryBase);

use Digest::MD5 qw(md5_hex);
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Versions;
use Plugins::Zvuk::API;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $cache = Slim::Utils::Cache->new();
my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

my ($ct, $splitChar);
my $previousArtistId = '';

sub initPlugin {
	my $class = shift;

	if (!CAN_IMPORTER) {
		$log->warn('ZVUK: Library importer requires Lyrion Music Server 8.0.0+');
		return;
	}

	if (!main::SCANNER) {
		return;
	}

	$class->SUPER::initPlugin(@_);
}

sub startScan { if (main::SCANNER) {
	my ($class) = @_;

	require Plugins::Zvuk::API::Sync;
	$ct = (Plugins::Zvuk::API->getQuality() eq 'flac') ? 'flc' : 'mp3';
	$splitChar = substr(Slim::Utils::Prefs::preferences('server')->get('splitList') || ';', 0, 1);

	my $accounts = _enabledAccounts();

	if (scalar keys %$accounts) {
		my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();

		$class->initOnlineTracksTable();

		if (!$playlistsOnly) {
			$class->scanAlbums($accounts);
			$class->scanArtists($accounts);
		}

		if (!$class->can('ignorePlaylists') || !$class->ignorePlaylists) {
			$class->scanPlaylists($accounts);
		}

		$class->deleteRemovedTracks();
		$cache->set('zvuk_library_last_scan', time(), '1y');

		# Save library fingerprint for needsUpdate() to detect future changes
		my ($anyUserId) = values %$accounts;
		if ($anyUserId) {
			$log->is_info && $log->info("Zvuk startScan: computing library fingerprint for caching");
			my $fingerprint = Plugins::Zvuk::API::Sync->get_library_fingerprint($anyUserId);
			if ($fingerprint) {
				$cache->set('zvuk_library_fingerprint', $fingerprint, '1y');
				$log->is_info && $log->info("Zvuk startScan: saved fingerprint=$fingerprint to cache");
			} else {
				$log->is_info && $log->info("Zvuk startScan: failed to compute fingerprint, skipping cache");
			}
		}
	}

	Slim::Music::Import->endImporter($class);
} }

sub scanAlbums { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_zvuk_albums',
		'total' => 1,
		'every' => 1,
	});

	while (my ($accountName, $userId) = each %$accounts) {
		my %missingAlbums;

		$progress->update(string('PLUGIN_ZVUK_PROGRESS_READ_ALBUMS', $accountName));

		my $albums = Plugins::Zvuk::API::Sync->users_likes_albums($userId) || [];
		$progress->total(scalar @$albums);

		foreach my $album (@$albums) {
			my $albumId = $album->{id} or next;
			my $albumDetails = $cache->get('zvuk_album_with_tracks_' . $albumId);

			if ($albumDetails && $albumDetails->{tracks} && ref $albumDetails->{tracks}) {
				$progress->update($album->{title});

				$class->storeTracks([
					map { _prepareTrack($albumDetails, $_) } _flattenTracksWithNumbers($albumDetails)
				], undef, $accountName);

				main::SCANNER && Slim::Schema->forceCommit;
			}
			else {
				$missingAlbums{$albumId} = $album;
			}
		}

		while (my ($albumId, $album) = each %missingAlbums) {
			$progress->update($album->{title});

			my $albumDetails = Plugins::Zvuk::API::Sync->get_album_with_tracks($albumId, $userId);

			if (!$albumDetails || !$albumDetails->{tracks}) {
				$log->warn("Didn't receive tracks for " . ($album->{title} || 'unknown') . "/$albumId");
				next;
			}

			$albumDetails->{title} ||= $album->{title};
			$albumDetails->{image} ||= $album->{image};

			$cache->set('zvuk_album_with_tracks_' . $albumId, $albumDetails, '3M');

			$class->storeTracks([
				map { _prepareTrack($albumDetails, $_) } _flattenTracksWithNumbers($albumDetails)
			], undef, $accountName);

			main::SCANNER && Slim::Schema->forceCommit;
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanArtists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_zvuk_artists',
		'total' => 1,
		'every' => 1,
	});

	$previousArtistId = '';

	while (my ($accountName, $userId) = each %$accounts) {
		$progress->update(string('PLUGIN_ZVUK_PROGRESS_READ_ARTISTS', $accountName));

		my $artists = Plugins::Zvuk::API::Sync->users_likes_artists($userId) || [];
		$progress->total($progress->total + scalar @$artists);

		foreach my $artist (@$artists) {
			my $name = $artist->{title} or next;

			$progress->update($name);
			main::SCANNER && Slim::Schema->forceCommit;

			my $artistData = {
				'artist' => $class->normalizeContributorName($name),
				'extid'  => 'zvuk:artist:' . $artist->{id},
			};

			if ($artist->{image} || $artist->{cover}) {
				my $cover = Plugins::Zvuk::API->getImageUrl($artist);
				$artistData->{cover} = $cover if $cover;
			}

			Slim::Schema::Contributor->add($artistData);

			_cacheArtistPicture($artist, '3M');
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanPlaylists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $dbh = Slim::Schema->dbh();
	my $insertTrackInTempTable_sth = $dbh->prepare_cached("INSERT OR IGNORE INTO online_tracks (url) VALUES (?)") if !$main::wipe;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_zvuk_playlists',
		'total' => 0,
		'every' => 1,
	});

	$progress->update(string('PLAYLIST_DELETED_PROGRESS'), $progress->done);
	my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'zvuk://playlist:%'");
	$deletePlaylists_sth->execute();

	while (my ($accountName, $userId) = each %$accounts) {
		$progress->update(string('PLUGIN_ZVUK_PROGRESS_READ_PLAYLISTS', $accountName));

		my $playlists = Plugins::Zvuk::API::Sync->users_likes_playlists($userId) || [];
		$progress->total($progress->total + @$playlists);

		my $prefix = 'Zvuk' . string('COLON') . ' ';

		foreach my $playlist (@{$playlists || []}) {
			my $id = $playlist->{id} or next;

			my $tracks = Plugins::Zvuk::API::Sync->get_playlist_tracks($id, $userId) || [];

			$progress->update($accountName . string('COLON') . ' ' . $playlist->{title});
			Slim::Schema->forceCommit;

			my $url = "zvuk://playlist:$id";
			my $cover = $playlist->{image} ? Plugins::Zvuk::API->getImageUrl($playlist) : '';

			my $playlistObj = Slim::Schema->updateOrCreate({
				url             => $url,
				playlist        => 1,
				integrateRemote => 1,
				attributes      => {
					TITLE        => $prefix . $playlist->{title},
					COVER        => $cover,
					AUDIO        => 1,
					EXTID        => $url,
					CONTENT_TYPE => 'ssp',
				},
			});

			my @trackIds = map { "zvuk://$_->{id}" } @$tracks;

			$playlistObj->setTracks(\@trackIds) if $playlistObj && scalar @trackIds;
			$insertTrackInTempTable_sth && $insertTrackInTempTable_sth->execute($url);
		}

		# Also import user's favorite tracks collection as a playlist
		my $likedTracks = Plugins::Zvuk::API::Sync->users_likes_tracks($userId) || [];
		if (@$likedTracks) {
			my $url = "zvuk://playlist:favorites:$userId";
			my $favTitle = $prefix . string('PLUGIN_ZVUK_COLLECTION');

			$progress->update($accountName . string('COLON') . ' ' . string('PLUGIN_ZVUK_COLLECTION'));
			Slim::Schema->forceCommit;

			my $favObj = Slim::Schema->updateOrCreate({
				url             => $url,
				playlist        => 1,
				integrateRemote => 1,
				attributes      => {
					TITLE        => $favTitle,
					COVER        => '/plugins/zvuk/html/images/favorites.png',
					AUDIO        => 1,
					EXTID        => $url,
					CONTENT_TYPE => 'ssp',
				},
			});

			my @favTrackIds = map { "zvuk://$_->{id}" } @$likedTracks;
			$favObj->setTracks(\@favTrackIds) if $favObj && scalar @favTrackIds;
			$insertTrackInTempTable_sth && $insertTrackInTempTable_sth->execute($url);
		}

		Slim::Schema->forceCommit;
	}

	$progress->final();
	Slim::Schema->forceCommit;
} }

# Called from SCANNER process — synchronous API call is valid here
sub getArtistPicture { if (main::SCANNER) {
	my ($class, $id) = @_;

	return unless defined $id && length($id);
	$id =~ s/^zvuk:artist://;

	my $cacheKey = 'zvuk_artist_image_zvuk:artist:' . $id;
	my $url = $cache->get($cacheKey);
	return $url if $url;

	my $accounts = _enabledAccounts();
	my ($anyUserId) = values %$accounts;
	return unless $anyUserId;

	require Plugins::Zvuk::API::Sync;
	my $artist = Plugins::Zvuk::API::Sync->get_artist($id, $anyUserId) || {};

	if ($artist && ($artist->{image} || $artist->{cover})) {
		my $cover = Plugins::Zvuk::API->getImageUrl($artist);
		$cache->set($cacheKey, $cover, '3M');
		return $cover;
	}

	return;
} }

# Helper method for importer plugins to see whether they are enabled or not.
# Overridden with fallback to 'Plugins::Zvuk::Plugin' because in LMS $loaded
# stores plugin metadata under the main Plugin class name.
sub isImportEnabled {
	my ($class) = @_;

	my $supportEnabled = eval { Slim::Music::Import->isOnlineLibrarySupportEnabled() };
	$log->is_info && $log->info("isImportEnabled($class) - isOnlineLibrarySupportEnabled=" . ($supportEnabled || 0));

	if ( $supportEnabled ) {
		my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class)
			|| Slim::Utils::PluginManager->dataForPlugin('Plugins::Zvuk::Plugin');

		my $pluginName = $pluginData ? $pluginData->{name} : 'N/A';
		my $onlineLibFlag = ($pluginData && $pluginData->{onlineLibrary}) ? $pluginData->{onlineLibrary} : 'N/A';

		$log->is_info && $log->info("isImportEnabled($class) - pluginName=$pluginName, onlineLibrary=$onlineLibFlag");

		if ($pluginData && ref $pluginData && $pluginData->{name} && ($pluginData->{onlineLibrary} || '') eq 'true') {
			my $prefKey = 'enable_' . $pluginData->{name};
			my $enabled = preferences('plugin.onlinelibrary')->get($prefKey);
			$log->is_info && $log->info("isImportEnabled($class) - found in onlinelibrary prefs, key=$prefKey, value=" . ($enabled ? 1 : 0));
			return $enabled ? 1 : 0;
		} else {
			$log->is_info && $log->info("isImportEnabled($class) - pluginData check failed: pluginData exists=" . ($pluginData ? 'yes' : 'no') . ", name exists=" . ($pluginData && $pluginData->{name} ? 'yes' : 'no') . ", onlineLibrary flag=" . ($pluginData ? ($pluginData->{onlineLibrary} || '') : '') );
		}
	}

	$log->is_info && $log->info("isImportEnabled($class) - returning 0 (disabled)");
	return 0;
}

sub trackUriPrefix { 'zvuk://' }

sub needsUpdate { if (!main::SCANNER) {
	my ($class, $cb) = @_;

	my $accounts = _enabledAccounts();
	return $cb->(0) unless scalar keys %$accounts;

	my $lastScanTime = $cache->get('zvuk_library_last_scan');
	my $lastFingerprint = $cache->get('zvuk_library_fingerprint') || '';

	$log->is_info && $log->info("Zvuk needsUpdate called. lastScanTime=" . ($lastScanTime || 'never') . ", lastFingerprint=" . ($lastFingerprint || 'none'));

	return $cb->(1) unless $lastScanTime;

	my @userIds = sort values %$accounts;
	my ($anyUserId) = @userIds;
	my $token = Plugins::Zvuk::API->getToken($anyUserId);

	unless ($token) {
		$log->is_info && $log->info("Zvuk needsUpdate: no token found for user $anyUserId, falling back to time-based check");
		return $cb->( (time() - $lastScanTime) / 86400 > 7 ? 1 : 0 );
	}

	my $api = Plugins::Zvuk::API->getClient($anyUserId);
	unless ($api) {
		return $cb->( (time() - $lastScanTime) / 86400 > 7 ? 1 : 0 );
	}

	$log->is_info && $log->info("Zvuk needsUpdate: fetching fingerprint for change detection");

	$api->getLibraryFingerprint(sub {
		my $fingerprint = shift;

		if (!$fingerprint) {
			$log->is_info && $log->info("Zvuk fingerprint check failed, falling back to time-based check");
			my $daysSinceScan = (time() - $lastScanTime) / 86400;
			my $needsScan = $daysSinceScan > 7 ? 1 : 0;
			return $cb->($needsScan);
		}

		$log->is_info && $log->info("Zvuk fingerprint comparison: current=$fingerprint vs cached=$lastFingerprint");
		my $needsScan = $fingerprint ne $lastFingerprint;
		$log->is_info && $log->info("Zvuk needsUpdate result: " . ($needsScan ? 'SCAN NEEDED (fingerprint changed)' : 'SKIP SCAN (fingerprint unchanged)'));

		$cb->($needsScan ? 1 : 0);
	});
} }

sub _enabledAccounts {
	my $accounts = $prefs->get('accounts') || {};
	my $dontImportAccounts = $prefs->get('dontImportAccounts') || {};

	my $enabledAccounts = {};

	while (my ($uid, $account) = each %$accounts) {
		next if $account->{stale};
		next if !$account->{token};
		next if $dontImportAccounts->{$uid};

		$enabledAccounts->{ $account->{name} || $account->{username} || $uid } = $uid;
	}

	return $enabledAccounts;
}

sub _flattenTracksWithNumbers {
	my ($album) = @_;
	return () unless $album->{tracks} && ref $album->{tracks} eq 'ARRAY';

	my @tracks;
	my $idx = 1;
	foreach my $track (@{ $album->{tracks} }) {
		next unless $track && ref $track eq 'HASH';
		my $t = { %$track };
		$t->{_track_number} = $track->{position} || $idx++;
		push @tracks, $t;
	}
	return @tracks;
}

sub _prepareTrack {
	my ($album, $track) = @_;

	my $trackId = $track->{id} or return;
	my $url = 'zvuk://' . $trackId;

	my $duration = $track->{duration} ? int($track->{duration}) : 0;

	my $artist_name = 'Unknown';
	if ($track->{artists} && ref $track->{artists} eq 'ARRAY' && @{ $track->{artists} }) {
		$artist_name = $track->{artists}[0]{title} || 'Unknown';
	} elsif ($track->{artist}) {
		$artist_name = $track->{artist};
	}

	my $track_num = $track->{_track_number} || $track->{position} || 0;

	my $cover = '';
	if ($album->{image}) {
		$cover = Plugins::Zvuk::API->getImageUrl($album);
	} elsif ($track->{release} && $track->{release}{image}) {
		$cover = Plugins::Zvuk::API->getImageUrl($track->{release});
	}

	my $curr_ct = $ct || ((Plugins::Zvuk::API->getQuality() eq 'flac') ? 'flc' : 'mp3');
	my $curr_split = $splitChar || substr(Slim::Utils::Prefs::preferences('server')->get('splitList') || ';', 0, 1);

	my $trackData = {
		url          => $url,
		TITLE        => $track->{title} || 'Unknown',
		ARTIST       => $artist_name,
		ARTIST_EXTID => ($track->{artists} && @{ $track->{artists} } && $track->{artists}[0]{id}) ? ('zvuk:artist:' . $track->{artists}[0]{id}) : undef,
		ALBUM        => $album->{title} || 'Unknown',
		ALBUM_EXTID  => 'zvuk:album:' . $album->{id},
		TRACKNUM     => $track_num,
		SECS         => $duration,
		COVER        => $cover,
		SERVICE_ID   => 'zvuk',
		AUDIO        => 1,
		EXTID        => $url,
		CONTENT_TYPE => $curr_ct,
		LOSSLESS     => ($curr_ct eq 'flc' ? 1 : 0),
	};

	if ($track->{artists} && @{ $track->{artists} } > 1) {
		my @otherArtists = map { $_->{title} } grep { $_->{title} && $_->{title} ne $artist_name } @{ $track->{artists} };
		if (@otherArtists) {
			$trackData->{TRACKARTIST} = join($curr_split, @otherArtists);
		}
	}

	return $trackData;
}

sub _cacheArtistPicture {
	my ($artist, $ttl) = @_;

	my $artistId = $artist->{id};
	return if !$artistId || $artistId eq $previousArtistId;

	my $cover = ($artist->{image} || $artist->{cover}) ? Plugins::Zvuk::API->getImageUrl($artist) : '';
	return unless $cover;

	$artistId =~ s/^zvuk:artist://;
	$cache->set('zvuk_artist_image_zvuk:artist:' . $artistId, $cover, $ttl || '3M');
	$previousArtistId = $artistId;
}

1;
