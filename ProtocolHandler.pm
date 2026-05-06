package Plugins::Zvuk::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Time::HiRes qw(time);

use Plugins::Zvuk::API;
use Plugins::Zvuk::API::Async;

my $log   = logger('plugin.zvuk');
my $cache = Slim::Utils::Cache->new();
my @pendingMeta;

sub register {
	my $class = shift;
	Slim::Player::ProtocolHandlers->registerHandler('zvuk', $class);
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->track()->url;
	my ($id) = $url =~ m{zvuk://(\d+)};

	if (!$id) {
		$log->error("Invalid Zvuk URL: $url");
		$errorCb->('Invalid Zvuk ID');
		return;
	}

	my $client = $song->master();
	$log->info("Resolving Zvuk stream for track ID: $id, player: " . ($client ? $client->id : 'unknown'));

	_getAPIHandler($client)->getStream(sub {
		my $data = shift;

		$log->debug("getStream response for track $id: " . (ref $data ? "Got response" : "Error: $data"));

		if (!$data) {
			$log->error("getStream: No response for track $id");
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		if ($data->{error}) {
			$log->error("getStream API error for track $id: $data->{error}");
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		if (!$data->{mediaContents} || !@{$data->{mediaContents}}) {
			$log->error("getStream: No mediaContents for track $id");
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		my $content = $data->{mediaContents}->[0];
		my $stream  = $content->{stream};

		my $prefQuality = Plugins::Zvuk::API->getQuality();
		my $streamUrl;
		my $format = 'mp3';

		if ($prefQuality eq 'flac') {
			if ($stream->{flac}) {
				$streamUrl = $stream->{flac};
				$format = 'flc';
			} elsif ($stream->{flacdrm}) {
				$log->warn("Only DRM FLAC available for track $id, falling back to MP3 320k");
				$streamUrl = $stream->{high} || $stream->{mid};
			} else {
				$streamUrl = $stream->{high} || $stream->{mid};
			}
		} elsif ($prefQuality eq 'high') {
			$streamUrl = $stream->{high} || $stream->{mid};
		} else {
			$streamUrl = $stream->{mid} || $stream->{high};
		}

		if (!$streamUrl) {
			$log->warn("No playable stream URL found for track $id");
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		$log->debug("Resolved stream for track $id (quality: $prefQuality, format: $format)");

		$song->streamUrl($streamUrl);
		$song->pluginData(format => $format);

		$successCb->();

	}, [$id]);
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my ($id) = $url =~ m{zvuk://(\d+)};
	return {} unless $id;

	my $meta = $cache->get("zvuk_meta_$id");
	return $meta if $meta;

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

	return { type => 'mp3', icon => $icon };
}

sub canDirectStream {
	return 0;
}

sub canSeek {
	return 1;
}

sub audioScrobblerSource {
	return 'P';
}

sub formatOverride {
	my ($class, $song) = @_;
	return $song->pluginData('format') || 'mp3';
}

sub getFormatForURL {
	my ($class, $url) = @_;
	return if $url =~ m{zvuk://\w+:};
	my $prefQuality = Plugins::Zvuk::API->getQuality();
	return $prefQuality eq 'flac' ? 'flc' : 'mp3';
}

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack());
}

sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	my ($type, $id) = $url =~ m{zvuk://(\w+):(\d+)};
	return $cb->([$url]) unless $type && $id;

	my %dispatch = (
		album    => 'Plugins::Zvuk::Plugin::handleAlbum',
		playlist => 'Plugins::Zvuk::Plugin::handlePlaylist',
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

sub isRemote { 1 }

sub _getAPIHandler {
	my ($client) = @_;

	if (ref $client) {
		return $client->pluginData('zvuk_api') || _initAPIHandler($client);
	} else {
		my $userId = Plugins::Zvuk::API->getSomeUserId();
		return Plugins::Zvuk::API::Async->new({ userId => $userId });
	}
}

sub _initAPIHandler {
	my ($client) = @_;
	my $prefs = preferences('plugin.zvuk');
	my $userId = $prefs->client($client)->get('userId') || Plugins::Zvuk::API->getSomeUserId();

	my $api;
	if ($userId) {
		$prefs->client($client)->set('userId', $userId);
		$api = Plugins::Zvuk::API::Async->new({ userId => $userId });
		$client->pluginData(zvuk_api => $api);
	}
	return $api;
}

1;
