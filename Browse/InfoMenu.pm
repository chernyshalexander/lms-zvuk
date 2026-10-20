package Plugins::Zvuk::Browse::InfoMenu;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('plugin.zvuk');

sub init {
	my $class = shift;

	# CLI dispatch for item context menus across all LMS UIs
	Slim::Control::Request::addDispatch(
		[ 'zvuk_info', 'items', '_index', '_quantity' ],
		[ 1, 1, 1, \&menuInfoCLI ]
	);
}

sub menuInfoCLI {
	my $request = shift;
	my $client  = $request->client;
	my $type    = $request->getParam('type') || '';
	my $id      = $request->getParam('id')   || '';
	my $url     = $request->getParam('url')  || ($type && $id ? "zvuk://$type:$id" : '');
	my $album   = $request->getParam('album')  || '';
	my $artist  = $request->getParam('artist') || '';
	my $artist_id  = $request->getParam('artist_id') || '';
	my $track      = $request->getParam('track')  || '';
	my $release_id = $request->getParam('release_id') || '';

	my $remoteMeta = {
		album      => $album,
		artist     => $artist,
		artist_id  => $artist_id,
		track      => $track,
		release_id => $release_id,
		url        => $url,
	};

	my $feed;
	if ($type eq 'album' || $url =~ m{^zvuk://album[:/](\d+)}) {
		$feed = albumInfoMenu($client, $url, undef, $remoteMeta);
	} elsif ($type eq 'artist' || $url =~ m{^zvuk://artist[:/](\d+)}) {
		$feed = artistInfoMenu($client, $url, undef, $remoteMeta);
	} elsif ($type eq 'track' || $url =~ m{^zvuk://(?:track[:/])?(\d+)}) {
		$feed = trackInfoMenu($client, $url, undef, $remoteMeta);
	}

	$feed ||= { items => [{ name => cstring($client, 'EMPTY'), type => 'text' }] };

	Slim::Control::XMLBrowser::cliQuery('zvuk_info', $feed, $request);
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta) = @_;

	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);
	return unless $api;

	my $albumUrl = $url || ($album && blessed($album) && $album->can('url') ? $album->url : '') || ($remoteMeta ? ($remoteMeta->{url} || '') : '') || '';
	my $albumId;
	if ($albumUrl =~ m{zvuk://(?:album[:/])?(\d+)}) {
		$albumId = $1;
	}

	return unless $albumId;
	my $targetUrl = 'zvuk://album:' . $albumId;
	my $albumTitle = ($remoteMeta && $remoteMeta->{album}) || ($album && blessed($album) && $album->can('title') ? $album->title : 'Zvuk Album');
	my $artistTitle = ($remoteMeta && $remoteMeta->{artist}) || ($album && blessed($album) && $album->can('artist') ? $album->artist : '');
	my $favTitle = $albumTitle . ($artistTitle ? " - $artistTitle" : "");

	# Check LMS Favorites status
	my $favToken = 'JIVE_SAVE_TO_FAVORITES';
	my $favCmd   = 'add';
	if (defined &Slim::Utils::PluginManager::isEnabled && Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Favorites::Plugin')) {
		eval {
			require Slim::Utils::Favorites;
			my $favs = Slim::Utils::Favorites->new($client);
			if (defined $favs->findUrl($targetUrl)) {
				$favToken = 'JIVE_DELETE_FROM_FAVORITES';
				$favCmd   = 'delete';
			}
		};
	}

	my @items = (
		{
			name        => cstring($client, 'ADD_TO_END'),
			type        => 'link',
			nextWindow  => 'parent',
			playcontrol => 'add',
			url         => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['playlist', 'add', $targetUrl]);
				$cb->({ items => [] });
			},
			itemActions => {
				go => {
					player     => 0,
					cmd        => ['playlist', 'add'],
					params     => { url => $targetUrl },
					nextWindow => 'parent',
				},
			},
		},
		{
			name        => cstring($client, 'PLAY_NEXT'),
			type        => 'link',
			nextWindow  => 'parent',
			playcontrol => 'insert',
			url         => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['playlist', 'insert', $targetUrl]);
				$cb->({ items => [] });
			},
			itemActions => {
				go => {
					player     => 0,
					cmd        => ['playlist', 'insert'],
					params     => { url => $targetUrl },
					nextWindow => 'parent',
				},
			},
		},
		{
			name        => cstring($client, 'PLAY'),
			type        => 'link',
			nextWindow  => 'nowPlaying',
			playcontrol => 'play',
			url         => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['playlist', 'play', $targetUrl]);
				$cb->({ items => [] });
			},
			itemActions => {
				go => {
					player     => 0,
					cmd        => ['playlist', 'play'],
					params     => { url => $targetUrl },
					nextWindow => 'nowPlaying',
				},
			},
		},
		{
			name      => cstring($client, 'PLUGIN_ZVUK_ALBUM_RADIO'),
			type      => 'audio',
			url       => 'zvuk://radio:release:' . $albumId,
			play      => 'zvuk://radio:release:' . $albumId,
			on_select => 'play',
			image     => 'html/images/radio.png',
		},
		{
			name        => cstring($client, $favToken),
			type        => 'link',
			nextWindow  => 'parent',
			url         => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['jivefavorites', $favCmd, "url:$targetUrl", "title:$favTitle", 'type:playlist']);
				$cb->({ items => [] });
			},
			itemActions => {
				go => {
					player     => 0,
					cmd        => ['jivefavorites', $favCmd],
					params     => { url => $targetUrl, title => $favTitle, type => 'playlist' },
					nextWindow => 'parent',
				},
			},
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_ON_ZVUK'),
			items => [
				{
					name        => cstring($client, 'PLUGIN_ZVUK_LIKE_ALBUM'),
					type        => 'link',
					url         => \&_doLikeRelease,
					passthrough => [$api, $albumId],
				},
				{
					name        => cstring($client, 'PLUGIN_ZVUK_UNLIKE_ALBUM'),
					type        => 'link',
					url         => \&_doUnlikeRelease,
					passthrough => [$api, $albumId],
				},
			],
		},
	);

	return { items => \@items };
}

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);
	return unless $api;

	my $trackUrl = $url || ($track && blessed($track) && $track->can('url') ? $track->url : '') || ($remoteMeta ? ($remoteMeta->{url} || '') : '') || '';
	my $trackId;
	if ($trackUrl =~ m{zvuk://(?:(?:track|episode)[:/])?(\d+)}) {
		$trackId = $1;
	}

	my $trackTitle  = ($remoteMeta && $remoteMeta->{track}) || ($remoteMeta && $remoteMeta->{title}) || ($track && blessed($track) && $track->can('title') ? $track->title : '');
	my $artistTitle = ($remoteMeta && $remoteMeta->{artist}) || ($track && blessed($track) && $track->can('artist') ? $track->artist : '') || ($track && blessed($track) && $track->can('artistName') ? $track->artistName : '');
	my $artistId    = ($remoteMeta && $remoteMeta->{artist_id});
	my $albumTitle  = ($remoteMeta && $remoteMeta->{album}) || ($track && blessed($track) && $track->can('album') ? ($track->album ? (ref $track->album ? $track->album->name : $track->album) : '') : '');
	my $releaseId   = ($remoteMeta && $remoteMeta->{release_id});

	# If missing details, try retrieving from track cache
	if ($trackId && (!$artistId || !$artistTitle || !$trackTitle || !$releaseId || !$albumTitle)) {
		if (my $cached = Plugins::Zvuk::API->cache->get("zvuk_meta_$trackId")) {
			$trackTitle  ||= $cached->{title};
			$artistTitle ||= $cached->{artist};
			$artistId    ||= $cached->{artist_id};
			if (!$artistId && $cached->{artists} && ref $cached->{artists} eq 'ARRAY' && $cached->{artists}->[0]) {
				$artistId = $cached->{artists}->[0]->{id};
			}
			$releaseId   ||= $cached->{release_id};
			$albumTitle  ||= $cached->{album};
			if (!$releaseId && $cached->{release} && ref $cached->{release} eq 'HASH') {
				$releaseId  = $cached->{release}->{id};
				$albumTitle ||= $cached->{release}->{title};
			}
		}
	}

	my @items;

	# If playing a Zvuk track, offer Radio actions
	if ($trackId) {
		my $radioTrackUrl  = 'zvuk://radio:track:' . $trackId;
		my $radioArtistUrl = $artistId ? ('zvuk://radio:artist:' . $artistId) : undef;
		my $radioAlbumUrl  = $releaseId ? ('zvuk://radio:release:' . $releaseId) : undef;

		# 1. Track Radio
		push @items, {
			name      => cstring($client, 'PLUGIN_ZVUK_TRACK_RADIO'),
			type      => 'audio',
			url       => $radioTrackUrl,
			play      => $radioTrackUrl,
			on_select => 'play',
			image     => 'html/images/radio.png',
		};

		# 2. Artist Radio (if artist is known)
		if ($radioArtistUrl) {
			my $name = cstring($client, 'PLUGIN_ZVUK_ARTIST_RADIO');
			$name .= " ($artistTitle)" if $artistTitle;
			push @items, {
				name      => $name,
				type      => 'audio',
				url       => $radioArtistUrl,
				play      => $radioArtistUrl,
				on_select => 'play',
				image     => 'html/images/radio.png',
			};
		}

		# 3. Album Radio (if album is known)
		if ($radioAlbumUrl) {
			my $name = cstring($client, 'PLUGIN_ZVUK_ALBUM_RADIO');
			$name .= " ($albumTitle)" if $albumTitle;
			push @items, {
				name      => $name,
				type      => 'audio',
				url       => $radioAlbumUrl,
				play      => $radioAlbumUrl,
				on_select => 'play',
				image     => 'html/images/radio.png',
			};
		}
	}

	# Search on Zvuk (for any track)
	my @search_items;

	if ($artistTitle) {
		push @search_items, {
			name        => cstring($client, 'SEARCH') . ' ' .
			               cstring($client, 'ARTISTS') . " '$artistTitle'",
			type        => 'link',
			url         => \&Plugins::Zvuk::Plugin::searchArtists,
			image       => 'html/images/artists.png',
			passthrough => [{ search => $artistTitle }],
		};
	}

	if ($albumTitle) {
		push @search_items, {
			name        => cstring($client, 'SEARCH') . ' ' .
			               cstring($client, 'ALBUMS') . " '$albumTitle'",
			type        => 'link',
			url         => \&Plugins::Zvuk::Plugin::searchAlbums,
			image       => 'html/images/albums.png',
			passthrough => [{ search => $albumTitle }],
		};
	}

	if ($trackTitle) {
		push @search_items, {
			name        => cstring($client, 'SEARCH') . ' ' .
			               cstring($client, 'SONGS') . " '$trackTitle'",
			type        => 'link',
			url         => \&Plugins::Zvuk::Plugin::searchTracks,
			image       => 'html/images/musicfolder.png',
			passthrough => [{ search => $trackTitle }],
		};
	}

	if (@search_items) {
		push @items, {
			type  => 'outline',
			name  => cstring($client, 'SEARCH'),
			items => \@search_items,
		};
	}

	return unless @items;
	return {
		name  => cstring($client, 'PLUGIN_ZVUK_ON_ZVUK'),
		items => \@items,
	};
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta) = @_;

	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);
	return unless $api;

	my $artistUrl = $url || ($artist && blessed($artist) && $artist->can('url') ? $artist->url : '') || ($remoteMeta ? ($remoteMeta->{url} || '') : '') || '';
	my $artistId;
	if ($artistUrl =~ m{zvuk://(?:artist[:/])?(\d+)}) {
		$artistId = $1;
	}

	my $artistTitle = ($remoteMeta && $remoteMeta->{artist}) || ($artist && blessed($artist) && $artist->can('name') ? $artist->name : '');

	my @items;
	if ($artistId) {
		my $radioUrl = 'zvuk://radio:artist:' . $artistId;
		push @items, {
			name      => cstring($client, 'PLUGIN_ZVUK_ARTIST_RADIO'),
			type      => 'audio',
			url       => $radioUrl,
			play      => $radioUrl,
			on_select => 'play',
			image     => 'html/images/radio.png',
		};
	} elsif ($artistTitle) {
		push @items, {
			name        => cstring($client, 'SEARCH') . ' ' . cstring($client, 'ARTISTS') . " '$artistTitle'",
			type        => 'link',
			url         => \&Plugins::Zvuk::Plugin::searchArtists,
			image       => 'html/images/artists.png',
			passthrough => [{ search => $artistTitle }],
		};
	}

	return unless @items;
	return {
		name  => cstring($client, 'PLUGIN_ZVUK_ON_ZVUK'),
		items => \@items,
	};
}


sub _doLikeRelease {
	my ($client, $cb, $args, $api, $releaseId) = @_;
	$api->likeRelease(sub {
		my $res = shift;
		my $msg = ($res && !$res->{error}) ? cstring($client, 'PLUGIN_ZVUK_DONE') : ("Error: " . ($res->{error} || 'failed'));
		$cb->({ items => [{ name => $msg, type => 'text' }] });
	}, $releaseId);
}

sub _doUnlikeRelease {
	my ($client, $cb, $args, $api, $releaseId) = @_;
	$api->unlikeRelease(sub {
		my $res = shift;
		my $msg = ($res && !$res->{error}) ? cstring($client, 'PLUGIN_ZVUK_DONE') : ("Error: " . ($res->{error} || 'failed'));
		$cb->({ items => [{ name => $msg, type => 'text' }] });
	}, $releaseId);
}

1;
