package Plugins::Zvuk::API::Async;

use strict;
use warnings;
use utf8;

use Digest::MD5 qw(md5_hex);
use JSON::XS;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Zvuk::API;
use Plugins::Zvuk::WaveSettings;
use Plugins::Zvuk::Throttle;
use Plugins::Zvuk::Retry;

# CRITICAL: We use a centralized cache from Plugins::Zvuk::API.
# This avoids data isolation and ensures metadata is consistent across the plugin.
# Centralized cache is used from Plugins::Zvuk::API
my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

# Initialize throttler and retry manager at module level
my $throttler = Plugins::Zvuk::Throttle->new(5, 1.0);  # 5 req/sec
my $retry_mgr = Plugins::Zvuk::Retry->new(5, 0.5);     # 5 attempts, 0.5s backoff

my %apiClients;

sub new {
	my ($class, $args) = @_;

	my $userId = $args->{userId} || Plugins::Zvuk::API->getSomeUserId() || return;

	if (my $apiClient = $apiClients{$userId}) {
		return $apiClient;
	}

	my $self = $apiClients{$userId} = bless {
		userId => $userId,
	}, $class;

	return $self;
}

sub accountId {
	my $self = shift;
	return $self->{userId} // 'default';
}

=head2 _graphql($cb, $operationName, $query, $variables, $opts)

Execute a GraphQL query with rate limiting (5 req/sec) and automatic retry (5 attempts).

This is the core request handler for all API operations. It implements:

1. CACHING: Checks cache before making request (bypasses throttle/retry if hit)
2. THROTTLING: Enforces 5 requests per second via token bucket algorithm
3. RETRY LOGIC: Automatic retry on transient errors with exponential backoff
4. CACHE WRITING: Writes successful results to cache (if cacheable)

THROTTLING:
  - Enforces maximum 5 requests per second
  - Queues excess requests for execution when slots become available
  - Delays logged at DEBUG level if > 0.1s
  - Uses token bucket algorithm (fair, prevents bursts)

RETRY LOGIC:
  - Up to 5 attempts per request
  - Exponential backoff: 0.5s, 1s, 2s, 4s, 8s (with ±25% jitter)
  - Retries on transient errors:
    * HTTP 429 (rate limit)
    * HTTP 502, 503, 504 (server errors)
    * Timeout (HTTP 0 or "timeout" string)
    * Network errors (connection refused, reset, etc.)
  - Does NOT retry on permanent errors:
    * HTTP 400, 401, 404, 409 (client errors)
    * GraphQL validation errors

CACHING:
  - Cache hits bypass throttle/retry entirely (instant response)
  - Cache key: user ID + operation name + MD5(variables)
  - Cache written after all retries complete
  - TTL varies by operation type (see _getCacheTTL)

Parameters:
  - $cb: Callback to invoke with result (receives data hash or error hash)
  - $operationName: Name of GraphQL operation (for logging, cache key, TTL)
  - $query: GraphQL query string
  - $variables: Hash ref of GraphQL variables
  - $opts: Optional hash ref with:
    * ttl: Override cache TTL for this operation (0 = no cache)

Returns:
  Via callback $cb->({...}):
  - On success: $cb->($data)  # data hash from GraphQL response
  - On error: $cb->({error => 'msg', code => HTTP_CODE, details => '...'})

=cut

sub _graphql {
	my ($self, $cb, $operationName, $query, $variables, $opts) = @_;
	$opts ||= {};

	my $userId = $self->{userId};
	my $ttl    = $opts->{ttl} // _getCacheTTL($operationName);

	# Create a unique cache key based on user, operation and variables
	my $cacheKey;
	if ($ttl > 0) {
		my $vars_json = $variables ? encode_json($variables) : '{}';
		$cacheKey = "zvuk_gql:${userId}:${operationName}:" . md5_hex($vars_json);

		# CACHE HIT: Bypass throttle/retry entirely for instant response
		if (my $cached = Plugins::Zvuk::API->cache->get($cacheKey)) {
			$log->debug("Cache hit for $operationName ($userId)");
			$cb->($cached);
			return;
		}
	}

	my $token = Plugins::Zvuk::API->getToken($userId);
	if (!$token) {
		$log->error("No token available for GraphQL request: $operationName");
		$cb->({ error => 'No token' });
		return;
	}

	my $deviceId = $prefs->get('device_id');
	if (!$deviceId) {
		$deviceId = sprintf("%04x%04x-%04x-%04x-%04x-%04x%04x%04x",
			rand(0xffff), rand(0xffff), rand(0xffff), rand(0x0fff) | 0x4000,
			rand(0x3fff) | 0x8000, rand(0xffff), rand(0xffff), rand(0xffff)
		);
		$prefs->set('device_id', $deviceId);
	}

	my $body = {
		operationName => $operationName,
		query         => $query,
		variables     => $variables || {},
	};

	$log->info("GraphQL Request: $operationName (userId: $userId, cache: " . ($cacheKey ? "TTL=$ttl" : 'off') . ")");

	# THROTTLE: Acquire a rate limit slot (max 5 requests per second)
	# If all slots are full, the request is queued and executed when a slot becomes available.
	# This prevents overwhelming the API and respects rate limits automatically.
	$throttler->acquire(sub {
		my $throttle_delay = shift;

		# Log significant throttle delays (> 0.1s) for monitoring
		# High frequency of these indicates hitting the 5 req/sec limit
		if ($throttle_delay > 0.1) {
			$log->debug(sprintf("GraphQL: throttled for %.3fs", $throttle_delay));
		}

		# RETRY: Execute operation with automatic retry on transient errors
		# Up to 5 attempts with exponential backoff (0.5s, 1s, 2s, 4s, 8s + jitter)
		# Retries on: 429, 502, 503, 504, timeout, network errors
		# Does NOT retry: 400, 401, 404, 409, GraphQL validation errors
		$retry_mgr->execute(
			# CALLBACK 1: on_success - invoked when request succeeds OR all retries exhausted
			sub {
				my $result = shift;

				# Success case: no error occurred
				if (!$result->{error}) {
					# CACHE: Write result to cache (if cacheable and TTL > 0)
					# Future requests for same operation+variables will hit cache instantly
					if ($cacheKey && $result->{data}) {
						Plugins::Zvuk::API->cache->set($cacheKey, $result->{data}, $ttl);
						$log->debug("GraphQL: Cached $operationName for ${ttl}s");
					}
					$cb->($result->{data} // $result);
					return;
				}

				# Error case: all retries exhausted OR permanent error detected
				# Log error for debugging and pass to original callback
				if ($result->{error}) {
					if ($result->{details}) {
						$log->error("GraphQL error ($operationName): $result->{error} - $result->{details}");
					} else {
						$log->error("GraphQL error ($operationName): $result->{error}");
					}
				}
				$cb->($result);
			},

			# CALLBACK 2: operation - executes the actual HTTP request
			# Called once initially, then again by retry manager if transient error detected
			sub {
				my $op_cb = shift;

				my $http = Slim::Networking::SimpleAsyncHTTP->new(
					# HTTP SUCCESS HANDLER: Response received (any HTTP code)
					sub {
						my $response = shift;
						my $content = $response->content;
						my $code = $response->code;

						# Validate response
						if (!$content || length($content) == 0) {
							$log->error("GraphQL: Empty response for $operationName (HTTP $code)");
							$op_cb->({ error => 'empty_response', code => $code });
							return;
						}

						# Parse JSON response
						my $result = eval { decode_json($content) };
						if ($@ || !$result) {
							$log->error("GraphQL: JSON parse error for $operationName: $@");
							$op_cb->({ error => 'parse_error', code => $code });
							return;
						}

						# Check for GraphQL errors (even on HTTP 200)
						if ($result->{errors}) {
							my $errors = $result->{errors};
							my @error_msgs;
							foreach my $err (@$errors) {
								if (ref $err eq 'HASH') {
									push @error_msgs, $err->{message} || 'Unknown error';
								} else {
									push @error_msgs, $err;
								}
							}
							my $msg = join('; ', @error_msgs);
							$log->error("GraphQL API error ($operationName, HTTP $code): $msg");
							# GraphQL validation errors are NOT retryable, return immediately
							$op_cb->({ error => $msg, code => $code });
							return;
						}

						# Extract and validate data field
						my $data = $result->{data};
						if (!$data) {
							$log->warn("GraphQL: No data in response for $operationName (HTTP $code)");
							$op_cb->({ error => 'no_data', code => $code });
							return;
						}

						# SUCCESS: Pass data to retry manager
						# Retry manager will invoke on_success callback with this result
						$op_cb->({ data => $data });
					},

					# HTTP ERROR HANDLER: any non-2xx/3xx HTTP response, or a
					# genuine network-level failure (connect/DNS/timeout).
					#
					# Slim::Networking::Async::HTTP routes ANY response outside
					# [23]\d\d here as soon as headers are read -- BEFORE the
					# body is fetched (Async/HTTP.pm:432-434) -- so for real
					# HTTP error responses (400/401/404/429/5xx) the response
					# body (e.g. a GraphQL error message) is never available,
					# only the status line/code. $response is still passed
					# through and has the real numeric code, though, so use
					# that instead of pattern-matching the error string --
					# the string match previously left HTTP 400 (and 401/403/
					# 404/409) miscategorized as code=>0 ("timeout"), which
					# Retry.pm treats as retryable, wasting several retries
					# with growing backoff on errors that will never succeed.
					sub {
						my ($http, $error, $response) = @_;
						my $code = $response ? $response->code : 0;

						if ($code) {
							$log->error("GraphQL: HTTP $code for $operationName: $error");
						} else {
							# No HTTP response at all -- real network/timeout failure.
							$log->error("GraphQL: Network error for $operationName: $error");
						}

						# Pass error to retry manager with the real HTTP code.
						# Retry manager will check is_retryable() to decide whether to retry.
						$op_cb->({ error => $error, code => $code });
					},

					{ timeout => 15 }  # 15 second HTTP timeout (per request)
				);

				$http->post(
					Plugins::Zvuk::API::GRAPHQL_URL,
					'x-auth-token' => $token,
					'x-app-name'   => Plugins::Zvuk::API::APP_NAME,
					'x-device-id'  => $deviceId,
					'origin'       => 'https://zvuk.com',
					'referer'      => 'https://zvuk.com/',
					'user-agent'   => Plugins::Zvuk::API::USER_AGENT,
					'content-type' => 'application/json',
					'accept'       => 'application/graphql-response+json, application/json',
					encode_json($body)
				);
			}
		);
	});
}

sub _getCacheTTL {
	my ($operationName) = @_;

	return 0 if $operationName =~ m/^(getStream|getPersonalWave)$/;
	return Plugins::Zvuk::API::USER_CONTENT_TTL if $operationName =~ m/^(getPaginatedCollection|getUserPlaylists|userTracks|userCollection|userCollectionReleases|userCollectionArtists|userPaginatedPodcasts|userPaginatedEpisodes)$/;
	return Plugins::Zvuk::API::DYNAMIC_TTL if $operationName =~ m/^(getSearch|quickSearch|search|searchTracks|searchArtists|searchReleases|searchPlaylists|getTracks|getPlaylistTracks|getArtistAlbums|getPodcastEpisodes)$/;
	return Plugins::Zvuk::API::DEFAULT_TTL;
}

	# --- API Methods ---

	# Helper method for HTTP GET requests with JSON parsing and error handling
	sub _http_get {
		my ($self, $url, $params, $cb) = @_;
		
		# Build URL with query parameters
		if ($params && %$params) {
			my @param_pairs;
			foreach my $key (keys %$params) {
				my $value = $params->{$key};
				push @param_pairs, "$key=" . ($value // '');
			}
			$url .= '?' . join('&', @param_pairs);
		}
		
		$log->debug("HTTP GET: $url");
		
		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $response = shift;
				my $content = $response->content;
				my $code = $response->code;
				
				# Parse JSON response
				my $data = eval { decode_json($content) };
				if ($@) {
					my $error = "JSON parse error: $@";
					$log->error("HTTP GET $url: $error");
					$cb->(undef, $error);
					return;
				}
				
				# Success callback with parsed data
				$cb->($data, undef);
			},
			sub {
				my ($http, $error) = @_;
				$log->error("HTTP GET $url failed: $error");
				$cb->(undef, $error);
			}
		);
		
		$http->get(
				$url,
				'x-auth-token' => Plugins::Zvuk::API->getToken($self->accountId),
				'user-agent'   => Plugins::Zvuk::API::USER_AGENT
			);
	}

	# Get user profile to validate token and get real userId
	sub getProfile {
	my ($class, $cb, $token) = @_;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $result = eval { decode_json($response->content) };
			if ($@) {
				$log->error("API::Async::getProfile: JSON parse error: $@");
				$cb->({ error => "JSON parse error: $@" });
			} else {
				$cb->($result->{result});
			}
		},
		sub {
			my ($http, $error) = @_;
			$log->error("API::Async::getProfile: HTTP error: $error");
			$cb->({ error => $error });
		}
	);

	$http->get(
		Plugins::Zvuk::API::PROFILE_URL,
		'x-auth-token' => $token,
		'user-agent'   => Plugins::Zvuk::API::USER_AGENT
	);
}

# Search implementation
sub search {
	my ($self, $cb, $args) = @_;

	my $query = $args->{query};
	my $limit = int($args->{limit} || 20);
	
	my $trackCursor    = $args->{trackCursor};
	my $artistsCursor  = $args->{artistsCursor};
	my $releasesCursor = $args->{releasesCursor};
	my $playlistsCursor = $args->{playlistsCursor};

	my $gql = q{
		query search(
			$query: String
			$limit: Int = 20
			$tracks: Boolean = true
			$trackCursor: Cursor = null
			$artists: Boolean = true
			$artistsCursor: Cursor = null
			$releases: Boolean = true
			$releasesCursor: Cursor = null
			$playlists: Boolean = true
			$playlistsCursor: Cursor = null
		) {
			search(query: $query) {
				tracks(limit: $limit, cursor: $trackCursor) @include(if: $tracks) {
					items {
						id title duration availability artistTemplate
						artists { id title }
						release { id title image { src } }
					}
					page { total next }
				}
				artists(limit: $limit, cursor: $artistsCursor) @include(if: $artists) {
					items { id title image { src } }
					page { total next }
				}
				releases(limit: $limit, cursor: $releasesCursor) @include(if: $releases) {
					items { id title type date artistTemplate image { src } }
					page { total next }
				}
				playlists(limit: $limit, cursor: $playlistsCursor) @include(if: $playlists) {
					items { id title image { src } }
					page { total next }
				}
			}
		}
	};

	# CRITICAL: Zvuk API requires true/false boolean types for these flags.
	# Standard Perl '1' or '0' would be encoded as integers (1/0) in JSON,
	# causing the GraphQL server to return a 400 Bad Request.
	# Using JSON::XS scalar references (\1 and \0) forces correct JSON boolean encoding.
	my $vars = {
		query => $query,
		limit => $limit,
		tracks => defined($args->{tracks}) ? ($args->{tracks} ? \1 : \0) : \1,
		artists => defined($args->{artists}) ? ($args->{artists} ? \1 : \0) : \1,
		releases => defined($args->{releases}) ? ($args->{releases} ? \1 : \0) : \1,
		playlists => defined($args->{playlists}) ? ($args->{playlists} ? \1 : \0) : \1,
	};
	
	$vars->{trackCursor} = $trackCursor if $trackCursor;
	$vars->{artistsCursor} = $artistsCursor if $artistsCursor;
	$vars->{releasesCursor} = $releasesCursor if $releasesCursor;
	$vars->{playlistsCursor} = $playlistsCursor if $playlistsCursor;

	$self->_graphql($cb, 'search', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Get tracks by IDs
sub getTracks {
	my ($self, $cb, $ids) = @_;

	my $gql = q{
		query getTracks($ids: [ID!]!) {
			mediaContents(ids: $ids) {
				... on Track {
					id title duration availability artistTemplate
					release { id title image { src } }
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		$cb->($data->{mediaContents});
	}, 'getTracks', $gql, { ids => $ids });
}

# Get stream URLs using GraphQL (fastest as it includes duration)
sub getStream {
	my ($self, $cb, $ids) = @_;

	my $gql = q{
		query getStream($ids: [ID!]!) {
			mediaContents(ids: $ids) {
				... on Track {
					id
					duration
					stream {
						high
						mid
						flac
						flacdrm
					}
				}
				... on Episode {
					id
					duration
					stream {
						high
						mid
					}
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		$cb->($data->{mediaContents} || []);
	}, 'getStream', $gql, { ids => $ids }, { ttl => 0 });
}

# Get album tracks
sub getAlbumTracks {
	my ($self, $cb, $id) = @_;

	my $gql = q{
		query getAlbumTracks($ids: [ID!]!) {
			getReleases(ids: $ids) {
				id title
				tracks {
					id title duration availability artistTemplate
					artists { id title }
					release { id title image { src } }
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		my $album = $data->{getReleases}->[0];
		$cb->($album ? $album->{tracks} : []);
	}, 'getAlbumTracks', $gql, { ids => [$id] });
}

# Get artist top tracks
sub getArtistTracks {
	my ($self, $cb, $id) = @_;

	my $gql = q{
		query getArtistTracks($ids: [ID!]!, $tracksLimit: Int = 50, $tracksOffset: Int = 0) {
			getArtists(ids: $ids) {
				id title
				popularTracks(offset: $tracksOffset, limit: $tracksLimit) {
					id title duration availability artistTemplate
					artists { id title }
					release { id title image { src } }
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		my $artist = $data->{getArtists}->[0];
		$cb->($artist ? $artist->{popularTracks} : []);
	}, 'getArtistTracks', $gql, { ids => [$id], tracksLimit => 50, tracksOffset => 0 });
}

# Get artist albums
sub getArtistAlbums {
	my ($self, $cb, $id) = @_;

	my $gql = q{
		query getArtistAlbums($ids: [ID!]!, $releasesLimit: Int = 100, $releasesOffset: Int = 0) {
			getArtists(ids: $ids) {
				id title
				releases(offset: $releasesOffset, limit: $releasesLimit) {
					id title type date artistTemplate image { src }
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		my $artist = $data->{getArtists}->[0];
		$cb->($artist ? $artist->{releases} : []);
	}, 'getArtistAlbums', $gql, { ids => [$id], releasesLimit => 100, releasesOffset => 0 });
}

# Get podcast episodes
sub getPodcastEpisodes {
	my ($self, $cb, $id) = @_;

	my $gql = q{
		query getPodcastEpisodes($ids: [ID!]!) {
			getPodcasts(ids: $ids) {
				id title
				episodes { id }
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $podcast  = $data->{getPodcasts}->[0];
		my $ep_stubs = $podcast ? ($podcast->{episodes} || []) : [];
		my @ids = map { $_->{id} } @$ep_stubs;
		return $cb->([]) unless @ids;

		my $gql2 = q{
			query getEpisodes($ids: [ID!]!) {
				getEpisodes(ids: $ids) {
					id title duration
					image { src }
					podcast { id title image { src } }
				}
			}
		};

		$self->_graphql(sub {
			my $d2 = shift;
			$cb->($d2 ? ($d2->{getEpisodes} || []) : []);
		}, 'getEpisodes', $gql2, { ids => \@ids });
	}, 'getPodcastEpisodes', $gql, { ids => [$id] });
}

# Get playlist tracks
sub getPlaylistTracks {
	my ($self, $cb, $id) = @_;

	my $gql = q{
		query getPlaylistTracks($id: ID!, $limit: Int = 500, $offset: Int = 0) {
			playlistTracks(id: $id, limit: $limit, offset: $offset) {
				id title duration availability artistTemplate
				artists { id title }
				release { id title image { src } }
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		$cb->($data->{playlistTracks} || []);
	}, 'getPlaylistTracks', $gql, { id => $id, limit => 500, offset => 0 });
}

# Get personalized wave
sub getPersonalWave {
	my ($self, $cb, $wave_settings) = @_;

	my $gql = q{
		query getPersonalWave($contentInput: PersonalWaveContentInput, $first: PositiveInt! = 2, $options: PersonalWaveOptions, $waveInput: WaveInput, $waveSrc: MagicSource) {
			personalWaveContent(
				contentInput: $contentInput
				first: $first
				options: $options
				waveInput: $waveInput
				waveSrc: $waveSrc
			) {
				...PlayerTrackData
			}
		}

		fragment PlayerTrackData on Track {
			id
			title
			lyrics
			hasFlac
			duration
			explicit
			availability
			artistTemplate
			childParam
			mark
			artists {
				id
				title
				image {
					src
					palette
				}
				mark
			}
			release {
				id
				title
				image {
					src
					palette
				}
			}
			zchan
			__typename
		}
	};

	# Use provided settings or defaults
	$wave_settings ||= Plugins::Zvuk::WaveSettings::loadSettings('default');

	# Ensure all numeric values are proper floats for GraphQL NormalizedFloat type
	my $popular = 0.0 + ($wave_settings->{popular} // 0.5);
	my $energy = 0.0 + ($wave_settings->{energy} // 0.5);
	my $fun = 0.0 + ($wave_settings->{fun} // 0.5);

	my $mood_str = sprintf("energy:%g,fun:%g", $energy, $fun);

	my $vars = {
		waveSrc => "AMAZME",
		first   => 3,
		options => {
			popular  => $popular,
			mood     => $mood_str,
		},
	};

	# Add optional settings if provided
	$vars->{options}->{language} = $wave_settings->{language}
		if defined $wave_settings->{language};

	# Convert vocal to proper float type for NormalizedFloat
	if (defined $wave_settings->{vocal}) {
		$vars->{options}->{vocal} = 0.0 + $wave_settings->{vocal};
	}

	# Add genres if provided
	if ($wave_settings->{genres} && @{$wave_settings->{genres}}) {
		$vars->{options}->{genre} = Plugins::Zvuk::WaveSettings::getGenreNames($wave_settings->{genres});
	}

	$self->_graphql(sub {
		my $data = shift;
		$cb->($data->{personalWaveContent} || []);
	}, 'getPersonalWave', $gql, $vars, { ttl => 0 });
}

# Get user collection (favorite tracks, albums, artists)
sub getCollection {
	my ($self, $cb, $type) = @_;
	$type ||= 'tracks';

	if ($type eq 'tracks') {
		_getCollectionTracks($self, $cb);
	} elsif ($type eq 'releases') {
		_getCollectionReleases($self, $cb);
	} elsif ($type eq 'artists') {
		_getCollectionArtists($self, $cb);
	} elsif ($type eq 'podcasts') {
		_getCollectionPodcasts($self, $cb);
	} elsif ($type eq 'episodes') {
		_getCollectionEpisodes($self, $cb);
	} elsif ($type eq 'synthesis_playlists') {
		_getCollectionSynthesis($self, $cb);
	} else {
		$cb->([]);
	}
}

sub _getCollectionTracks {
	my ($self, $cb) = @_;
	my $gql = q{
		query userTracks {
			collection {
				tracks {
					id
					title
					duration
					availability
					artistTemplate
					explicit
					artists { id title image { src } }
					release { id title image { src } }
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $col = $data->{collection} || {};
		$cb->($col->{tracks} || []);
	}, 'userTracks', $gql, {}, { ttl => Plugins::Zvuk::API::USER_CONTENT_TTL });
}

sub _getCollectionReleases {
	my ($self, $cb) = @_;
	my $gql = q{
		query userCollectionReleases {
			collection {
				releases {
					id
					title
					type
					date
					artistTemplate
					image { src }
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $col = $data->{collection} || {};
		$cb->($col->{releases} || []);
	}, 'userCollectionReleases', $gql, {});
}

sub _getCollectionArtists {
	my ($self, $cb) = @_;
	my $gql = q{
		query userCollectionArtists {
			collection {
				artists {
					id
					title
					image { src }
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $col = $data->{collection} || {};
		$cb->($col->{artists} || []);
	}, 'userCollectionArtists', $gql, {});
}

sub _getCollectionPodcasts {
	my ($self, $cb) = @_;
	my $gql = q{
		query userPaginatedPodcasts {
			paginatedCollection {
				podcasts(pagination: {first: 500}) {
					items {
						id
						title
						description
						image { src }
					}
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $col = $data->{paginatedCollection} || {};
		my $pods = $col->{podcasts} || {};
		$cb->($pods->{items} || []);
	}, 'userPaginatedPodcasts', $gql, {}, { ttl => Plugins::Zvuk::API::USER_CONTENT_TTL });
}

sub _getCollectionEpisodes {
	my ($self, $cb) = @_;
	my $gql = q{
		query userPaginatedEpisodes {
			paginatedCollection {
				episodes(pagination: {first: 500}) {
					items {
						id
						title
						description
						duration
						image { src }
						podcast { id title image { src } }
					}
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $col = $data->{paginatedCollection} || {};
		my $eps = $col->{episodes} || {};
		$cb->($eps->{items} || []);
	}, 'userPaginatedEpisodes', $gql, {}, { ttl => Plugins::Zvuk::API::USER_CONTENT_TTL });
}

sub _getCollectionSynthesis {
	my ($self, $cb) = @_;
	# Synthesis playlists API endpoint not available or not supported
	# Return empty list for now
	$log->debug("Synthesis playlists: returning empty list (not available via API)");
	$cb->([]);
}

# Get user playlists
sub getUserPlaylists {
	my ($self, $cb) = @_;

	my $gql = q{
		query getUserPlaylists {
			collection {
				playlists {
					id
					title
					image { src palette }
					description
					isPublic
				}
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		my $col = $data->{collection} || {};
		$cb->($col->{playlists} || []);
	}, 'getUserPlaylists', $gql, {}, { ttl => Plugins::Zvuk::API::USER_CONTENT_TTL });
}

# Shared track fragment for GigaMix (AI playlist generator) operations
my $GIGAMIX_TRACK_FIELDS = q{
	id
	title
	duration
	availability
	artistTemplate
	explicit
	hasFlac
	condition
	artists {
		id
		title
		image { src }
	}
	release {
		id
		title
		image { src }
		date
	}
};

# Generate a new AI playlist (GigaMix) from a free-text prompt
sub getGenerativePlaylist {
	my ($self, $cb, $args) = @_;
	$args ||= {};

	my $queryText  = $args->{queryText};
	my $promptUuid = $args->{promptUuid};

	my $gql = qq{
		query getGenerativePlaylist(\$queryText: String!, \$promptUuid: String) {
			getGenerativePlaylist(queryText: \$queryText, promptUuid: \$promptUuid) {
				cursor
				playlistName
				genId
				tracks {
					$GIGAMIX_TRACK_FIELDS
				}
			}
		}
	};

	my $vars = {
		queryText  => $queryText,
		promptUuid => $promptUuid,
	};

	$log->info("GigaMix: getGenerativePlaylist queryText='" . ($queryText // '') . "'");

	$self->_graphql(sub {
		my $data = shift;

		if ($data->{error}) {
			$log->error("GigaMix: getGenerativePlaylist failed: $data->{error}");
			$cb->($data);
			return;
		}

		my $result = $data->{getGenerativePlaylist} || {};
		my $tracks = $result->{tracks} || [];

		Plugins::Zvuk::API->cacheTrackMetadata($tracks);

		$cb->({
			playlistName => $result->{playlistName},
			tracks       => $tracks,
			cursor       => $result->{cursor},
			genId        => $result->{genId},
		});
	}, 'getGenerativePlaylist', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Fetch the next page of an existing GigaMix playlist via cursor
# Load next page of GigaMix playlist using cursor-based pagination
sub getGenerativePlaylistPage {
	my ($self, $cb, $args) = @_;
	$args ||= {};

	my $cursor = $args->{cursor};
	my $limit  = $args->{limit} || 20;

	if (!$cursor) {
		$log->error("GigaMix: getGenerativePlaylistPage called without cursor");
		$cb->({ error => 'no_cursor' });
		return;
	}

	my $gql = qq{
		query getGenerativePlaylistPage(\$limit: Int!, \$cursor: Cursor!) {
			getGenerativePlaylistPagination(limit: \$limit, cursor: \$cursor) {
				cursor
				tracks {
					$GIGAMIX_TRACK_FIELDS
				}
			}
		}
	};

	my $vars = {
		limit  => $limit,
		cursor => $cursor,
	};

	$log->info("GigaMix: getGenerativePlaylistPage limit=$limit, cursor='$cursor'");

	$self->_graphql(sub {
		my $data = shift;

		if ($data->{error}) {
			$log->error("GigaMix: getGenerativePlaylistPage failed: $data->{error}");
			$cb->($data);
			return;
		}

		my $result = $data->{getGenerativePlaylistPagination} || {};
		my $tracks = $result->{tracks} || [];

		Plugins::Zvuk::API->cacheTrackMetadata($tracks);

		$cb->({
			tracks => $tracks,
			cursor => $result->{cursor},
		});
	}, 'getGenerativePlaylistPage', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Regenerate (reshuffle) a GigaMix playlist for the same prompt
sub remakeGenerativePlaylist {
	my ($self, $cb, $args) = @_;
	$args ||= {};

	my $queryText = $args->{queryText};

	my $gql = qq{
		query remakeGenerativePlaylist(\$queryText: String!) {
			remakeGenerativePlaylist(queryText: \$queryText) {
				cursor
				playlistName
				genId
				tracks {
					$GIGAMIX_TRACK_FIELDS
				}
			}
		}
	};

	my $vars = {
		queryText => $queryText,
	};

	$log->info("GigaMix: remakeGenerativePlaylist queryText='" . ($queryText // '') . "'");

	$self->_graphql(sub {
		my $data = shift;

		if ($data->{error}) {
			$log->error("GigaMix: remakeGenerativePlaylist failed: $data->{error}");
			$cb->($data);
			return;
		}

		my $result = $data->{remakeGenerativePlaylist} || {};
		my $tracks = $result->{tracks} || [];

		Plugins::Zvuk::API->cacheTrackMetadata($tracks);

		$cb->({
			playlistName => $result->{playlistName},
			tracks       => $tracks,
			cursor       => $result->{cursor},
			genId        => $result->{genId},
		});
	}, 'remakeGenerativePlaylist', $gql, $vars, { ttl => Plugins::Zvuk::API::GIGAMIX_CACHE_TTL });
}

# Get lightweight playlist metadata (no tracks) for a set of playlist IDs.
# operationName is "getShortPlaylist" (verified against zvuk-music sources)
# but the GraphQL field it actually selects is the same getPlaylists field
# used for regular playlists — just without a `tracks` selection.
sub getShortPlaylists {
	my ($self, $cb, $ids) = @_;

	my $gql = q{
		query getShortPlaylist($ids: [ID!]!) {
			getPlaylists(ids: $ids) {
				id
				title
				isPublic
				description
				duration
				image { src }
			}
		}
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) {
			$cb->($data || { error => 'Unknown error' });
			return;
		}
		$cb->($data->{getPlaylists} || []);
	}, 'getShortPlaylist', $gql, { ids => $ids });
}

# Fetch synthesis playlists (Playlists for You personalization feature).
# Fixed, stable per-account IDs (see ma-provider/provider/constants.py:SYNTHESIS_PLAYLIST_IDS).
use constant SYNTHESIS_PLAYLIST_IDS => [3, 4, 6, 11, 12, 13, 14, 15];

sub getSynthesisPlaylists {
	my ($self, $cb) = @_;
	$self->getShortPlaylists($cb, SYNTHESIS_PLAYLIST_IDS);
}

# Get editorial playlist IDs from Zvuk's Tiny API Grid endpoint
sub getEditorialPlaylistIds {
	my ($self, $cb) = @_;
	
	my $url = "https://zvuk.com/api/tiny/grid/content";
	my $params = {
		name => "editorial_playlist",
		ranker_enabled => "true",
	};
	
	$log->info("Fetching editorial playlist IDs from Grid API");
	
	$self->_http_get($url, $params, sub {
		my ($data, $error) = @_;
		
		if ($error) {
			$log->error("Grid API request failed: $error");
			$cb->({ error => "Failed to fetch editorial playlists: $error" });
			return;
		}
		
			if (!$data || !$data->{result} || !$data->{result}{page} || !$data->{result}{page}{data}) {
				$log->warn("Grid API returned empty data structure");
				$cb->([]);
				return;
			}
			
			my $items = $data->{result}{page}{data} || [];
		$log->debug("Grid API returned " . scalar(@$items) . " items");
		
		# Filter only playlists and extract IDs
		my @playlist_ids = map { $_->{id} } grep { $_->{type} eq 'playlist' } @$items;
		
		$log->info("Found " . scalar(@playlist_ids) . " editorial playlist IDs");
		$cb->(\@playlist_ids);
	});
}

# Get lightweight playlist metadata for editorial playlists
	sub getEditorialPlaylistMetadata {
		my ($self, $cb, $playlist_ids) = @_;
		
		unless ($playlist_ids && @$playlist_ids) {
			$log->debug("No playlist IDs provided to getEditorialPlaylistMetadata");
			$cb->([]);
			return;
		}
		
		my $ids = ref $playlist_ids eq 'ARRAY' ? $playlist_ids : [$playlist_ids];
		
		my $gql = q{
			query getShortPlaylist($ids: [ID!]!) {
				getPlaylists(ids: $ids) {
					id
					title
					image {
						src
					}
					description
					trackCount
					isPublic
				}
			}
		};
		
		my $vars = { ids => $ids };
		
		$log->info("getEditorialPlaylistMetadata: requesting metadata for " . scalar(@$ids) . " playlists");
		
		$self->_graphql(sub {
			my $data = shift;
			
			if (!$data || $data->{error}) {
				$cb->($data || { error => 'Unknown error' });
				return;
			}
			
			my $playlists = $data->{getPlaylists} || [];
			$log->debug("getEditorialPlaylistMetadata: received metadata for " . scalar(@$playlists) . " playlists");
			
			$cb->($playlists);
		}, 'getShortPlaylist', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
	}

# Get personalized music recommendations (For You, Trending, etc.).
# $args->{page}: optional page number (defaults to 1).
sub getMusicRecommendations {
	my ($self, $cb, $args) = @_;
	$args ||= {};

	my $contentType = $args->{contentType} || 'Music';
	my $itemTypes   = $args->{itemTypes}   || ['Artist', 'Release', 'Playlist'];
	my $page        = $args->{page}        || 1;

	my $gql = qq{
		query getMusicRecommendations(\$contentType: DynamicBlockContentType!, \$itemType: [DynamicBlockItemType!], \$pages: [Int!]!) {
			dynamicBlock(contentType: \$contentType, itemType: \$itemType, pages: \$pages) {
				totalPages
				pages {
					page
					items {
						__typename
						... on Artist {
							id
							title
							image { src }
						}
						... on Release {
							id
							title
							explicit
							artists {
								id
								title
							}
							image { src }
						}
						... on Playlist {
							id
							title
							duration
							trackCount
							image { src }
						}
					}
				}
			}
		}
	};

	my $vars = {
		contentType => $contentType,
		itemType    => $itemTypes,
		pages       => [$page],
	};

	$log->info("getMusicRecommendations: contentType=$contentType, page=$page");

	$self->_graphql(sub {
		my $data = shift;

		$log->debug("getMusicRecommendations callback received, error=" . ($data->{error} ? 'yes' : 'no'));

		if ($data->{error}) {
			$log->error("getMusicRecommendations failed: $data->{error}");
			$cb->($data);
			return;
		}

		my $block = $data->{dynamicBlock} || {};
		my $pages = $block->{pages} || [];

		$log->debug("getMusicRecommendations: dynamicBlock received, totalPages=$block->{totalPages}, pages count=" . scalar(@$pages));

		# Collect all items from this page
		my @allItems;
		foreach my $page_data (@$pages) {
			my $items = $page_data->{items} || [];
			$log->debug("  Page " . ($page_data->{page} // '?') . ": " . scalar(@$items) . " items");
			push @allItems, @$items;
		}

		$log->debug("getMusicRecommendations: total items collected=" . scalar(@allItems));

		Plugins::Zvuk::API->cacheTrackMetadata(\@allItems) if @allItems;

		# Separate items by type
		my (@artists, @releases, @playlists);
		foreach my $item (@allItems) {
			my $type = $item->{__typename} || 'UNKNOWN';
			$log->debug("  Item typename=$type");
			if ($type eq 'Artist') {
				push @artists, $item;
			} elsif ($type eq 'Release') {
				push @releases, $item;
			} elsif ($type eq 'Playlist') {
				push @playlists, $item;
			}
		}

		$log->info("getMusicRecommendations result: artists=" . scalar(@artists) . ", releases=" . scalar(@releases) . ", playlists=" . scalar(@playlists));

		$cb->({
			allItems    => \@allItems,
			artists     => \@artists,
			releases    => \@releases,
			playlists   => \@playlists,
			totalPages  => $block->{totalPages},
			totalCount  => scalar(@allItems),
		});
	}, 'getMusicRecommendations', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

1;
