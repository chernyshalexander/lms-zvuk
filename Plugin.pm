package Plugins::Zvuk::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::OPMLBased);

use Encode qw(decode_utf8 encode_utf8);
use JSON::XS;
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Zvuk::API;
use Plugins::Zvuk::API::Async;
use Plugins::Zvuk::ProtocolHandler;
use Plugins::Zvuk::Settings;
use Plugins::Zvuk::WaveSettings;

my $log = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

my %api_clients;

sub initPlugin {
	my $class = shift;

	Slim::Utils::Log->addLogCategory({
		'category'     => 'plugin.zvuk',
		'defaultLevel' => 'WARN',
		'description'  => 'PLUGIN_ZVUK',
	});

	$log->info("Initializing Zvuk plugin...");

	$prefs->init({
		accounts           => {},
		quality            => 'high',
		gigamix_autoplay   => 0,
	});

	Plugins::Zvuk::ProtocolHandler->register();
	
	if (main::WEBUI) {
		Plugins::Zvuk::Settings->new();

		# Register web routes for AJAX and web pages
		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/waveSettings',
			\&Plugins::Zvuk::Plugin::handleWaveSettingsWebUI
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/saveWaveSettings',
			\&Plugins::Zvuk::Plugin::handleSaveWaveSettingsWeb
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/saveOAuthToken',
			\&Plugins::Zvuk::Plugin::handleSaveOAuthToken
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/oauthCallback',
			\&Plugins::Zvuk::Plugin::handleOAuthCallback
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/getAnonymousToken',
			\&Plugins::Zvuk::Plugin::handleGetAnonymousToken
		);
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'zvuk',
		menu   => 'apps',
		weight => 10,
	);

	# Subscribe to events to clear wave_active flag when playback stops
	Slim::Control::Request::subscribe(\&_onStop, [['stop', 'playlist']]);

	# Initialize API clients for all accounts at startup
	my $accounts = $prefs->get('accounts') || {};
	foreach my $userId (keys %$accounts) {
		_init_api_client($userId);
	}

}

sub _onStop {
	my ($request) = @_;
	my $client = $request->client();
	return unless $client;

	my $action = $request->getRequest(0);
	if ($action eq 'stop' || ($action eq 'playlist' && $request->getRequest(1) eq 'clear')) {
		$client->pluginData(zvuk_wave_active => 0);
		$client->pluginData(zvuk_gigamix_active => 0);
		$log->debug("Cleared zvuk_wave_active and zvuk_gigamix_active flags");
	}
}

sub _init_api_client {
	my ($userId) = @_;
	my $accounts = $prefs->get('accounts') || {};
	my $account  = $accounts->{$userId};

	if ($account && $account->{token}) {
		# Each account gets its own Async API client with its own userId/deviceId
		$api_clients{$userId} = Plugins::Zvuk::API::Async->new({ userId => $userId });
		return $api_clients{$userId};
	}
	return;
}

sub _getUserIdForClient {
	my ($client) = @_;
	my $userId = $client ? $prefs->client($client)->get('userId') : undef;
	return $userId || Plugins::Zvuk::API->getSomeUserId();
}

sub _get_api_client {
	my ($client) = @_;
	my $userId = _getUserIdForClient($client);
	return $api_clients{$userId} if $userId && $api_clients{$userId};
	return _init_api_client($userId) if $userId;
	return;
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	unless (_get_api_client($client)) {
		$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN'), type => 'text' }]);
		return;
	}

	_buildRootMenu($client, $cb);
}

sub _buildRootMenu {
	my ($client, $cb) = @_;

	my @items = (
		{
			name  => cstring($client, 'PLUGIN_ZVUK_SEARCH'),
			type  => 'outline',
			image => 'plugins/zvuk/html/images/search.png',
			items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_TRACKS'),    type => 'search', url => \&searchTracks },
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_ARTISTS'),   type => 'search', url => \&searchArtists },
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_ALBUMS'),    type => 'search', url => \&searchAlbums },
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_PLAYLISTS'), type => 'search', url => \&searchPlaylists },
			],
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_WAVE'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/radio.png',
			items => _getWaveMenuItems($client),
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/playlists.png',
			url   => \&handlePersonalizedPlaylists,
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/playlists.png',
			url   => \&handleRecommendations,
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/playlists.png',
			url   => \&handleGigaMix,
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_MY_MUSIC'),
			type  => 'outline',
			image => 'plugins/zvuk/html/images/favorites.png',
			items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_COLLECTION'),  type => 'link', url => \&handleCollection,      image => 'html/images/musicfolder.png' },
				{ name => cstring($client, 'ALBUMS'),                  type => 'link', url => \&handleFavoriteAlbums,  image => 'plugins/zvuk/html/images/albums.png' },
				{ name => cstring($client, 'ARTISTS'),                 type => 'link', url => \&handleFavoriteArtists, image => 'plugins/zvuk/html/images/artists.png' },
				{ name => cstring($client, 'PLUGIN_ZVUK_PLAYLISTS'),   type => 'link', url => \&handleUserPlaylists,   image => 'plugins/zvuk/html/images/playlists.png' },
				{ name => cstring($client, 'PLUGIN_ZVUK_PODCASTS'),     type => 'link', url => \&handleFavoritePodcasts, image => 'plugins/zvuk/html/images/podcast_svg.png' },
				{ name => cstring($client, 'PLUGIN_ZVUK_EPISODES'),    type => 'link', url => \&handleFavoriteEpisodes, image => 'plugins/zvuk/html/images/podcast_svg.png' },
				# TODO: Synthesis Playlists API endpoint not available
				# { name => 'Synthesis Playlists', type => 'link', url => \&handleSynthesisPlaylists, image => 'plugins/zvuk/html/images/playlists.png' },
			],
		},
	);

	my $accounts = $prefs->get('accounts') || {};
	if (scalar(keys %$accounts) > 1) {
		my $userId  = _getUserIdForClient($client);
		my $account = $accounts->{$userId} || {};
		my $name    = $account->{name} || $userId;

		push @items, {
			name  => cstring($client, 'PLUGIN_ZVUK_SELECT_ACCOUNT') . ': ' . $name,
			type  => 'link',
			url   => \&selectAccount,
			image => 'plugins/zvuk/html/images/accnts_svg.png',
		};
	}

	$cb->({ items => \@items });
}

sub selectAccount {
	my ($client, $cb, $args) = @_;

	my $accounts      = $prefs->get('accounts') || {};
	my $currentUserId = _getUserIdForClient($client);

	my @items;
	foreach my $userId (sort keys %$accounts) {
		my $account   = $accounts->{$userId};
		my $name      = $account->{name} || $userId;
		my $isCurrent = defined $currentUserId && $userId eq $currentUserId;

		push @items, {
			name        => ($isCurrent ? '> ' : '  ') . $name,
			type        => 'link',
			url         => \&_switchAccount,
			passthrough => [$userId],
		};
	}

	$cb->({ items => \@items });
}

sub _switchAccount {
	my ($p1, $cb, $args, $userId) = @_;

	# In Jive, p1 is client only when called from connected player.
	# When called from web UI without player, p1 is undef.
	# The real client (if any) is in args->{client}
	my $client = (ref($p1) && $p1->can('name')) ? $p1 : $args->{client};

	my $accounts = $prefs->get('accounts') || {};
	unless (exists $accounts->{$userId}) {
		$cb->({ items => [{ name => 'Error: account not found', type => 'text' }] });
		return;
	}

	# Set client preference if we have a client
	if ($client && ref($client)) {
		eval {
			if (my $clientPrefs = $prefs->client($client)) {
				$clientPrefs->set('userId', $userId);
			}
		};
		$log->info("Zvuk: " . $client->name() . " switched to userId=$userId");
	} else {
		# No client connected - just log the switch (will use first account as fallback)
		$log->info("Zvuk: Account switched to userId=$userId (no connected player)");
	}

	handleFeed($client, $cb, $args);
}

# --- Search Handlers ---

sub searchTracks {
	my ($client, $cb, $args) = @_;
	_searchGeneric($client, $cb, $args, 'tracks', \&_renderTrack, \&searchTracks, 1);
}

sub searchArtists {
	my ($client, $cb, $args) = @_;
	_searchGeneric($client, $cb, $args, 'artists', \&_renderArtist, \&searchArtists);
}

sub searchAlbums {
	my ($client, $cb, $args) = @_;
	_searchGeneric($client, $cb, $args, 'releases', \&_renderAlbum, \&searchAlbums);
}

sub searchPlaylists {
	my ($client, $cb, $args) = @_;
	_searchGeneric($client, $cb, $args, 'playlists', \&_renderPlaylist, \&searchPlaylists);
}

sub _searchGeneric {
	my ($client, $cb, $args, $type, $renderSub, $pageSub, @renderArgs) = @_;

	my $api = _get_api_client($client);
	my $query = $args->{search};
	my $cursor = $args->{cursor};

	my %cursorKeys = (
		tracks    => 'trackCursor',
		artists   => 'artistsCursor',
		releases  => 'releasesCursor',
		playlists => 'playlistsCursor',
	);
	my %vars = ( query => $query, tracks => 0, artists => 0, releases => 0, playlists => 0 );
	$vars{$type} = 1;
	$vars{$cursorKeys{$type}} = $cursor if $cursor;

	$api->search(sub {
		my $data = shift;
		my $searchData = $data->{search};
		
		if (!$searchData) {
			$cb->({ items => [] });
			return;
		}

		my $section = $searchData->{$type} || {};
		my $items = $section->{items} || [];
		my $page = $section->{page} || {};
		my $nextCursor = $page->{next};

		# CRITICAL: We cache metadata proactively during browsing.
		# This allows ProtocolHandler to show the duration/progress bar instantly on playback.
		my @items = @$items;
		Plugins::Zvuk::API->cacheTrackMetadata(\@items) if $type eq 'tracks';
		my @rendered = map { $renderSub->($_, @renderArgs) } @items;

		if ($nextCursor) {
			push @rendered, {
				name => cstring($client, 'NEXT_PAGE'),
				type => 'link',
				url  => $pageSub,
				passthrough => [{ search => $query, cursor => $nextCursor }],
			};
		}

		$cb->({ items => \@rendered });
	}, \%vars);
}

# --- Browse Handlers ---

sub handleArtist {
	my ($client, $cb, $args, $params) = @_;
	my $id = $params->{id} || $args->{id};

	$cb->({ items => [
		{
			name        => cstring($client, 'SONGS'),
			type        => 'link',
			url         => \&handleArtistTracks,
			image       => 'html/images/musicfolder.png',
			passthrough => [{ id => $id }],
		},
		{
			name        => cstring($client, 'ALBUMS'),
			type        => 'link',
			url         => \&handleArtistAlbums,
			image       => 'html/images/albums.png',
			passthrough => [{ id => $id }],
		},
	]});
}

sub handleArtistTracks {
	my ($client, $cb, $args, $params) = @_;
	my $id = $params->{id} || $args->{id};
	my $api = _get_api_client($client);

	$api->getArtistTracks(sub {
		my $items = shift || [];
		Plugins::Zvuk::API->cacheTrackMetadata($items);
		$cb->({ items => [ map { _renderTrack($_, 0) } @$items ] });
	}, $id);
}

sub handleArtistAlbums {
	my ($client, $cb, $args, $params) = @_;
	my $id = $params->{id} || $args->{id};
	my $api = _get_api_client($client);

	$api->getArtistAlbums(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderAlbum($_) } @$items ] });
	}, $id);
}

sub handlePodcast {
	my ($client, $cb, $args, $params) = @_;
	my $id = $params->{id} || $args->{id};
	my $api = _get_api_client($client);

	$api->getPodcastEpisodes(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderEpisode($_) } @$items ] });
	}, $id);
}

sub handleAlbum {
	my ($client, $cb, $args, $params) = @_;
	my $id = $params->{id} || $args->{id};
	my $api = _get_api_client($client);

	$api->getAlbumTracks(sub {
		my $items = shift || [];
		Plugins::Zvuk::API->cacheTrackMetadata($items);
		$cb->({ items => [ map { _renderTrack($_, 0) } @$items ] });
	}, $id);
}

sub handlePlaylist {
	my ($client, $cb, $args, $params) = @_;
	my $id = $params->{id} || $args->{id};
	my $api = _get_api_client($client);

	$api->getPlaylistTracks(sub {
		my $items = shift || [];
		Plugins::Zvuk::API->cacheTrackMetadata($items);
		$cb->({ items => [ map { _renderTrack($_, 1) } @$items ] });
	}, $id);
}

sub handlePersonalWave {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getPersonalWave(sub {
		my $items = shift || [];
		Plugins::Zvuk::API->cacheTrackMetadata($items);
		$cb->({ items => [ map { _renderTrack($_, 1) } @$items ] });
	});
}

sub handleCollection {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getCollection(sub {
		my $items = shift || [];
		Plugins::Zvuk::API->cacheTrackMetadata($items);
		$cb->({ items => [ map { _renderTrack($_, 1) } @$items ] });
	}, 'tracks');
}

sub handleFavoriteAlbums {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getCollection(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderAlbum($_) } @$items ] });
	}, 'releases');
}

sub handleFavoriteArtists {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getCollection(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderArtist($_) } @$items ] });
	}, 'artists');
}

sub handleFavoritePodcasts {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getCollection(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderPodcast($_) } @$items ] });
	}, 'podcasts');
}

sub handleFavoriteEpisodes {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getCollection(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderEpisode($_) } @$items ] });
	}, 'episodes');
}

sub handleSynthesisPlaylists {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getCollection(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderPlaylist($_) } @$items ] });
	}, 'synthesis_playlists');
}

sub handleUserPlaylists {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getUserPlaylists(sub {
		my $items = shift || [];
		$cb->({ items => [ map { _renderPlaylist($_) } @$items ] });
	});
}

sub handlePersonalizedPlaylists {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getSynthesisPlaylists(sub {
		my $result = shift || [];

		# Handle API error (result is a hash with error field)
		if (ref $result eq 'HASH' && $result->{error}) {
			$log->error("Personalized Playlists API error: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR'), type => 'text' },
			]});
			return;
		}

		# Handle empty result (result is an array)
		my $playlists = ref $result eq 'ARRAY' ? $result : [];
		unless (@$playlists) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY'), type => 'text' },
			]});
			return;
		}

		# Render playlists
		$cb->({ items => [ map { _renderPlaylist($_) } @$playlists ] });
	});
}

# --- Music Recommendations (For You) ---

sub handleRecommendations {
	my ($client, $cb, $args, $params) = @_;
	my $api = _get_api_client($client);

	$api->getMusicRecommendations(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("getMusicRecommendations failed: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_ERROR'), type => 'text' },
			]});
			return;
		}

		my $items = $result->{items} || [];
		unless (@$items) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_EMPTY'), type => 'text' },
			]});
			return;
		}

		# Render mixed content (artists, releases, playlists)
		my @menuItems;
		foreach my $item (@$items) {
			if (ref($item) eq 'HASH') {
				if ($item->{artists}) {
					# Release (альбом)
					push @menuItems, _renderReleaseItem($item);
				} elsif ($item->{trackCount}) {
					# Playlist
					push @menuItems, _renderPlaylistItem($item);
				} else {
					# Artist
					push @menuItems, _renderArtistItem($item);
				}
			}
		}

		$cb->({ items => \@menuItems });
	}, {
		contentType => 'Music',
		itemTypes   => ['Artist', 'Release', 'Playlist'],
		page        => 1,
	});
}

sub _renderArtistItem {
	my ($artist) = @_;
	return {
		name     => $artist->{title},
		type     => 'link',
		url      => \&handleArtist,
		image    => Plugins::Zvuk::API->getImageUrl($artist),
		passthrough => [{ artistId => $artist->{id} }],
	};
}

sub _renderReleaseItem {
	my ($release) = @_;
	my $artist_name = ($release->{artists} && @{$release->{artists}})
		? $release->{artists}[0]{title}
		: '';
	return {
		name     => $release->{title} . ($artist_name ? " - $artist_name" : ''),
		type     => 'link',
		url      => \&handleAlbum,
		image    => Plugins::Zvuk::API->getImageUrl($release),
		passthrough => [{ releaseId => $release->{id} }],
	};
}

sub _renderPlaylistItem {
	my ($playlist) = @_;
	return {
		name     => $playlist->{title},
		type     => 'link',
		url      => \&handlePlaylist,
		image    => Plugins::Zvuk::API->getImageUrl($playlist),
		passthrough => [{ playlistId => $playlist->{id} }],
	};
}

# --- GigaMix AI Playlist Generator ---

sub handleGigaMix {
	my ($client, $cb) = @_;

	$cb->({ items => [
		{
			name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_PROMPT'),
			type => 'search',
			url  => \&handleGigaMixSearch,
		},
	]});
}

sub handleGigaMixSearch {
	my ($client, $cb, $args) = @_;

	my $prompt = $args->{search};
	unless ($prompt && length($prompt)) {
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_EMPTY_PROMPT'), type => 'text' },
		]});
		return;
	}

	my $api = _get_api_client($client);

	$log->info("GigaMix: generating playlist for: $prompt");

	$api->getGenerativePlaylist(sub {
		my $result = shift || {};
		_renderGigaMixPlaylist($client, $cb, $result, $prompt);
	}, { queryText => $prompt });
}

sub handleGigaMixRemake {
	my ($client, $cb, $args, $params) = @_;
	my $api = _get_api_client($client);

	my $prompt = $params->{prompt};
	$log->info("GigaMix: remixing playlist for: $prompt");

	$api->remakeGenerativePlaylist(sub {
		my $result = shift || {};
		_renderGigaMixPlaylist($client, $cb, $result, $prompt);
	}, { queryText => $prompt });
}

sub handleGigaMixAddMore {
	my ($client, $cb, $args, $params) = @_;
	my $api = _get_api_client($client);

	my $cursor = $params->{cursor};
	my $prompt = $params->{prompt};

	$log->info("GigaMix: adding more tracks for: $prompt");

	$api->getGenerativePlaylistPage(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("GigaMix: failed to add more tracks: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_LOAD_MORE'), type => 'text' },
				{ name => "Error: $result->{error}", type => 'text' },
			]});
			return;
		}

		my $newTracks = $result->{tracks} || [];
		my $newCursor = $result->{cursor};

		$log->info("GigaMix: loaded " . scalar(@$newTracks) . " more tracks, adding to playlist");

		unless (@$newTracks) {
			$log->info("GigaMix: no more tracks available");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_NO_RESULTS') . " - плейлист исчерпан", type => 'text' },
			]});
			return;
		}

		# Add loaded tracks to the actual player playlist
		foreach my $track (@$newTracks) {
			Slim::Control::Request::executeRequest(
				$client, ['playlist', 'add', 'zvuk://' . $track->{id}]
			);
		}

		# Save GigaMix context for autoplay at end of playlist
		if ($newCursor) {
			$client->pluginData('zvuk_gigamix_active', 1);
			$client->pluginData('zvuk_gigamix_cursor', $newCursor);
			$client->pluginData('zvuk_gigamix_prompt', $prompt);
		}

		$log->info("GigaMix: successfully added " . scalar(@$newTracks) . " tracks to playlist");

		# Return confirmation message
		$cb->({ items => [
			{ name => "Added " . scalar(@$newTracks) . " tracks to playlist", type => 'text' },
		]});
	}, { cursor => $cursor, limit => 5 });
}

sub handleGigaMixNextPage {
	my ($client, $cb, $args, $params) = @_;

	my $cursor = $params->{cursor};
	my $prompt = $params->{prompt};

	unless ($cursor) {
		$log->warn("GigaMix: next page called without cursor");
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_CURSOR'), type => 'text' },
		]});
		return;
	}

	my $api = _get_api_client($client);

	$log->info("GigaMix: loading next page with cursor='$cursor'");

	$api->getGenerativePlaylistPage(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("GigaMix: getGenerativePlaylistPage failed with error: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_LOAD_MORE') . " ($result->{error})", type => 'text' },
			]});
			return;
		}

		my $tracks = $result->{tracks} || [];
		my $nextCursor = $result->{cursor};

		my @items = map { _renderTrack($_, 1) } @$tracks;

		if ($nextCursor) {
			push @items, {
				name        => cstring($client, 'NEXT_PAGE'),
				type        => 'link',
				url         => \&handleGigaMixNextPage,
				passthrough => [{ cursor => $nextCursor, prompt => $prompt }],
			};
		}

		$cb->({ items => \@items });
	}, { limit => 20, cursor => $cursor });
}

sub _renderGigaMixPlaylist {
	my ($client, $cb, $result, $prompt) = @_;

	if ($result->{error}) {
		$log->error("GigaMix: generation failed: $result->{error}");
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ERROR_GENERATE'), type => 'text' },
		]});
		return;
	}

	my $playlistName = $result->{playlistName};
	my $tracks       = $result->{tracks} || [];
	my $cursor       = $result->{cursor};
	my $genId        = $result->{genId};

	$log->info("GigaMix: playlist generated - genId=$genId, tracks=" . scalar(@$tracks));

	unless (@$tracks) {
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_NO_RESULTS'), type => 'text' },
		]});
		return;
	}

	my @items;

	push @items, map { _renderTrack($_, 1) } @$tracks;

	push @items, {
		name        => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_REMAKE'),
		type        => 'link',
		url         => \&handleGigaMixRemake,
		passthrough => [{ prompt => $prompt }],
	};

	# Add "More Tracks" button if cursor exists (pagination available)
	if ($cursor) {
		# Save context for auto-extend feature
		$client->pluginData('zvuk_gigamix_active', 1);
		$client->pluginData('zvuk_gigamix_cursor', $cursor);
		$client->pluginData('zvuk_gigamix_prompt', $prompt);

		push @items, {
			name        => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_ADD_MORE'),
			type        => 'link',
			url         => \&handleGigaMixAddMore,
			passthrough => [{ cursor => $cursor, prompt => $prompt, initialTracks => $tracks }],
		};
	}

	$cb->({ items => \@items });
}

# --- Rendering Helpers ---

sub _renderTrack {
	my ($track, $showArtist) = @_;
	my $url = 'zvuk://' . $track->{id};
	my $artist = _getArtistName($track);

	return {
		name            => $track->{title} . ($showArtist ? " - " . $artist : ""),
		favorites_title => $track->{title} . " - " . $artist,
		line1           => $track->{title},
		line2           => $showArtist ? ($artist . " • " . ($track->{release}->{title} || "")) : "",
		artist          => $artist,
		album           => $track->{release}->{title} || "",
		duration        => $track->{duration},
		secs            => $track->{duration},
		on_select       => 'play',
		url             => $url,
		play            => $url,
		playall         => 1,
		type            => 'audio',
		image           => Plugins::Zvuk::API->getImageUrl($track),
	};
}

sub _getArtistName { Plugins::Zvuk::API->_getArtistName($_[0]) }

sub _renderAlbum {
	my ($album) = @_;
	return {
		name      => $album->{title},
		line1     => $album->{title},
		line2     => _getArtistName($album),
		type      => 'link',
		url       => \&handleAlbum,
		passthrough => [{ id => $album->{id} }],
		image     => Plugins::Zvuk::API->getImageUrl($album),
	};
}

sub _renderArtist {
	my ($artist) = @_;
	return {
		name      => $artist->{title},
		type      => 'link',
		url       => \&handleArtist,
		passthrough => [{ id => $artist->{id} }],
		image     => Plugins::Zvuk::API->getImageUrl($artist),
	};
}

sub _renderPlaylist {
	my ($playlist) = @_;
	return {
		name      => $playlist->{title},
		type      => 'link',
		url       => \&handlePlaylist,
		passthrough => [{ id => $playlist->{id} }],
		image     => Plugins::Zvuk::API->getImageUrl($playlist),
	};
}

sub _renderPodcast {
	my ($podcast) = @_;
	return {
		name        => $podcast->{title},
		line1       => $podcast->{title},
		line2       => $podcast->{description} || "",
		type        => 'link',
		url         => \&handlePodcast,
		passthrough => [{ id => $podcast->{id} }],
		image       => Plugins::Zvuk::API->getImageUrl($podcast),
	};
}

sub _renderEpisode {
	my ($episode) = @_;
	my $podcast_name = $episode->{podcast} ? $episode->{podcast}->{title} : "Podcast";
	return {
		name      => $episode->{title},
		line1     => $episode->{title},
		line2     => $podcast_name,
		duration  => $episode->{duration},
		secs      => $episode->{duration},
		type      => 'text',
		image     => $episode->{podcast} ? Plugins::Zvuk::API->getImageUrl($episode->{podcast}) : "",
	};
}

# --- Wave Settings ---

sub _getWaveSettingsItems {
	my ($client) = @_;
	my @items;

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_POPULAR') . ': ' . _getSliderLabel($client, 'popular'),
		type => 'link',
		url  => \&handleSlider,
		passthrough => [{ key => 'popular' }],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_ENERGY') . ': ' . _getSliderLabel($client, 'energy'),
		type => 'link',
		url  => \&handleSlider,
		passthrough => [{ key => 'energy' }],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_FUN') . ': ' . _getSliderLabel($client, 'fun'),
		type => 'link',
		url  => \&handleSlider,
		passthrough => [{ key => 'fun' }],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_VOCAL') . ': ' . _getVocalLabel($client),
		type => 'link',
		url  => \&handleVocalMenu,
	};

	# Only show language if vocal=1 (with vocals)
	my $vocal = _getSettingValue($client, 'vocal', 1);
	if ($vocal == 1) {
		push @items, {
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_LANGUAGE') . ': ' . _getLangLabel($client),
			type => 'link',
			url  => \&handleLanguageMenu,
		};
	}

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
		type => 'link',
		url  => \&handleGenresMenu,
	};

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return \@items;
}

sub _getSliderLabel {
	my ($client, $key) = @_;
	return sprintf('%.1f', _getSettingValue($client, $key, 0.5));
}

sub _getLangLabel {
	my ($client) = @_;
	my $val = _getSettingValue($client, 'language', 'all');
	my %map = (
		all     => 'PLUGIN_ZVUK_LANGUAGE_ALL',
		foreign => 'PLUGIN_ZVUK_LANGUAGE_FOREIGN',
		russian => 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN',
	);
	return cstring($client, $map{$val} || $map{all});
}

sub _getVocalLabel {
	my ($client) = @_;
	my $val = _getSettingValue($client, 'vocal', 1);
	return cstring($client, $val ? 'PLUGIN_ZVUK_VOCAL_WITH' : 'PLUGIN_ZVUK_VOCAL_WITHOUT');
}

sub _getSettingValue {
	my ($client, $key, $default) = @_;
	return $default unless $client;

	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	return $settings->{$key} // $default;
}

sub _updateSetting {
	my ($client, $key, $value) = @_;
	return unless $client;

	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	$settings->{$key} = $value;
	Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

	$log->info("Wave setting updated: $key = $value");
}

sub handleGenresMenu {
	my ($client, $callback) = @_;
	$callback->(_getGenresMenu($client));
}

sub _getGenresMenu {
	my ($client) = @_;
	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $selected_genres = $settings->{genres} || [];
	my %selected = map { $_ => 1 } @$selected_genres;

	my @genre_items;
	foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenres() }) {
		my $is_selected = $selected{$genre->{name}} ? 1 : 0;
		my $checkbox_char = $is_selected ? '[x]' : '[ ]';
		push @genre_items, {
			name       => "$checkbox_char " . cstring($client, $genre->{label}),
			type       => 'link',
			url        => \&handleGenreToggle,
			passthrough => [{ genre => $genre->{name} }],
			nextWindow => 'refresh',
		};
	}

	push @genre_items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return \@genre_items;
}

sub handleGenreToggle {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $genre_name = $params->{genre};

	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $genres = $settings->{genres} || [];
	my %genre_hash = map { $_ => 1 } @$genres;

	# Toggle
	if ($genre_hash{$genre_name}) {
		delete $genre_hash{$genre_name};
	} else {
		$genre_hash{$genre_name} = 1;
	}

	$settings->{genres} = [sort keys %genre_hash];
	Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

	$log->info("Genre toggled: $genre_name, new genres: " . join(',', @{$settings->{genres}}));

	# Вернуть в меню жанров
	$callback->(_getGenresMenu($client));
}

sub _getAPIHandler {
	my ($client) = @_;
	return unless $client;
	return $client->pluginData('zvuk_api') || _initAPIHandler($client);
}

sub _initAPIHandler {
	my ($client) = @_;
	require Plugins::Zvuk::API::Async;
	my $userId = _getUserIdForClient($client);
	my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
	$client->pluginData(zvuk_api => $api);
	return $api;
}

# Handle slider changes (Popular, Energy, Fun)
sub handleSlider {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;
	my $key = $params->{key};
	$callback->(_getSliderItems($client, $key));
}

sub _getWaveMenuItems {
	my ($client) = @_;
	my @items;

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_START'),
		type => 'audio',
		url  => 'zvuk://wave',
	};

	push @items, {
		name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
		type  => 'link',
		url   => \&handleWaveSettingsRouter,
	};

	return \@items;
}

sub handleWaveSettingsRouter {
	my ($client, $callback, $args) = @_;

	$log->info("=== Wave Settings Router Decision ===");
	$log->info("Args received: " . (defined $args ? "YES" : "UNDEF"));

	my $isWeb = $args && $args->{isWeb} ? 1 : 0;
	my $isControl = $args && defined $args->{isControl} ? $args->{isControl} : undef;
	my $quantity = $args && defined $args->{quantity} ? $args->{quantity} : undef;

	$log->info("  isWeb=$isWeb");
	$log->info("  isControl=" . (defined $isControl ? $isControl : 'undef'));
	$log->info("  quantity=" . (defined $quantity ? $quantity : 'undef'));

	if ($args) {
		foreach my $key (sort keys %$args) {
			next if $key =~ /^(isWeb|isControl|quantity)$/;
			my $val = $args->{$key};
			if (ref $val) {
				$log->info("  $key => [" . ref($val) . "]");
			} else {
				$log->info("  $key => " . ($val // 'undef'));
			}
		}
	}

	my $useWebUI = 0;
	my $reason = '';

	if ($isWeb) {
		$useWebUI = 1;
		$reason = 'isWeb=1 - show web sliders';
	} elsif (!defined $isControl) {
		$useWebUI = 1;
		$reason = 'isControl undefined - web-like client';
	} elsif ($isControl && (!defined $quantity || $quantity > 5000)) {
		$useWebUI = 1;
		$reason = 'isControl=1 AND (quantity undef OR quantity > 5000) - Material UI';
	} else {
		$reason = 'isControl=1 AND quantity <= 5000 - Jive/SqueezePlay';
	}

	$log->info("Decision: useWebUI=$useWebUI (Reason: $reason)");
	$log->info("=== End Router Decision ===");

	if ($useWebUI) {
		# For Web/Material UI: Settings not available in OPML menu
		# Web UI users should use "Open Settings" button on plugin settings page
		# to access the slider-based settings form (waveSliders.html)
		$callback->([{
			name => cstring($client, 'PLUGIN_ZVUK_SETTINGS_IN_PLUGIN_PAGE'),
			type => 'text'
		}]);
	} else {
		# For Jive/SqueezePlay: show standard list settings
		handleWaveSettings($client, $callback, $args);
	}
}

sub handleWaveSettings {
	my ($client, $callback, $args) = @_;
	$callback->({ items => _getWaveSettingsItems($client) });
}

# =====================================================================
# WAVE SETTINGS WIZARD - NOT CURRENTLY USED
# =====================================================================
# The wizard interface below was originally designed for OPML menu navigation
# but has been replaced with a modal-based slider form (waveSliders.html) in
# the Web UI settings page for better user experience.
#
# The wizard code is preserved here for future experimentation and can be
# re-enabled if needed by modifying handleWaveSettingsRouter to route
# Web/Material UI clients to handleWaveWizardStart instead of the web UI.
#
# For OPML clients (Jive, SqueezePlay), use handleWaveSettings instead.
# =====================================================================

sub handleWaveWizardStart {
	my ($client, $callback, $args) = @_;
	my $state = {
		popular  => undef,
		energy   => undef,
		fun      => undef,
		language => undef,
		vocal    => undef,
		genres   => [],
	};
	$callback->(_getWizardStep($client, 1, $state));
}

sub _getWizardStep {
	my ($client, $step, $state) = @_;

	if ($step == 1) {
		return _getWizardPopularityStep($client, $state);
	} elsif ($step == 2) {
		return _getWizardEnergyStep($client, $state);
	} elsif ($step == 3) {
		return _getWizardFunStep($client, $state);
	} elsif ($step == 4) {
		return _getWizardVocalStep($client, $state);
	} elsif ($step == 5) {
		# Only show language step if vocal is selected (vocal=1)
		if ($state->{vocal} == 1) {
			return _getWizardLanguageStep($client, $state);
		} else {
			# Skip language, go to genres
			return _getWizardGenresStep($client, $state);
		}
	} elsif ($step == 6) {
		return _getWizardGenresStep($client, $state);
	} else {
		return _getWizardLaunch($client, $state);
	}
}

sub _getWizardStepLabel {
	my ($client, $step, $value) = @_;

	return unless defined $value;

	# Only show labels for exact values: 0.0, 0.5, 1.0
	if ($step == 1) {  # Popularity
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_POPULAR_UNKNOWN'); }
		elsif (abs($value - 0.5) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_POPULAR_POPULAR'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_POPULAR_FAVORITES'); }
	} elsif ($step == 2) {  # Energy
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_ENERGY_CALM'); }
		elsif (abs($value - 0.5) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_ENERGY_NEUTRAL'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_ENERGY_ENERGETIC'); }
	} elsif ($step == 3) {  # Fun
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_FUN_SAD'); }
		elsif (abs($value - 0.5) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_FUN_NEUTRAL'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_FUN_HAPPY'); }
	} elsif ($step == 4) {  # Vocal
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_VOCAL_WITHOUT'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_VOCAL_WITH'); }
	}

	return '';
}

sub _getWizardPopularityStep {
	my ($client, $state) = @_;
	my @items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $label = _getWizardStepLabel($client, 1, $val);
		my $name = sprintf("%.1f", $val);
		$name .= ' - ' . $label if $label;
		push @items, {
			name        => $name,
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 1, value => $val, state => $state }],
		};
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return { items => \@items };
}

sub _getWizardEnergyStep {
	my ($client, $state) = @_;
	my @items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $label = _getWizardStepLabel($client, 2, $val);
		my $name = sprintf("%.1f", $val);
		$name .= ' - ' . $label if $label;
		push @items, {
			name        => $name,
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 2, value => $val, state => $state }],
		};
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return { items => \@items };
}

sub _getWizardFunStep {
	my ($client, $state) = @_;
	my @items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $label = _getWizardStepLabel($client, 3, $val);
		my $name = sprintf("%.1f", $val);
		$name .= ' - ' . $label if $label;
		push @items, {
			name        => $name,
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 3, value => $val, state => $state }],
		};
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return { items => \@items };
}

sub _getWizardLanguageStep {
	my ($client, $state) = @_;
	my @lang_items = (
		{
			name        => cstring($client, 'PLUGIN_ZVUK_LANGUAGE_ALL'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 5, value => 'all', state => $state }],
		},
		{
			name        => cstring($client, 'PLUGIN_ZVUK_LANGUAGE_FOREIGN'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 5, value => 'foreign', state => $state }],
		},
		{
			name        => cstring($client, 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 5, value => 'russian', state => $state }],
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return { items => \@lang_items };
}

sub _getWizardVocalStep {
	my ($client, $state) = @_;
	my @vocal_items = (
		{
			name        => cstring($client, 'PLUGIN_ZVUK_VOCAL_WITH'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 4, value => 1, state => $state }],
		},
		{
			name        => cstring($client, 'PLUGIN_ZVUK_VOCAL_WITHOUT'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 4, value => 0, state => $state }],
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return { items => \@vocal_items };
}

sub _getWizardGenresStep {
	my ($client, $state) = @_;
	my @genre_items;

	foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenres() }) {
		my $is_selected = grep { $_ eq $genre->{name} } @{$state->{genres}};
		my $checkbox_char = $is_selected ? '[x]' : '[ ]';
		push @genre_items, {
			name        => "$checkbox_char " . cstring($client, $genre->{label}),
			type        => 'link',
			url         => \&handleWizardGenreToggle,
			passthrough => [{ genre => $genre->{name}, state => $state }],
			nextWindow  => 'refresh',
		};
	}

	push @genre_items, (
		{
			name        => cstring($client, 'PLUGIN_ZVUK_WIZARD_NEXT'),
			type        => 'link',
			url         => \&handleWizardGenresDone,
			passthrough => [{ state => $state }],
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return { items => \@genre_items };
}

sub handleWizardStepSelect {
	my ($client, $callback, $args, $params) = @_;
	my $step = $params->{step};
	my $value = $params->{value};
	my $state = $params->{state};

	# Update state based on step
	if ($step == 1) { $state->{popular} = $value; }
	elsif ($step == 2) { $state->{energy} = $value; }
	elsif ($step == 3) { $state->{fun} = $value; }
	elsif ($step == 4) { $state->{vocal} = $value; }
	elsif ($step == 5) { $state->{language} = $value; }

	# Move to next step
	$callback->(_getWizardStep($client, $step + 1, $state));
}

sub handleWizardGenreToggle {
	my ($client, $callback, $args, $params) = @_;
	my $genre = $params->{genre};
	my $state = $params->{state};

	# Toggle genre
	my @genres = @{$state->{genres}};
	if (grep { $_ eq $genre } @genres) {
		@genres = grep { $_ ne $genre } @genres;
	} else {
		push @genres, $genre;
	}
	$state->{genres} = \@genres;

	# Refresh genres menu with updated checkmarks
	$callback->(_getWizardGenresStep($client, $state));
}

sub handleWizardGenresDone {
	my ($client, $callback, $args, $params) = @_;
	my $state = $params->{state};

	# Move to launch screen
	$callback->(_getWizardLaunch($client, $state));
}

sub _getWizardLaunch {
	my ($client, $state) = @_;

	# Save settings to prefs
	my $api = _getAPIHandler($client);
	my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

	my $settings = {
		popular  => $state->{popular} // 0.5,
		energy   => $state->{energy} // 0.5,
		fun      => $state->{fun} // 0.5,
		language => $state->{language} // 'all',
		vocal    => defined $state->{vocal} ? $state->{vocal} : 1,
		genres   => $state->{genres} || [],
	};
	Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

	return {
		items => [
			{
				name => cstring($client, 'PLUGIN_ZVUK_WIZARD_LAUNCH'),
				type => 'audio',
				url  => 'zvuk://wave',
			},
			{
				name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
				type       => 'link',
				nextWindow => 'parent',
			},
		],
	};
}

sub _getSliderItems {
	my ($client, $key) = @_;
	my $current_value = _getSettingValue($client, $key, 0.5);

	my @slider_items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $marker = abs($val - $current_value) < 0.01 ? '[x]' : '[ ]';
		push @slider_items, {
			name       => sprintf("$marker %.1f", $val),
			type       => 'link',
			url        => \&handleSliderValue,
			passthrough => [{ key => $key, value => $val }],
			nextWindow => 'parent',
		};
	}

	push @slider_items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return \@slider_items;
}

# Handle actual slider value selection
sub handleSliderValue {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $key = $params->{key};
	my $value = $params->{value};

	_updateSetting($client, $key, $value);
	$callback->(_getSliderItems($client, $key));
}

# Handle language selection
sub handleLanguageSelect {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $language = $params->{language};
	_updateSetting($client, 'language', $language);
	$callback->(_getLanguageMenu($client));
}

# Handle vocal selection
sub handleVocalSelect {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $vocal = $params->{vocal};
	_updateSetting($client, 'vocal', $vocal);
	$callback->(_getVocalMenu($client));
}

# Generate language selection menu handler
sub handleLanguageMenu {
	my ($client, $callback) = @_;
	$callback->(_getLanguageMenu($client));
}

# Return language menu items
sub _getLanguageMenu {
	my ($client) = @_;
	my $account_id = 'default';
	if ($client) {
		my $api = _getAPIHandler($client);
		$account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
	}

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $current_lang = $settings->{language} || 'all';

	my @lang_items = (
		{
			name       => ($current_lang eq 'all' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_ALL'),
			type       => 'link',
			url        => \&handleLanguageSelect,
			passthrough => [{ language => 'all' }],
			nextWindow => 'parent',
		},
		{
			name       => ($current_lang eq 'foreign' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_FOREIGN'),
			type       => 'link',
			url        => \&handleLanguageSelect,
			passthrough => [{ language => 'foreign' }],
			nextWindow => 'parent',
		},
		{
			name       => ($current_lang eq 'russian' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN'),
			type       => 'link',
			url        => \&handleLanguageSelect,
			passthrough => [{ language => 'russian' }],
			nextWindow => 'parent',
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return \@lang_items;
}

# Generate vocal selection menu handler
sub handleVocalMenu {
	my ($client, $callback) = @_;
	$callback->(_getVocalMenu($client));
}

# Return vocal menu items
sub _getVocalMenu {
	my ($client) = @_;
	my $account_id = 'default';
	if ($client) {
		my $api = _getAPIHandler($client);
		$account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
	}

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $current_vocal = $settings->{vocal} // 1;

	my @vocal_items = (
		{
			name       => ($current_vocal == 1 ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_VOCAL_WITH'),
			type       => 'link',
			url        => \&handleVocalSelect,
			passthrough => [{ vocal => 1 }],
			nextWindow => 'parent',
		},
		{
			name       => ($current_vocal == 0 ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_VOCAL_WITHOUT'),
			type       => 'link',
			url        => \&handleVocalSelect,
			passthrough => [{ vocal => 0 }],
			nextWindow => 'parent',
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return \@vocal_items;
}

# Web UI handler for displaying wave settings (AJAX or standalone)
sub handleWaveSettingsWebUI {
	my ($httpClient, $response) = @_;

	require Plugins::Zvuk::WaveSettings;
	require Slim::Web::HTTP;
	my $request = $response->request;
	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings('default');

	# Build genres list for JavaScript
	my $genres = Plugins::Zvuk::WaveSettings::getGenres();
	my @genre_list;
	my %genre_labels;
	foreach my $genre (@$genres) {
		push @genre_list, { name => $genre->{name} };
		$genre_labels{$genre->{name}} = Slim::Utils::Strings::string($genre->{label});
	}

	my $vars = {
		wave_settings => $wave_settings,
		genres_json => encode_json(\@genre_list),
		genres_labels_json => encode_json(\%genre_labels),
		selected_genres_json => encode_json($wave_settings->{genres} || []),
		webroot => '/html/',
	};

	# Use waveSliders.html for AJAX modal content, waveSettings.html for standalone
	my $template = 'plugins/zvuk/waveSliders.html';

	my $output = Slim::Web::HTTP::filltemplatefile($template, $vars);

	$response->code(200);
	$response->content_type('text/html; charset=utf-8');
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$output);
}

# Web AJAX handler for saving wave settings from web interface
sub handleSaveWaveSettingsWeb {
	my ($httpClient, $response) = @_;

	my $request = $response->request;

	# Get JSON payload from request body
	my $body = $request->content_ref ? ${$request->content_ref} : '';
	my $data;

	eval {
		$data = decode_json($body);
	};

	if ($@ || !$data) {
		$log->error("Wave Settings Web: Failed to parse JSON: $@");
		$response->code(400);
		$response->content_type('application/json');
		my $json = encode_json({ success => 0, error => 'Invalid JSON' });
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		return;
	}

	# Get current account ID (default for web UI)
	my $account_id = 'default';

	# Validate and save settings
	my $settings = {
		popular  => defined $data->{popular} ? 0.0 + $data->{popular} : 0.5,
		energy   => defined $data->{energy} ? 0.0 + $data->{energy} : 0.5,
		fun      => defined $data->{fun} ? 0.0 + $data->{fun} : 0.5,
		language => $data->{language} || 'all',
		vocal    => defined $data->{vocal} ? 0 + $data->{vocal} : 1,
		genres   => $data->{genres} && ref $data->{genres} eq 'ARRAY' ? $data->{genres} : [],
	};

	Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);
	$log->info("Wave settings saved from web interface for account $account_id");

	$response->code(200);
	$response->content_type('application/json');
	my $json = encode_json({ success => 1 });
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
}

sub handleSaveOAuthToken {
	my ($httpClient, $response) = @_;

	$log->debug("OAuth: handleSaveOAuthToken called");

	my $request = $response->request;
	my $body = $request->content_ref ? ${$request->content_ref} : '';
	$log->debug("OAuth: Request body length: " . length($body));
	$log->debug("OAuth: Request body (first 100 chars): " . substr($body, 0, 100));

	my $data;

	eval {
		$data = decode_json($body);
	};

	if ($@) {
		$log->error("OAuth: Failed to parse JSON: $@");
	}

	if ($@ || !$data || !$data->{token}) {
		$log->error("OAuth: Failed to parse token request: $@ | data: " . ($data ? 'exists' : 'null') . " | token: " . ($data->{token} ? 'exists' : 'null'));
		$response->code(400);
		$response->content_type('application/json');
		my $json = encode_json({ success => 0, error => 'Missing token' });
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		return;
	}

	my $token = $data->{token};

	# Validate token format (32 hex characters)
	if ($token !~ /^[0-9a-f]{32}$/i) {
		$log->error("OAuth: Invalid token format: $token");
		$response->code(400);
		$response->content_type('application/json');
		my $json = encode_json({ success => 0, error => 'Invalid token format' });
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		return;
	}

	# Save token immediately without waiting for profile fetch
	my $prefs = preferences('plugin.zvuk');
	my $accounts = $prefs->get('accounts') || {};

	# Generate temporary userId from token hash
	my $tempUserId = substr($token, 0, 16);
	$accounts->{$tempUserId} = {
		token => $token,
		name  => "Account $tempUserId",
	};
	$prefs->set('accounts', $accounts);
	$log->info("OAuth: Token saved immediately with tempUserId=$tempUserId");

	# Send immediate response to client
	$response->code(200);
	$response->content_type('application/json');

	my $json_encoder = JSON::XS->new->utf8(0)->canonical(1);
	my $json = $json_encoder->encode({
		success => 1,
		account => {
			userId => $tempUserId,
			name => "Account"
		}
	});
	$log->debug("OAuth: Sending immediate response: $json");
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
	$log->debug("OAuth: Response sent immediately");
}

sub handleOAuthCallback {
	my ($httpClient, $response) = @_;

	$log->info("OAuth Callback: Serving browser-side fetch page");

	# Return an HTML page that uses JS to fetch the token from zvuk.com
	# The browser has zvuk.com session cookies, so fetch with credentials:include
	# will return the authenticated profile. If CORS blocks it, manual paste is shown.
	my $html = <<'END_HTML';
<!DOCTYPE html>
<html>
<head>
	<meta charset="UTF-8">
	<title>Zvuk — Авторизация</title>
	<style>
		* { box-sizing: border-box; margin: 0; padding: 0; }
		body {
			font-family: Arial, sans-serif;
			display: flex;
			align-items: center;
			justify-content: center;
			min-height: 100vh;
			background: #f5f5f5;
			padding: 20px;
		}
		.container {
			background: white;
			padding: 40px;
			border-radius: 8px;
			text-align: center;
			box-shadow: 0 2px 8px rgba(0,0,0,0.12);
			max-width: 480px;
			width: 100%;
		}
		h2 { color: #333; margin-bottom: 24px; font-size: 20px; }
		.spinner {
			border: 3px solid #eee;
			border-top: 3px solid #b8a6db;
			border-radius: 50%;
			width: 44px;
			height: 44px;
			animation: spin 0.8s linear infinite;
			margin: 0 auto 16px;
		}
		@keyframes spin { to { transform: rotate(360deg); } }
		.status { color: #666; font-size: 14px; line-height: 1.5; }
		.status.ok  { color: #388e3c; font-weight: bold; }
		.status.err { color: #d32f2f; }
		#manualSection { display: none; margin-top: 24px; text-align: left; }
		#manualSection p { font-size: 13px; color: #555; margin-bottom: 12px; line-height: 1.6; }
		#manualSection a { color: #b8a6db; }
		code { background: #f0f0f0; padding: 2px 5px; border-radius: 3px; font-family: monospace; font-size: 12px; }
		input[type=text] {
			width: 100%;
			padding: 10px 12px;
			border: 1px solid #ddd;
			border-radius: 4px;
			font-size: 13px;
			margin-bottom: 10px;
			font-family: monospace;
		}
		input[type=text]:focus { outline: none; border-color: #b8a6db; }
		button {
			background: #b8a6db;
			color: white;
			border: none;
			padding: 10px 24px;
			border-radius: 4px;
			cursor: pointer;
			font-size: 14px;
			width: 100%;
		}
		button:hover { background: #a594cc; }
		#manualStatus { font-size: 12px; margin-top: 8px; }
	</style>
</head>
<body>
<div class="container">
	<h2>Zvuk — Авторизация</h2>
	<div id="autoSection">
		<div class="spinner" id="spinner"></div>
		<div class="status" id="statusText">Получаем токен авторизации...</div>
	</div>
	<div id="manualSection">
		<p>
			Автоматическое получение токена недоступно (CORS).
			<br>
			<a href="https://zvuk.com/api/tiny/profile" target="_blank">Откройте профиль</a>,
			скопируйте значение поля <code>"token"</code> и вставьте ниже:
		</p>
		<input type="text" id="tokenInput" placeholder="Вставьте token...">
		<button onclick="saveManualToken()">Сохранить</button>
		<div class="status" id="manualStatus"></div>
	</div>
</div>
<script>
function setStatus(text, cls) {
	var el = document.getElementById('statusText');
	el.textContent = text;
	el.className = 'status' + (cls ? ' ' + cls : '');
}

function notifyAndClose(success, error) {
	if (window.opener) {
		window.opener.postMessage(
			success
				? { type: 'zvukOAuthSuccess' }
				: { type: 'zvukOAuthError', error: error || 'Unknown error' },
			'*'
		);
	}
	setTimeout(function() { window.close(); }, 2000);
}

function saveToken(token) {
	return fetch('/plugins/zvuk/saveOAuthToken', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ token: token })
	})
	.then(function(r) { return r.json(); })
	.then(function(data) {
		if (data.success) {
			document.getElementById('spinner').style.display = 'none';
			setStatus('Авторизация успешна! Окно закроется...', 'ok');
			notifyAndClose(true);
		} else {
			throw new Error(data.error || 'Server error');
		}
	});
}

function tryAutoFetch() {
	fetch('https://zvuk.com/api/tiny/profile', {
		credentials: 'include',
		headers: {
			'Accept': 'application/json',
			'Accept-Language': 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
		}
	})
	.then(function(r) {
		if (!r.ok) throw new Error('HTTP ' + r.status);
		return r.json();
	})
	.then(function(data) {
		var result = data && data.result || data;
		var token = result && result.token;
		var isAnon = result && result.is_anonymous;

		if (!token) throw new Error('no_token');
		if (isAnon) throw new Error('anonymous');

		setStatus('Токен получен, сохраняем...');
		return saveToken(token);
	})
	.catch(function(e) {
		document.getElementById('spinner').style.display = 'none';
		if (e.message === 'anonymous') {
			setStatus('Вы не авторизованы. Войдите на zvuk.com и повторите.', 'err');
		} else {
			// CORS or network error — show manual fallback
			setStatus('Автоматическое получение недоступно.', 'err');
			document.getElementById('manualSection').style.display = 'block';
		}
	});
}

function saveManualToken() {
	var token = document.getElementById('tokenInput').value.trim();
	if (!token) return;
	var ms = document.getElementById('manualStatus');
	ms.textContent = 'Сохраняем...';
	ms.className = 'status';
	saveToken(token).catch(function(e) {
		ms.textContent = 'Ошибка: ' + e.message;
		ms.className = 'status err';
	});
}

tryAutoFetch();
</script>
</body>
</html>
END_HTML

	$response->code(200);
	$response->content_type('text/html; charset=utf-8');
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$html);
}

sub handleGetAnonymousToken {
	my ($httpClient, $response) = @_;

	$log->info("Anonymous Token: Requesting from Zvuk API");

	require Slim::Networking::SimpleAsyncHTTP;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $resp = shift;
			my $data = eval { decode_json($resp->content) };
			my $token = $data && $data->{result} && $data->{result}{token};

			if ($token) {
				my $prefs = preferences('plugin.zvuk');
				my $accounts = $prefs->get('accounts') || {};
				$accounts->{anonymous} = {
					token => $token,
					name  => 'Анонимный (128kbps)',
				};
				$prefs->set('accounts', $accounts);
				$log->info("Anonymous Token: Saved token");

				$response->code(200);
				$response->content_type('application/json');
				my $json = encode_json({ success => 1 });
				Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
			}
			else {
				$log->error("Anonymous Token: No token in response: " . $resp->content);
				$response->code(500);
				$response->content_type('application/json');
				my $json = encode_json({ success => 0, error => 'No token in response' });
				Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
			}
		},
		sub {
			my ($http, $error) = @_;
			$log->error("Anonymous Token: HTTP error: $error");
			$response->code(500);
			$response->content_type('application/json');
			my $json = encode_json({ success => 0, error => $error });
			Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$json);
		}
	);

	$http->get(
		Plugins::Zvuk::API::PROFILE_URL,
		'User-Agent'      => Plugins::Zvuk::API::USER_AGENT,
		'Accept'          => 'application/json, text/plain, */*',
		'Accept-Language' => 'ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7',
		'Referer'         => 'https://zvuk.com/',
		'Origin'          => 'https://zvuk.com',
	);
}

1;
