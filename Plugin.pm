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

	# Initialize API clients for all accounts at startup
	my $accounts = $prefs->get('accounts') || {};
	foreach my $userId (keys %$accounts) {
		_init_api_client($userId);
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

sub _get_api_client {
	my ($client) = @_;
	my $userId;

	if ($client) {
		$userId = $prefs->client($client)->get('userId');
	}

	$userId ||= Plugins::Zvuk::API->getSomeUserId();

	return $api_clients{$userId} if $userId && $api_clients{$userId};
	return _init_api_client($userId) if $userId;
	return;
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	my $api = _get_api_client($client);
	
	if (!$api) {
		$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN'), type => 'text' }]);
		return;
	}

	$cb->({ items => [
		{
			name => cstring($client, 'PLUGIN_ZVUK_SEARCH'),
			type => 'outline',
			items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_TRACKS'),    type => 'search', url => \&searchTracks },
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_ARTISTS'),   type => 'search', url => \&searchArtists },
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_ALBUMS'),    type => 'search', url => \&searchAlbums },
				{ name => cstring($client, 'PLUGIN_ZVUK_SEARCH_PLAYLISTS'), type => 'search', url => \&searchPlaylists },
			],
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_WAVE'),
			type => 'link',
			url  => \&handlePersonalWave,
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_MY_MUSIC'),
			type => 'outline',
			items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_COLLECTION'), type => 'link', url => \&handleCollection },
				{ name => cstring($client, 'PLUGIN_ZVUK_PLAYLISTS'),  type => 'link', url => \&handleUserPlaylists },
			],
		},
	]});
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
	});
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
	my $url = 'zvuk://' . $track->{id} . '.mp3';
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

1;
