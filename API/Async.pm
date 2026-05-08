package Plugins::Zvuk::API::Async;

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use JSON::XS;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Zvuk::API;

# CRITICAL: We use a centralized cache from Plugins::Zvuk::API.
# This avoids data isolation and ensures metadata is consistent across the plugin.
# Centralized cache is used from Plugins::Zvuk::API
my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

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

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $content = $response->content;

			if (!$content || length($content) == 0) {
				$log->error("GraphQL: Empty response for $operationName");
				$cb->({ error => 'empty_response' });
				return;
			}

			my $result = eval { decode_json($content) };
			if ($@ || !$result) {
				$log->error("GraphQL: JSON parse error for $operationName: $@");
				$cb->({ error => 'parse_error' });
				return;
			}

			if ($result->{errors}) {
				my $msg = $result->{errors}->[0]->{message} || 'Unknown API error';
				$log->error("GraphQL API error ($operationName): $msg");
				$cb->({ error => $msg });
				return;
			}

			my $data = $result->{data};
			if (!$data) {
				$log->warn("GraphQL: No data in response for $operationName");
				$cb->({ error => 'no_data' });
				return;
			}

			if ($cacheKey && $data) {
				Plugins::Zvuk::API->cache->set($cacheKey, $data, $ttl);
				$log->debug("GraphQL: Cached $operationName for ${ttl}s");
			}

			$cb->($data);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("GraphQL HTTP error ($operationName): $error");
			$cb->({ error => 'http_error', details => $error });
		},
		{ timeout => 15 }
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

sub _getCacheTTL {
	my ($operationName) = @_;

	return 0 if $operationName =~ m/^(getStream|getPersonalWave)$/;
	return Plugins::Zvuk::API::USER_CONTENT_TTL if $operationName =~ m/^(getPaginatedCollection|getUserPlaylists|userTracks|userCollection|userPaginatedPodcasts|userPaginatedEpisodes)$/;
	return Plugins::Zvuk::API::DYNAMIC_TTL if $operationName =~ m/^(getSearch|quickSearch|search|searchTracks|searchArtists|searchReleases|searchPlaylists|getTracks|getArtistAlbums|getPodcastEpisodes)$/;
	return Plugins::Zvuk::API::DEFAULT_TTL;
}

# --- API Methods ---

# Get user profile to validate token and get real userId
sub getProfile {
	my ($class, $cb, $token) = @_;

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $result = eval { decode_json($response->content) };
			$cb->($result->{result});
		},
		sub {
			$cb->({ error => $_[1] });
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
	my ($self, $cb) = @_;

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

	my $vars = {
		waveSrc => "AMAZME",
		first   => 20,
		options => {
			popular => undef,
			mood    => "energy:0.5,fun:0.5",
		},
	};

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
		query userCollection {
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
	}, 'userCollection', $gql, {});
}

sub _getCollectionArtists {
	my ($self, $cb) = @_;
	my $gql = q{
		query userCollection {
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
	}, 'userCollection', $gql, {});
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

1;
