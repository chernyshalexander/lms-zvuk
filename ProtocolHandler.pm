package Plugins::Zvuk::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Networking::Async::HTTP;
use Time::HiRes qw(time);

use Plugins::Zvuk::API;
use Plugins::Zvuk::API::Async;

my $log   = logger('plugin.zvuk');
my $cache = Slim::Utils::Cache->new();
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

		if (!$data || $data->{error}) {
			$log->error("getStream error for track $id: " . ($data->{error} || 'no response'));
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		my $streamUrl = $data->{stream};
		my $quality   = $data->{quality} || $prefQuality;
		
		if (!$streamUrl) {
			$errorCb->(string('PLUGIN_ZVUK_ERROR_STREAM'));
			return;
		}

		my $format = ($quality eq 'flac') ? 'flc' : 'mp3';
		
		$log->info("Resolved Zvuk stream ($quality) for track $id: $streamUrl");

		$song->streamUrl($streamUrl);
		$song->pluginData(format => $format);
		$song->pluginData(quality => $quality);

		# Optimization: Start playback immediately for MP3, only parse for FLAC
		if ($format eq 'flc') {
			require Slim::Utils::Scanner::Remote;
			my $http = Slim::Networking::Async::HTTP->new;
			$http->send_request({
				request     => HTTP::Request->new(GET => $streamUrl),
				onStream    => \&Slim::Utils::Scanner::Remote::parseFlacHeader,
				onError     => sub {
					$class->_finalizeMetadata($song, $format, $quality, $successCb);
				},
				passthrough => [ $song->track, { cb => sub { $class->_finalizeMetadata($song, $format, $quality, $successCb) } }, $streamUrl ],
			});
		} else {
			$class->_finalizeMetadata($song, $format, $quality, $successCb);
		}

	}, $id, $prefQuality);
}

sub _finalizeMetadata {
	my ($class, $song, $format, $prefQuality, $successCb) = @_;

	if ($song->track) {
		my $track_url = $song->track->url;
		my $duration = $song->duration;

		# Recovery duration if missing
		if (!$duration) {
			my ($id) = $track_url =~ m{zvuk://(\d+)};
			my $meta = $cache->get("zvuk_meta_$id");
			if ($meta && $meta->{duration}) {
				$duration = $meta->{duration};
				$song->duration($duration);
			}
		}

		# Set type in DB before notifying LMS
		eval {
			require Slim::Schema;
			Slim::Schema->updateOrCreate({
				url        => $track_url,
				attributes => { 
					CONTENT_TYPE => $format,
				},
			});
			Slim::Schema->clearContentTypeCache($track_url);
		};

		# Set bitrate estimate
		my $bitrate = $song->track->bitrate;
		if (!$bitrate || $bitrate < 1000) {
			$bitrate = ($format eq 'flc') ? 900_000 : ($prefQuality eq 'mid' ? 128_000 : 320_000);
			Slim::Music::Info::setBitrate($song->track, $bitrate);
		}

		if ($duration) {
			Slim::Music::Info::setDuration($song->track, $duration);
		}

		if ($format eq 'mp3') {
			$song->track->samplerate(44100) unless $song->track->samplerate;
			$song->track->samplesize(16) unless $song->track->samplesize;
		}
	}

	$successCb->();
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
	my ($class, $song, $url) = @_;
	return $url =~ m{^https?://} ? 1 : 0;
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

sub getHeaders {
	my ($class, $song) = @_;
	my $headers = $class->SUPER::getHeaders($song) || {};
	$headers->{'User-Agent'} = Plugins::Zvuk::API::USER_AGENT;
	return $headers;
}

sub getFormatForURL {
	my ($class, $url) = @_;
	return if $url =~ m{zvuk://\w+:};
	my $prefQuality = Plugins::Zvuk::API::getQuality();
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
