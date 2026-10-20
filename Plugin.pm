package Plugins::Zvuk::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::OPMLBased);

use Encode qw(decode_utf8 encode_utf8);
use JSON::XS;
use JSON::XS::VersionOneAndTwo;
use URI::QueryParam;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Zvuk::API;
use Plugins::Zvuk::API::Async;
use Plugins::Zvuk::ProtocolHandler;
use Plugins::Zvuk::Settings;
use Plugins::Zvuk::WaveSettings;
use Plugins::Zvuk::GigaMix;
use Plugins::Zvuk::WaveUI;
use Plugins::Zvuk::WebHandlers;
use Plugins::Zvuk::Browse::InfoMenu;
use Plugins::Zvuk::AtlasUI;

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
		accounts               => {},
		quality                => 'high',
		gigamix_autoplay       => 0,
		material_settings_mode => 'iframe',
	});

	Plugins::Zvuk::ProtocolHandler->register();
	Plugins::Zvuk::Browse::InfoMenu->init();
	
	if (main::WEBUI) {
		Plugins::Zvuk::Settings->new();

			# Register web routes for AJAX and web pages
			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/waveSettings',
				\&Plugins::Zvuk::WebHandlers::handleWaveSettingsWebUI
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/waveStandalone',
				\&Plugins::Zvuk::WebHandlers::handleWaveSettingsStandalone
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/waveStandalone.html',
				\&Plugins::Zvuk::WebHandlers::handleWaveSettingsStandalone
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/saveWaveSettings',
				\&Plugins::Zvuk::WebHandlers::handleSaveWaveSettingsWeb
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/getWaveSettings',
				\&Plugins::Zvuk::WebHandlers::handleGetWaveSettingsWeb
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/saveOAuthToken',
				\&Plugins::Zvuk::WebHandlers::handleSaveOAuthToken
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/oauthCallback',
				\&Plugins::Zvuk::WebHandlers::handleOAuthCallback
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/getAnonymousToken',
				\&Plugins::Zvuk::WebHandlers::handleGetAnonymousToken
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/requestSmsCode',
				\&Plugins::Zvuk::WebHandlers::handleRequestSmsCode
			);

			Slim::Web::Pages->addRawFunction(
				'plugins/zvuk/verifySmsCode',
				\&Plugins::Zvuk::WebHandlers::handleVerifySmsCode
			);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/imageproxy',
			\&Plugins::Zvuk::WebHandlers::handleImageProxy
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/atlasStandalone',
			\&Plugins::Zvuk::WebHandlers::handleAtlasStandalone
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/atlasStandalone.html',
			\&Plugins::Zvuk::WebHandlers::handleAtlasStandalone
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/getAtlasMap',
			\&Plugins::Zvuk::WebHandlers::handleGetAtlasMapWeb
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

	# Register info providers for TrackInfo, AlbumInfo, and ArtistInfo menus
	eval {
		if (eval { Slim::Menu::TrackInfo->can('registerInfoProvider') }) {
			Slim::Menu::TrackInfo->registerInfoProvider( zvuk => (
				before => 'top',
				func  => \&Plugins::Zvuk::Browse::InfoMenu::trackInfoMenu,
			) );
		}
		if (eval { Slim::Menu::AlbumInfo->can('registerInfoProvider') }) {
			Slim::Menu::AlbumInfo->registerInfoProvider( zvuk => (
				before => 'top',
				func  => \&Plugins::Zvuk::Browse::InfoMenu::albumInfoMenu,
			) );
		}
		if (eval { Slim::Menu::ArtistInfo->can('registerInfoProvider') }) {
			Slim::Menu::ArtistInfo->registerInfoProvider( zvuk => (
				before => 'top',
				func  => \&Plugins::Zvuk::Browse::InfoMenu::artistInfoMenu,
			) );
		}
	};
	if ($@) {
		$log->error("Error registering info providers: $@");
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
		$client->pluginData(zvuk_radio_active => 0);
		$client->pluginData(zvuk_radio_entity_id => undef);
		$client->pluginData(zvuk_radio_entity_type => undef);
		$client->pluginData(zvuk_radio_cursor => undef);
		$client->pluginData(zvuk_radio_loading => 0);
		$client->pluginData(zvuk_atlas_active => 0);
		$client->pluginData(zvuk_atlas_island_id => undef);
		$client->pluginData(zvuk_atlas_cursor => undef);
		$client->pluginData(zvuk_atlas_loading => 0);
		$client->pluginData(zvuk_wave_last_track => undef);
		$log->debug("Cleared zvuk_wave_active, zvuk_gigamix_active, zvuk_radio_active, zvuk_atlas_active and zvuk_wave_last_track flags");
	}
}

sub _clear_api_client {
	my $userId = @_ > 1 ? $_[1] : $_[0];
	if (defined $userId) {
		delete $api_clients{$userId};
	} else {
		%api_clients = ();
	}
}

sub _init_api_client {
	my $userId = @_ > 1 ? $_[1] : $_[0];
	return unless defined $userId && length($userId);

	my $accounts = $prefs->get('accounts');
	return unless ref $accounts eq 'HASH';
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
	my $accounts = $prefs->get('accounts');
	$accounts = {} unless ref $accounts eq 'HASH';

	my $userId = $client ? $prefs->client($client)->get('userId') : undef;

	# If client has a valid, existing account with a token, use it
	if (defined $userId && length($userId) && $accounts->{$userId} && $accounts->{$userId}{token}) {
		return $userId;
	}

	# Stale or non-existent client userId (or client has none set):
	# Fall back to defaultUserId or any valid configured account
	my $fallbackUserId = Plugins::Zvuk::API->getSomeUserId();

	# Self-heal: update client's preference to valid account
	if ($client && defined $fallbackUserId && length($fallbackUserId)) {
		eval {
			$prefs->client($client)->set('userId', $fallbackUserId);
		};
		my $clientId = (ref $client && $client->can('id')) ? $client->id : "$client";
		$log->info("Zvuk: Auto-healed client $clientId userId: " . (defined $userId ? $userId : 'undef') . " -> $fallbackUserId");
	}

	return $fallbackUserId;
}

sub _get_api_client {
	my ($client) = @_;
	my $userId = _getUserIdForClient($client);
	return unless defined $userId && length($userId);

	my $accounts = $prefs->get('accounts');
	return unless ref $accounts eq 'HASH';
	return unless $accounts->{$userId} && $accounts->{$userId}{token};

	return $api_clients{$userId} if $api_clients{$userId};
	return _init_api_client($userId);
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	unless (_get_api_client($client)) {
		$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN'), type => 'text' }]);
		return;
	}

	_buildRootMenu($client, $cb, $args);
}

sub _buildRootMenu {
	my ($client, $cb, $args) = @_;

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
			items => Plugins::Zvuk::WaveUI::_getWaveMenuItems($client, $args),
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_ATLAS'),
			type  => 'outline',
			image => 'plugins/zvuk/html/images/playlists.png',
			url   => \&Plugins::Zvuk::AtlasUI::handleAtlasMenu,
		},
			{
				name  => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS'),
				type  => 'outline',
				image => 'plugins/zvuk/html/images/playlists.png',
				items => [
					{
						name  => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS'),
						type  => 'link',
						image => 'plugins/zvuk/html/images/playlists.png',
						url   => \&handlePersonalizedPlaylists,
					},
					{
						name  => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_MIXED'),
						type  => 'link',
						image => 'plugins/zvuk/html/images/playlists.png',
						url   => \&handleRecommendations,
					},
				],
			},
				{
					name  => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS'),
					type  => 'link',
					image => 'plugins/zvuk/html/images/playlists.png',
					url   => \&handleEditorialPlaylists,
				},
			{
				name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX'),
				type  => 'link',
				image => 'plugins/zvuk/html/images/playlists.png',
				url   => \&Plugins::Zvuk::GigaMix::handleGigaMix,
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
	my $radioUrl = 'zvuk://radio:artist:' . $id;

	$cb->({ items => [
		{
			name        => cstring($client, 'PLUGIN_ZVUK_ARTIST_RADIO'),
			type        => 'link',
			nextWindow  => 'nowPlaying',
			playcontrol => 'play',
			image       => 'html/images/radio.png',
			url         => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['playlist', 'play', $radioUrl]);
				$cb->({ items => [] });
			},
			itemActions => {
				go => {
					player     => 0,
					cmd        => ['playlist', 'play'],
					params     => { url => $radioUrl },
					nextWindow => 'nowPlaying',
				},
			},
		},
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
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	# Fetches the first dynamicBlock page and renders the menu from it.
	$api->getMusicRecommendations(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("getMusicRecommendations failed: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_ERROR'), type => 'text' },
			]});
			return;
		}

		my $totalCount = $result->{totalCount} || 0;
		unless ($totalCount > 0) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_EMPTY'), type => 'text' },
			]});
			return;
		}

		# Show categories for recommendations
		my @menuItems;

		# Artists category
		# Pass the already-fetched items through so drilling into a category
		# doesn't re-issue the same getMusicRecommendations request.
		my $artists = $result->{artists} || [];
		if (@$artists) {
			push @menuItems, {
				name => cstring($client, 'PLUGIN_ZVUK_ARTISTS') . ' (' . scalar(@$artists) . ')',
				type => 'link',
				url  => \&handleRecommendationArtists,
				passthrough => [{ artists => $artists }],
			};
		}

		# Releases (Albums) category
		my $releases = $result->{releases} || [];
		if (@$releases) {
			push @menuItems, {
				name => cstring($client, 'PLUGIN_ZVUK_ALBUMS') . ' (' . scalar(@$releases) . ')',
				type => 'link',
				url  => \&handleRecommendationAlbums,
				passthrough => [{ releases => $releases }],
			};
		}

		# Playlists category
		my $playlists = $result->{playlists} || [];
		if (@$playlists) {
			push @menuItems, {
				name => cstring($client, 'PLUGIN_ZVUK_PLAYLISTS') . ' (' . scalar(@$playlists) . ')',
				type => 'link',
				url  => \&handleRecommendationPlaylists,
				passthrough => [{ playlists => $playlists }],
			};
		}

		$cb->({ items => \@menuItems });
	}, {
		contentType => 'Music',
		itemTypes   => ['Artist', 'Release', 'Playlist'],
	});
}

sub handleRecommendationArtists {
	my ($client, $cb, $args, $passthrough) = @_;

	# Normal path: category items already fetched by handleRecommendations
	# and handed down via passthrough, so avoid a redundant round-trip.
	if ($passthrough && $passthrough->{artists}) {
		$cb->({ items => [ map { _renderArtist($_) } @{ $passthrough->{artists} } ] });
		return;
	}

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

		my $artists = $result->{artists} || [];
		unless (@$artists) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_EMPTY'), type => 'text' },
			]});
			return;
		}

		$cb->({ items => [ map { _renderArtist($_) } @$artists ] });
	}, {
		contentType => 'Music',
		itemTypes   => ['Artist', 'Release', 'Playlist'],
	});
}

sub handleRecommendationAlbums {
	my ($client, $cb, $args, $passthrough) = @_;

	if ($passthrough && $passthrough->{releases}) {
		$cb->({ items => [ map { _renderAlbum($_) } @{ $passthrough->{releases} } ] });
		return;
	}

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

		my $releases = $result->{releases} || [];
		unless (@$releases) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_EMPTY'), type => 'text' },
			]});
			return;
		}

		$cb->({ items => [ map { _renderAlbum($_) } @$releases ] });
	}, {
		contentType => 'Music',
		itemTypes   => ['Artist', 'Release', 'Playlist'],
	});
}

sub handleRecommendationPlaylists {
	my ($client, $cb, $args, $passthrough) = @_;

	if ($passthrough && $passthrough->{playlists}) {
		$cb->({ items => [ map { _renderPlaylist($_) } @{ $passthrough->{playlists} } ] });
		return;
	}

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

		my $playlists = $result->{playlists} || [];
		unless (@$playlists) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_EMPTY'), type => 'text' },
			]});
			return;
		}

		$cb->({ items => [ map { _renderPlaylist($_) } @$playlists ] });
	}, {
		contentType => 'Music',
		itemTypes   => ['Artist', 'Release', 'Playlist'],
	});
}

sub handleEditorialPlaylists {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$log->info("Loading editorial playlists for client");

	# Step 1: Get editorial playlist IDs from Grid API
	$api->getEditorialPlaylistIds(sub {
		my ($ids, $error) = @_;

		if ($error) {
			$log->error("getEditorialPlaylistIds failed: $error");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_ERROR'), type => 'text' },
			]});
			return;
		}

		unless ($ids && @$ids) {
			$log->info("No editorial playlists available");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY'), type => 'text' },
			]});
			return;
		}

		$log->info("Got " . scalar(@$ids) . " editorial playlist IDs, loading metadata");

			# Step 2: Get lightweight metadata for all playlists
			$api->getEditorialPlaylistMetadata(sub {
				my $playlists = shift;

			unless ($playlists && @$playlists) {
				$log->warn("getShortPlaylist returned empty results");
				$cb->({ items => [
					{ name => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY'), type => 'text' },
				]});
				return;
			}

			$log->info("Got metadata for " . scalar(@$playlists) . " editorial playlists");
			# Step 3: Render all playlists
			my @items = map { _renderEditorialPlaylist($_) } @$playlists;

			$cb->({ items => \@items });
		}, $ids);
	});
}

# --- Rendering Helpers ---

sub _renderTrack {
	my ($track, $showArtist) = @_;
	my $url = 'zvuk://' . $track->{id};
	my $artist = _getArtistName($track);
	my $artist_id = ($track->{artists} && ref $track->{artists} eq 'ARRAY' && $track->{artists}->[0]) ? $track->{artists}->[0]->{id} : '';
	my $release_id = ($track->{release} && ref $track->{release} eq 'HASH') ? $track->{release}->{id} : '';

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
		itemActions     => {
			info => {
				command     => ['zvuk_info', 'items'],
				fixedParams => {
					type       => 'track',
					id         => $track->{id},
					url        => $url,
					track      => $track->{title},
					artist     => $artist,
					artist_id  => $artist_id,
					album      => ($track->{release}->{title} || ''),
					release_id => $release_id,
				},
			},
		},
	};
}

sub _getArtistName { Plugins::Zvuk::API->_getArtistName($_[0]) }

sub _renderRelease {
	my ($release) = @_;
	my $releaseId = $release->{id};
	my $artist    = _getArtistName($release);
	my $title     = $release->{title};
	my $url       = 'zvuk://album:' . $releaseId;

	return {
		name            => $title . ($artist ? " ($artist)" : ""),
		favorites_title => $title . ($artist ? " - " . $artist : ""),
		favorites_type  => 'playlist',
		favorites_url   => $url,
		line1           => $title,
		line2           => $artist,
		type            => 'playlist',
		url             => \&handleAlbum,
		play            => $url,
		image           => Plugins::Zvuk::API->getImageUrl($release),
		passthrough     => [{ id => $releaseId, releaseId => $releaseId }],
		itemActions     => {
			info => {
				command     => ['zvuk_info', 'items'],
				fixedParams => { type => 'album', id => $releaseId, url => $url, album => $title, artist => $artist },
			},
		},
	};
}

sub _renderAlbum {
	my ($album) = @_;
	return _renderRelease($album);
}

sub _renderArtist {
	my ($artist) = @_;
	my $url = 'zvuk://artist:' . $artist->{id};
	return {
		name        => $artist->{title},
		type        => 'link',
		url         => \&handleArtist,
		passthrough => [{ id => $artist->{id} }],
		image       => Plugins::Zvuk::API->getImageUrl($artist),
		itemActions => {
			info => {
				command     => ['zvuk_info', 'items'],
				fixedParams => { type => 'artist', id => $artist->{id}, url => $url, artist => $artist->{title} },
			},
		},
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

sub _renderEditorialPlaylist {
	my ($playlist) = @_;

	return {
		name      => $playlist->{title},
		line1     => $playlist->{title},
		line2     => $playlist->{description} || "",
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
	my $url = 'zvuk://episode:' . $episode->{id};
	return {
		name      => $episode->{title},
		line1     => $episode->{title},
		line2     => $podcast_name,
		duration  => $episode->{duration},
		secs      => $episode->{duration},
		on_select => 'play',
		url       => $url,
		play      => $url,
		playall   => 1,
		type      => 'audio',
		image     => $episode->{podcast} ? Plugins::Zvuk::API->getImageUrl($episode->{podcast}) : "",
	};
}


1;
