package Plugins::Zvuk::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Networking::Async::HTTP;
use Time::HiRes qw(time);

use Plugins::Zvuk::API;
use Plugins::Zvuk::API::Async;

use constant CAN_FLAC_SEEK => UNIVERSAL::can('Slim::Utils::Scanner::Remote', 'parseFlacHeader');

my $log   = logger('plugin.zvuk');
my @pendingMeta;

sub new {
	my ($class, $args) = @_;

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	$log->info("Remote streaming Zvuk track: $streamUrl");

	return $class->SUPER::new({
		url    => $streamUrl,
		song   => $args->{song},
		client => $args->{client},
	});
}

sub register {
	my $class = shift;
	Slim::Player::ProtocolHandlers->registerHandler('zvuk', $class);
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->track()->url;
	my ($id) = $url =~ m{zvuk://(\d+)};

	if (!$id) {
		$errorCb->('Invalid Zvuk ID');
		return;
	}

	my $client = $song->master();
	$log->info("Resolving Zvuk stream for track ID: $id");

	my $prefQuality = Plugins::Zvuk::API->getQuality();
	
	_getAPIHandler($client)->getStream(sub {
		my $data = shift;

		if (!$data || !ref $data || !@$data) {
			$log->error("getStream error for track $id: no response or empty");
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		my $content = $data->[0];
		my $stream  = $content->{stream};
		my $duration = $content->{duration};

		if ($duration) {
			$song->duration($duration);
			Slim::Music::Info::setDuration($song->track, $duration);
		}

		my $streamUrl;
		my $format = 'mp3';

		if ($prefQuality eq 'flac') {
			# Check both flac and flacdrm
			if ($stream->{flac}) {
				$streamUrl = $stream->{flac};
				$format = 'flc';
			} elsif ($stream->{flacdrm}) {
				$streamUrl = $stream->{flacdrm};
				$format = 'flc';
			} else {
				$streamUrl = $stream->{high} || $stream->{mid};
			}
		} elsif ($prefQuality eq 'high') {
			$streamUrl = $stream->{high} || $stream->{mid};
		} else {
			$streamUrl = $stream->{mid} || $stream->{high};
		}

		if (!$streamUrl) {
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		# 2. Set bitrate estimate
		my $bitrate = ($format eq 'flc') ? 900_000 : ($prefQuality eq 'mid' ? 128_000 : 320_000);
		Slim::Music::Info::setBitrate($song->track, $bitrate);

		$log->info("Resolved Zvuk stream ($format) for track $id: $streamUrl");

		$song->streamUrl($streamUrl);
		$song->pluginData(format => $format);
		$song->track->content_type($format);

		# Update cache with format type for immediate metadata display
		my $cached_meta = Plugins::Zvuk::API->cache->get("zvuk_meta_$id") || {};
		$cached_meta->{type} = $format;
		Plugins::Zvuk::API->cache->set("zvuk_meta_$id", $cached_meta, Plugins::Zvuk::API::DEFAULT_TTL);

		# Parse remote header to get accurate duration/bitrate before playback starts
		# This ensures progress bar and time display are available immediately in SqueezePlay
		require Slim::Utils::Scanner::Remote;

		my $parseCallback = sub {
			$client->currentPlaylistUpdateTime(Time::HiRes::time());
			# Ensure parseRemoteHeader didn't override the format (especially for FLAC)
			$song->track->content_type($format);
			Slim::Control::Request::notifyFromArray($client, ['newmetadata']);

			$successCb->();
		};

		my $errorCallback = sub {
			my ($error) = @_;
			$log->warn("Could not parse $format header for track $id: $error");
			$successCb->();
		};

		Slim::Utils::Scanner::Remote::parseRemoteHeader(
			$song->track, $streamUrl, $format,
			$parseCallback, $errorCallback
		);

	}, [$id]);
}


sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my ($id) = $url =~ m{zvuk://(\d+)};
	return {} unless $id;

	my $meta = Plugins::Zvuk::API->cache->get("zvuk_meta_$id");
	if ($meta) {
		$meta->{type} //= Plugins::Zvuk::API->getQuality() eq 'flac' ? 'flc' : 'mp3';
		return $meta;
	}

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

	# Return format type based on quality preference
	# getMetadataFor is called for all tracks in playlist, not just current,
	# so we use the user's quality preference to determine the format
	my $quality = Plugins::Zvuk::API->getQuality();
	my $type = $quality eq 'flac' ? 'flc' : 'mp3';

	return { type => $type, icon => $icon };
}

sub canDirectStream { 0 }

sub canSeek {
	return 1;
}

sub audioScrobblerSource {
	return 'P';
}

sub formatOverride {
	my ($class, $song) = @_;
	return $song->pluginData('format')
		|| (Plugins::Zvuk::API->getQuality() eq 'flac' ? 'flc' : 'mp3');
}

sub getHeaders {
	my ($class, $song) = @_;
	my $headers = $class->SUPER::getHeaders($song) || {};
	$headers->{'User-Agent'} = Plugins::Zvuk::API::USER_AGENT;
	return $headers;
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
		artist   => 'Plugins::Zvuk::Plugin::handleArtistTracks',
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

sub getIcon {
	my ( $class, $url ) = @_;
	return Plugins::Zvuk::Plugin->_pluginDataFor('icon');
}

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
