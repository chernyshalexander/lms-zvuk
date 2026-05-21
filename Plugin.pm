package Plugins::Zvuk::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

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
		accounts => {},
		quality  => 'high',
	});

	Plugins::Zvuk::ProtocolHandler->register();
	
	if (main::WEBUI) {
		Plugins::Zvuk::Settings->new();
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
		$log->debug("Cleared zvuk_wave_active flag");
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
			items => [
				{
					name => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_START'),
					type => 'audio',
					url  => 'zvuk://wave',
				},
				{
					name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
					type  => 'outline',
					items => _getWaveSettingsItems($client),
				},
			],
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_MY_MUSIC'),
			type  => 'outline',
			image => 'plugins/zvuk/html/images/favorites.png',
			items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_COLLECTION'),  type => 'link', url => \&handleCollection,      image => 'plugins/zvuk/html/images/personal.png' },
				{ name => cstring($client, 'ALBUMS'),                  type => 'link', url => \&handleFavoriteAlbums,  image => 'plugins/zvuk/html/images/albums.png' },
				{ name => cstring($client, 'ARTISTS'),                 type => 'link', url => \&handleFavoriteArtists, image => 'plugins/zvuk/html/images/artists.png' },
				{ name => cstring($client, 'PLUGIN_ZVUK_PLAYLISTS'),   type => 'link', url => \&handleUserPlaylists,   image => 'plugins/zvuk/html/images/playlists.png' },
				{ name => cstring($client, 'PODCASTS'),                type => 'link', url => \&handleFavoritePodcasts, image => 'plugins/zvuk/html/images/podcast.png' },
				{ name => cstring($client, 'EPISODES'),                type => 'link', url => \&handleFavoriteEpisodes, image => 'plugins/zvuk/html/images/podcast.png' },
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
			image => 'plugins/zvuk/html/images/accnts.png',
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
	my ($client, $cb, $args, $userId) = @_;

	my $accounts = $prefs->get('accounts') || {};
	unless (exists $accounts->{$userId}) {
		$cb->({ items => [{ name => 'Error: account not found', type => 'text' }] });
		return;
	}

	$prefs->client($client)->set('userId', $userId);
	$log->info("Zvuk: " . $client->name() . " switched to userId=$userId");

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
			image       => 'html/images/playall.png',
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
	return [
		{
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_POPULAR'),
			type => 'link',
			url  => \&handleSlider,
			passthrough => [{ key => 'popular' }],
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_ENERGY'),
			type => 'link',
			url  => \&handleSlider,
			passthrough => [{ key => 'energy' }],
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_FUN'),
			type => 'link',
			url  => \&handleSlider,
			passthrough => [{ key => 'fun' }],
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_LANGUAGE'),
			type => 'link',
			url  => \&handleLanguageMenu,
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_VOCAL'),
			type => 'link',
			url  => \&handleVocalMenu,
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
			type => 'link',
			url  => \&handleGenresMenu,
		},
	];
}

sub _getSettingValue {
	my ($client, $key, $default) = @_;
	return $default unless $client;

	my $api = _getAPIHandler($client);
	my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	return $settings->{$key} // $default;
}

sub _updateSetting {
	my ($client, $key, $value) = @_;
	return unless $client;

	my $api = _getAPIHandler($client);
	my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

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
	my $account_id = 'default';
	if ($client) {
		my $api = _getAPIHandler($client);
		$account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
	}

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $selected_genres = $settings->{genres} || [];
	my %selected = map { $_ => 1 } @$selected_genres;

	my @genre_items;
	foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenres() }) {
		my $is_selected = $selected{$genre->{name}} ? 1 : 0;
		my $checkbox_char = $is_selected ? '[x]' : '[ ]';
		push @genre_items, {
			name => "$checkbox_char " . string($genre->{label}),
			type => 'link',
			url => \&handleGenreToggle,
			passthrough => [{ genre => $genre->{name}, account_id => $account_id }],
		};
	}

	push @genre_items, {
		name => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type => 'link',
		url  => sub {
			my ($cl, $cb) = @_;
			$cb->({ items => _getWaveSettingsItems($cl) });
		},
	};

	return \@genre_items;
}

sub handleGenreToggle {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $genre_name = $params->{genre};
	my $account_id = $params->{account_id};

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
	my $api = Plugins::Zvuk::API::Async->new();
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

sub _getSliderItems {
	my ($client, $key) = @_;
	my $current_value = _getSettingValue($client, $key, 0.5);

	my @slider_items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $marker = abs($val - $current_value) < 0.01 ? '[x]' : '[ ]';
		push @slider_items, {
			name => sprintf("$marker %.1f", $val),
			type => 'link',
			url => \&handleSliderValue,
			passthrough => [{ key => $key, value => $val }],
		};
	}

	push @slider_items, {
		name => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type => 'link',
		url  => sub {
			my ($cl, $cb) = @_;
			$cb->({ items => _getWaveSettingsItems($cl) });
		},
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
			name => ($current_lang eq 'all' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_ALL'),
			type => 'link',
			url => \&handleLanguageSelect,
			passthrough => [{ language => 'all' }],
		},
		{
			name => ($current_lang eq 'foreign' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_FOREIGN'),
			type => 'link',
			url => \&handleLanguageSelect,
			passthrough => [{ language => 'foreign' }],
		},
		{
			name => ($current_lang eq 'russian' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN'),
			type => 'link',
			url => \&handleLanguageSelect,
			passthrough => [{ language => 'russian' }],
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type => 'link',
			url  => sub {
				my ($cl, $cb) = @_;
				$cb->({ items => _getWaveSettingsItems($cl) });
			},
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
			name => ($current_vocal == 1 ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_VOCAL_WITH'),
			type => 'link',
			url => \&handleVocalSelect,
			passthrough => [{ vocal => 1 }],
		},
		{
			name => ($current_vocal == 0 ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_VOCAL_WITHOUT'),
			type => 'link',
			url => \&handleVocalSelect,
			passthrough => [{ vocal => 0 }],
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type => 'link',
			url  => sub {
				my ($cl, $cb) = @_;
				$cb->({ items => _getWaveSettingsItems($cl) });
			},
		},
	);

	return \@vocal_items;
}

1;
