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

	my $remoteMeta = {
		album  => $album,
		artist => $artist,
		url    => $url,
	};

	my $feed;
	if ($type eq 'album' || $url =~ m{zvuk://(?:album[:/])?(\d+)}) {
		$feed = albumInfoMenu($client, $url, undef, $remoteMeta);
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

	my $albumName = ($remoteMeta && $remoteMeta->{album}) || ($album && blessed($album) && $album->can('title') ? $album->title : (blessed($album) && $album->can('name') ? $album->name : undef)) || (ref $album ? '' : $album);

	if ($albumId) {
		my @items = (
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
		);
		if ($albumName && !ref $albumName) {
			push @items, {
				name        => cstring($client, 'SEARCH') . ' ' . cstring($client, 'ALBUMS') . " '$albumName'",
				type        => 'link',
				url         => \&_handleSearchAlbum,
				image       => 'plugins/zvuk/html/images/albums.png',
				passthrough => [$albumName],
			};
		}
		return {
			name  => cstring($client, 'PLUGIN_ZVUK_ON_ZVUK'),
			items => \@items,
		};
	}

	if ($albumName && !ref $albumName) {
		return {
			type        => 'link',
			name        => cstring($client, 'PLUGIN_ZVUK_ON_ZVUK'),
			url         => \&_handleSearchAlbum,
			passthrough => [$albumName],
		};
	}

	return;
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

sub _handleSearchAlbum {
	my ($client, $cb, $args, $albumQuery) = @_;
	my $api = Plugins::Zvuk::Plugin::_get_api_client($client);
	return unless $api;

	$api->search(sub {
		my $data = shift;
		my $releases = $data->{search}{releases}{items} || [];
		my @items;
		foreach my $rel (@$releases) {
			push @items, Plugins::Zvuk::Plugin::_renderRelease($rel);
		}
		$cb->({ items => @items ? \@items : [{ name => cstring($client, 'EMPTY'), type => 'text' }] });
	}, { query => $albumQuery, limit => 20, tracks => 0, releases => 1, playlists => 0, artists => 0 });
}

1;
