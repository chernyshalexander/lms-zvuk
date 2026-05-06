package Plugins::Zvuk::Plugin;

use strict;
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
		feed     => \&handleFeed,
		tag      => 'zvuk',
		menu     => 'apps',
		icon     => 'plugins/Zvuk/html/images/logo.png',
		jiveIcon => 'plugins/Zvuk/html/images/logo.png',
		weight   => 10,
	);

	# Initialize API clients for all accounts at startup
	my $accounts = $prefs->get('accounts') || {};
	foreach my $userId (keys %$accounts) {
		_init_api_client($userId);
	}

	# Register global search provider like Yandex
	Slim::Menu::GlobalSearch->registerInfoProvider( zvuk => (
		func => sub {
			my ($client, $tags) = @_;
			return {
				name  => 'Zvuk',
				items => _globalSearchItems($client, $tags->{search}),
			};
		},
	) );
}

sub _init_api_client {
	my ($userId) = @_;
	my $accounts = $prefs->get('accounts') || {};
	my $account  = $accounts->{$userId};

	if ($account && $account->{token}) {
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
		$cb->({
			items => [{
				name => cstring($client, 'PLUGIN_ZVUK_NO_ACCOUNTS'),
				type => 'text',
			}]
		});
		return;
	}

	_renderRootMenu($client, $cb, $api);
}

sub _renderRootMenu {
	my ($client, $cb, $api) = @_;

	my @menu = (
		{
			name => cstring($client, 'PLUGIN_ZVUK_SEARCH'),
			type => 'search',
			url  => \&search,
			passthrough => [$api],
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_MY_MUSIC'),
			type => 'outline',
			items => [
				{
					name => cstring($client, 'PLUGIN_ZVUK_COLLECTION'),
					type => 'link',
					url  => \&handleCollection,
					passthrough => [$api],
				},
				{
					name => cstring($client, 'PLUGIN_ZVUK_PLAYLISTS'),
					type => 'link',
					url  => \&handleUserPlaylists,
					passthrough => [$api],
				},
				{
					name => cstring($client, 'PLUGIN_ZVUK_WAVE'),
					type => 'audio',
					url  => \&handleWave,
					passthrough => [$api],
				}
			]
		},
		{
			name => cstring($client, 'PLUGIN_ZVUK_SELECT_ACCOUNT'),
			type => 'link',
			url  => \&handleSelectAccount,
		}
	);

	$cb->({ items => \@menu });
}

sub _globalSearchItems {
	my ($client, $query) = @_;
	return [] unless $query;

	return [
		{
			name        => cstring($client, 'PLUGIN_ZVUK_SEARCH'),
			url         => \&search,
			passthrough => [undef, { search => $query }],
		},
	];
}

# --- Browse Handlers ---

sub search {
	my ($client, $cb, $args, $api) = @_;

	my $query = $args->{search} || return $cb->([]);
	$api ||= _get_api_client($client);
	
	$log->info("Searching Zvuk for: $query");

	$api->search(sub {
		my $data = shift;

		if ($data->{error}) {
			$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_API'), type => 'text' }]);
			return;
		}

		my $content = $data->{quickSearch}{content} || [];
		my @items;

		foreach my $item (@$content) {
			if ($item->{__typename} eq 'Track') {
				push @items, _renderTrack($item, $client);
			}
			elsif ($item->{__typename} eq 'Artist') {
				push @items, _renderArtist($item, $client, $api);
			}
			elsif ($item->{__typename} eq 'Release') {
				push @items, _renderAlbum($item, $client, $api);
			}
			elsif ($item->{__typename} eq 'Playlist') {
				push @items, _renderPlaylist($item, $client, $api);
			}
		}

		$cb->({ items => \@items });
	}, { query => $query });
}

sub handleCollection {
	my ($client, $cb, $args, $api) = @_;
	$api ||= _get_api_client($client);
	my $after = $args->{after} || "";

	$api->getCollection(sub {
		my $data = shift;

		if ($data->{error}) {
			$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_API'), type => 'text' }]);
			return;
		}

		my $tracksData = $data->{paginatedCollection}{tracks};
		my $tracks = $tracksData->{items} || [];
		my $endCursor = $tracksData->{page}{endCursor};

		my @items = map { _renderTrack($_, $client) } @$tracks;

		if ($endCursor) {
			push @items, {
				name => cstring($client, 'NEXT_PAGE'),
				type => 'link',
				url  => \&handleCollection,
				passthrough => [$api, { after => $endCursor }],
			};
		}

		$cb->({ items => \@items });
	}, { after => $after });
}

sub handleWave {
	my ($client, $cb, $args, $api) = @_;
	$api ||= _get_api_client($client);

	my $limit = $args->{limit} || 50;

	$api->getPersonalWave(sub {
		my $data = shift;

		if ($data->{error}) {
			$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_API'), type => 'text' }]);
			return;
		}

		my $tracks = $data->{personalWaveContent} || [];
		my @items = map { _renderTrack($_, $client) } @$tracks;

		if (scalar(@items) >= $limit) {
			push @items, {
				name => cstring($client, 'PLUGIN_ZVUK_LOAD_MORE_WAVE'),
				type => 'link',
				url  => \&handleWave,
				passthrough => [$api, { limit => $limit }],
			};
		}

		$cb->({ items => \@items });
	}, { first => $limit });
}
sub handleUserPlaylists {
	my ($client, $cb, $args, $api) = @_;
	$api ||= _get_api_client($client);
	my $after = $args->{after} || "";

	$api->getUserPlaylists(sub {
		my $data = shift;

		if ($data->{error}) {
			$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_API'), type => 'text' }]);
			return;
		}

		my $playlistsData = $data->{paginatedCollection}{playlists};
		my $playlists = $playlistsData->{items} || [];
		my $endCursor = $playlistsData->{page}{endCursor};

		my @items = map { _renderPlaylist($_, $client, $api) } @$playlists;

		if ($endCursor) {
			push @items, {
				name => cstring($client, 'NEXT_PAGE'),
				type => 'link',
				url  => \&handleUserPlaylists,
				passthrough => [$api, { after => $endCursor }],
			};
		}

		$cb->({ items => \@items });
	}, { after => $after });
}

sub _renderTrack {
	my ($track, $client) = @_;
	my $icon = Plugins::Zvuk::API->getImageUrl($track, 1);

	Plugins::Zvuk::API->cacheTrackMetadata([$track]);

	my $url = 'zvuk://' . $track->{id} . '.mp3';
	return {
		name            => $track->{title},
		favorites_title => $track->{title} . ' - ' . $track->{artistTemplate},
		line1           => $track->{title},
		line2           => $track->{artistTemplate},
		type            => 'audio',
		url             => $url,
		play            => $url,
		on_select       => 'play',
		playall         => 1,
		icon            => $icon,
		image           => $icon,
	};
}

sub _renderArtist {
	my ($artist, $client, $api) = @_;
	my $icon = Plugins::Zvuk::API->getImageUrl($artist, 1);

	return {
		name => $artist->{title},
		type => 'link',
		url  => \&handleArtist,
		passthrough => [$api, { id => $artist->{id} }],
		icon => $icon,
		image => $icon,
	};
}

sub _renderAlbum {
	my ($album, $client, $api) = @_;
	my $icon = Plugins::Zvuk::API->getImageUrl($album, 1);

	return {
		name            => $album->{title},
		line1           => $album->{title},
		line2           => $album->{artistTemplate},
		type            => 'link',
		url             => \&handleAlbum,
		passthrough     => [$api, { id => $album->{id} }],
		favorites_url   => 'zvuk://album:' . $album->{id},
		favorites_type  => 'playlist',
		icon            => $icon,
		image           => $icon,
	};
}

sub _renderPlaylist {
	my ($playlist, $client, $api) = @_;
	my $icon = Plugins::Zvuk::API->getImageUrl($playlist, 1);

	return {
		name            => $playlist->{title},
		type            => 'link',
		url             => \&handlePlaylist,
		passthrough     => [$api, { id => $playlist->{id} }],
		favorites_url   => 'zvuk://playlist:' . $playlist->{id},
		favorites_type  => 'playlist',
		icon            => $icon,
		image           => $icon,
	};
}

# Drill-down handlers

sub handleArtist {
	my ($client, $cb, $args, $api) = @_;
	my $id = $args->{id};
	$api ||= _get_api_client($client);

	my @items = (
		{
			name        => cstring($client, 'PLUGIN_ZVUK_TOP_TRACKS'),
			type        => 'link',
			url         => \&handleArtistTopTracks,
			image       => 'html/images/playall.png',
			passthrough => [$api, { id => $id }],
		},
		{
			name        => cstring($client, 'PLUGIN_ZVUK_ALBUMS'),
			type        => 'link',
			url         => \&handleArtistAlbums,
			image       => 'html/images/albums.png',
			passthrough => [$api, { id => $id }],
		},
	);
	$cb->({ items => \@items });
}

sub handleArtistTopTracks {
	my ($client, $cb, $args, $api) = @_;
	my $id = $args->{id};
	$api ||= _get_api_client($client);

	$api->getArtist(sub {
		my $data = shift;
		my $artist = $data->{getArtists}->[0];
		my $tracks = $artist->{topTracks} || [];

		my @items = map { _renderTrack($_, $client) } @$tracks;
		$cb->({ items => \@items });
	}, $id);
}

sub handleArtistAlbums {
	my ($client, $cb, $args, $api) = @_;
	my $id = $args->{id};
	$api ||= _get_api_client($client);

	$api->getArtistAlbums(sub {
		my $data = shift;
		my $artist = $data->{getArtists}->[0];
		my $albums = $artist->{releases} || [];

		my @items = map { _renderAlbum($_, $client, $api) } @$albums;
		$cb->({ items => \@items });
	}, $id);
}

sub handleAlbum {
	my ($client, $cb, $args, $api) = @_;
	my $id = $args->{id};
	$api ||= _get_api_client($client);

	$api->getAlbum(sub {
		my $data = shift;
		my $releases = $data->{getReleases} || [];
		my $album = $releases->[0];
		my $tracks = $album ? ($album->{tracks} || []) : [];

		my @items = map { _renderTrack($_, $client) } @$tracks;
		$cb->({ items => \@items });
	}, $id);
}

sub handlePlaylist {
	my ($client, $cb, $args, $api) = @_;
	my $id = $args->{id};
	my $offset = $args->{offset} || 0;
	$api ||= _get_api_client($client);

	my $limit = Plugins::Zvuk::API::DEFAULT_LIMIT;

	$api->getPlaylistTracks(sub {
		my $data = shift;

		if ($data->{error}) {
			$cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_API'), type => 'text' }]);
			return;
		}

		my $playlistData = $data->{playlistTracks} || {};
		my $tracks = $playlistData->{items} || [];
		my $total = $playlistData->{total} || 0;

		my @items = map { _renderTrack($_, $client) } @$tracks;

		if ($offset + $limit < $total) {
			push @items, {
				name => cstring($client, 'NEXT_PAGE'),
				type => 'link',
				url  => \&handlePlaylist,
				passthrough => [$api, { id => $id, offset => $offset + $limit }],
			};
		}

		$cb->({ items => \@items });
	}, $id, $limit, $offset);
}

sub handleSelectAccount {
	my ($client, $cb, $args) = @_;

	my $accounts = $prefs->get('accounts') || {};
	my @items;

	foreach my $userId (sort keys %$accounts) {
		my $acc = $accounts->{$userId};
		push @items, {
			name => $acc->{name} || $userId,
			type => 'link',
			url  => sub {
				my ($client, $cb) = @_;
				if ($client) {
					$prefs->client($client)->set('userId', $userId);
				}
				handleFeed($client, $cb);
			},
		};
	}

	$cb->({ items => \@items });
}

sub _pluginDataFor {
	my ($class, $data) = @_;
	my $info = Slim::Utils::PluginManager->dataForPlugin($class);
	return $info ? $info->{$data} : undef;
}

1;
