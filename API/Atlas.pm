package Plugins::Zvuk::API::Atlas;

use strict;
use warnings;
use utf8;

use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8 is_utf8);
use JSON::XS;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Zvuk::API;
use Plugins::Zvuk::Throttle;
use Plugins::Zvuk::Retry;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

my $throttler = Plugins::Zvuk::Throttle->new(5, 1.0);  # 5 req/sec
my $retry_mgr = Plugins::Zvuk::Retry->new(5, 0.5);     # 5 attempts, 0.5s backoff

my %atlasClients;

sub new {
	my ($class, $args) = @_;
	$args ||= {};

	my $userId = $args->{userId} || Plugins::Zvuk::API->getSomeUserId();

	if ($userId && $atlasClients{$userId}) {
		return $atlasClients{$userId};
	}

	my $self = bless {
		userId => $userId,
	}, $class;

	if ($userId) {
		$atlasClients{$userId} = $self;
	}

	return $self;
}

sub clearClient {
	my ($class, $userId) = @_;
	if (@_ == 1 && ref($class)) {
		$userId = $class->{userId};
	}
	if (defined $userId) {
		delete $atlasClients{$userId};
	} else {
		%atlasClients = ();
	}
}

sub _resetThrottlerForTesting {
	$throttler->{_task_logs} = [];
}

sub _getToken {
	my ($self) = @_;
	my $userId = $self->{userId} || Plugins::Zvuk::API->getSomeUserId();
	return unless defined $userId && length($userId);
	return Plugins::Zvuk::API->getToken($userId);
}

sub _request {
	my ($self, $method, $path, $params, $body, $cb, $opts) = @_;
	$opts ||= {};
	$method = uc($method || 'GET');

	my $url = Plugins::Zvuk::API::ATLAS_BASE_URL . $path;

	# Build URL with deterministic query parameters
	if ($params && ref $params eq 'HASH' && %$params) {
		my @param_pairs;
		foreach my $key (sort keys %$params) {
			my $value = $params->{$key};
			push @param_pairs, "$key=" . ($value // '');
		}
		$url .= ($url =~ /\?/ ? '&' : '?') . join('&', @param_pairs);
	}

	my $ttl = $opts->{ttl} // 0;
	my $cacheKey = $opts->{cache_key};
	if ($ttl > 0 && !$cacheKey) {
		my $uid = $self->{userId} || 'default';
		$cacheKey = "zvuk_atlas:" . $uid . ":" . md5_hex($url);
	}

	if ($cacheKey && $ttl > 0) {
		if (my $cached = Plugins::Zvuk::API->cache->get($cacheKey)) {
			$log->debug("Cache hit for Atlas $method: $url");
			$cb->($cached, undef);
			return;
		}
	}

	my $token = $self->_getToken();
	if (!$token) {
		$log->error("Atlas $method $url: No auth token available for user: " . ($self->{userId} || 'unknown'));
		$cb->(undef, 'Unauthorized: no token');
		return;
	}

	$log->debug("Atlas $method request: $url");

	$throttler->acquire(sub {
		my $throttle_delay = shift;
		if ($throttle_delay && $throttle_delay > 0.1) {
			$log->debug(sprintf("Atlas %s: throttled for %.3fs: %s", $method, $throttle_delay, $url));
		}

		$retry_mgr->execute(
			sub {
				my $result = shift;

				if (!$result->{error}) {
					if ($cacheKey && $ttl > 0 && $result->{data}) {
						Plugins::Zvuk::API->cache->set($cacheKey, $result->{data}, $ttl);
						$log->debug("Atlas: Cached $url in $cacheKey for ${ttl}s");
					}
					$cb->($result->{data}, undef);
					return;
				}

				# Automatic token refresh on HTTP 401
				if (($result->{code} && $result->{code} == 401) && !$opts->{refreshed}) {
					$log->warn("Atlas $method: Received HTTP 401 for $url, attempting token refresh");
					require Plugins::Zvuk::API::Async;
					my $async = Plugins::Zvuk::API::Async->new({ userId => $self->{userId} });
					if ($async && $async->can('refreshToken')) {
						$async->refreshToken(sub {
							my ($newToken, $refreshErr) = @_;
							if ($newToken) {
								$log->info("Atlas $method: Token refreshed successfully, retrying $url");
								my $newOpts = { %$opts, refreshed => 1 };
								$self->_request($method, $path, $params, $body, $cb, $newOpts);
							} else {
								$log->error("Atlas $method: Token refresh failed: " . ($refreshErr || 'unknown'));
								$cb->(undef, $result->{error}, $result->{code});
							}
						});
						return;
					}
				}

				$log->error("Atlas $method $url failed after retries: " . ($result->{error} || 'unknown'));
				$cb->(undef, $result->{error}, $result->{code});
			},
			sub {
				my $op_cb = shift;

				my $http = Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $response = shift;
						my $content = $response->content;
						my $code = $response->code;

						if (!$content || length($content) == 0) {
							# Empty response on PUT may be valid if HTTP 200/204
							if ($code =~ /^2/ && $method eq 'PUT') {
								$op_cb->({ data => { success => 1 }, code => $code });
								return;
							}
							$log->error("Atlas: Empty response for $url (HTTP $code)");
							$op_cb->({ error => 'empty_response', code => $code });
							return;
						}

						my $bytes = (defined $content && Encode::is_utf8($content)) ? Encode::encode_utf8($content) : $content;
						my $data = eval { decode_json($bytes) };
						if ($@ || !$data) {
							my $err = $@ ? "JSON parse error: $@" : "No data decoded";
							$log->error("Atlas $method $url: $err");
							$op_cb->({ error => $err, code => 400 });
							return;
						}

						if (ref $data eq 'HASH' && $data->{error}) {
							my $err_code = ($data->{error} =~ /unauthori[zs]ed/i) ? 401 : $code;
							$op_cb->({ error => $data->{error}, code => $err_code });
							return;
						}

						$op_cb->({ data => $data, code => $code });
					},
					sub {
						my ($http, $error, $response) = @_;
						my $code = $response ? $response->code : 0;
						if ($code) {
							$log->error("Atlas: HTTP $code for $url: $error");
						} else {
							$log->error("Atlas: Network error for $url: $error");
						}
						$op_cb->({ error => $error, code => $code });
					},
					{ timeout => $opts->{timeout} || 15 }
				);

				# CRITICAL: Atlas API requires Cookie: auth=<token>; in_webkit=true
				# and REJECTS X-Auth-Token header!
				my $referer = 'https://atlas.zvuk.com/';
				if ($self->{userId}) {
					$referer .= 'map/' . $self->{userId};
				}

				my %headers = (
					'accept'     => 'application/json',
					'user-agent' => Plugins::Zvuk::API::USER_AGENT,
					'referer'    => $referer,
					'cookie'     => "auth=$token; in_webkit=true",
					%{ $opts->{headers} || {} },
				);

				if ($method eq 'PUT' || $method eq 'POST') {
					$headers{'content-type'} = 'application/json';
					my $content_body = defined $body ? (ref $body ? encode_json($body) : $body) : '{}';

					if ($method eq 'PUT') {
						if ($http->can('put')) {
							$http->put($url, %headers, $content_body);
						} elsif ($http->can('request')) {
							$http->request({ method => 'PUT', url => $url, headers => \%headers, content => $content_body });
						} else {
							$headers{'X-HTTP-Method-Override'} = 'PUT';
							$http->post($url, %headers, $content_body);
						}
					} else {
						$http->post($url, %headers, $content_body);
					}
				} else {
					$http->get($url, %headers);
				}
			}
		);
	});
}

# GET /api/v1/map — Full taste map of the user (79 islands)
sub getMap {
	my ($self, $cb, $opts) = @_;
	$opts ||= {};

	my $uid = $self->{userId} || 'default';
	my $cache_key = "zvuk_atlas_map_$uid";

	my %request_opts = (
		ttl       => Plugins::Zvuk::API::ATLAS_MAP_TTL,
		cache_key => $cache_key,
		%$opts,
	);

	$self->_request('GET', '/api/v1/map', undef, undef, $cb, \%request_opts);
}

# GET /api/v1/map/islands/{island_id} — Detailed tracks for an island (up to 50)
sub getIslandTracks {
	my ($self, $cb, $islandId, $opts) = @_;
	$opts ||= {};

	return $cb->(undef, 'Missing islandId') unless defined $islandId && length($islandId);

	my $cache_key = "zvuk_atlas_island_$islandId";
	my %request_opts = (
		ttl       => Plugins::Zvuk::API::ATLAS_ISLAND_TTL,
		cache_key => $cache_key,
		%$opts,
	);

	$self->_request('GET', "/api/v1/map/islands/$islandId", undef, undef, $cb, \%request_opts);
}

# PUT /api/v1/map/islands/{island_id}/wave — Register wave start on server
sub startIslandWave {
	my ($self, $cb, $islandId, $opts) = @_;
	$opts ||= {};

	return $cb->(undef, 'Missing islandId') unless defined $islandId && length($islandId);

	my %request_opts = (
		ttl => 0,
		%$opts,
	);

	$self->_request('PUT', "/api/v1/map/islands/$islandId/wave", undef, {}, $cb, \%request_opts);
}

# GET /api/v1/map/islands/{island_id}/wave?limit=20[&cursor=...] — Island wave stream tracks
sub getIslandWave {
	my ($self, $cb, $islandId, $limit, $cursor, $opts) = @_;
	$opts ||= {};

	return $cb->(undef, 'Missing islandId') unless defined $islandId && length($islandId);

	my %params = (
		limit => $limit || 20,
	);
	$params{cursor} = $cursor if defined $cursor && length($cursor);

	my %request_opts = (
		ttl => 0,
		%$opts,
	);

	$self->_request('GET', "/api/v1/map/islands/$islandId/wave", \%params, undef, $cb, \%request_opts);
}

1;
