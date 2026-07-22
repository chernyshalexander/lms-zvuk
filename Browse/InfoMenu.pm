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
			name  => cstring($client, 'ADD_TO_END'),
			type  => 'link',
			url   => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['playlistcontrol', 'cmd:add', "url:$targetUrl"]);
				$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_DONE'), type => 'text' }] });
			},
		},
		{
			name  => cstring($client, 'PLAY_NEXT'),
			type  => 'link',
			url   => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['playlistcontrol', 'cmd:insert', "url:$targetUrl"]);
				$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_DONE'), type => 'text' }] });
			},
		},
		{
			name  => cstring($client, 'PLAY'),
			type  => 'link',
			url   => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['playlistcontrol', 'cmd:load', "url:$targetUrl"]);
				$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_DONE'), type => 'text' }] });
			},
		},
		{
			name  => cstring($client, $favToken),
			type  => 'link',
			url   => sub {
				my ($client, $cb) = @_;
				Slim::Control::Request::executeRequest($client, ['jivefavorites', $favCmd, "url:$targetUrl", "title:$favTitle", 'type:playlist']);
				$cb->({ items => [{ name => cstring($client, 'PLUGIN_ZVUK_DONE'), type => 'text' }] });
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
