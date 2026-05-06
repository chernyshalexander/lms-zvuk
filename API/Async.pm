package Plugins::Zvuk::API::Async;

use strict;

use Async::Util;
use Digest::MD5 qw(md5_hex);
use JSON::XS;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Zvuk::API;

my $cache = Slim::Utils::Cache->new();
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

# Base GraphQL request helper with caching
sub _graphql {
	my ($self, $cb, $operationName, $query, $variables, $params) = @_;
	$params ||= {};

	my $noCache = $params->{nocache} || 0;
	my $ttl = $params->{ttl};

	my $cacheKey;
	unless ($noCache) {
		$cacheKey = "zvuk_gql:" . $self->{userId} . ":$operationName:" . md5_hex(encode_json($variables || {}));
		if (my $cached = $cache->get($cacheKey)) {
			$log->debug("Cache hit for $operationName");
			return $cb->($cached);
		}
	}

	my $token = Plugins::Zvuk::API->getToken($self->{userId});

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

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			$log->debug("GraphQL response received for $operationName, status: " . $response->code);

			my $content = $response->content;
			if (!$content || length($content) == 0) {
				$log->error("GraphQL: Empty response content for $operationName");
				$cb->({ error => 'empty_response' });
				return;
			}

			my $result = eval { decode_json($content) };

			if ($@) {
				$log->error("GraphQL: Failed to parse JSON response for $operationName: $@");
				$log->error("GraphQL: Response content (first 500 chars): " . substr($content, 0, 500));
				$cb->({ error => 'parse_error', details => $@ });
				return;
			}

			if ($result->{errors}) {
				$log->error("GraphQL API errors for $operationName: " . encode_json($result->{errors}));
				$log->debug("GraphQL Variables: " . encode_json($variables));
				$cb->({ error => 'api_error', details => $result->{errors} });
				return;
			}

			my $data = $result->{data};
			if (!$data) {
				$log->warn("GraphQL: No data in response for $operationName");
				$log->debug("GraphQL: Full response: " . encode_json($result));
				$cb->({ error => 'no_data' });
				return;
			}

			if ($cacheKey && $data) {
				my $cacheTTL = $ttl || _getCacheTTL($operationName);
				$cache->set($cacheKey, $data, $cacheTTL);
				$log->debug("GraphQL: Cached $operationName for ${cacheTTL}s");
			}
			$log->info("GraphQL success: $operationName");
			$cb->($data);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("GraphQL HTTP request failed for $operationName: $error");
			$cb->({ error => 'http_error', details => $error });
		},
		{
			timeout => 15,
		}
	);

	$log->info("GraphQL Request: $operationName (userId: $self->{userId}, cache: " . ($cacheKey ? 'enabled' : 'disabled') . ")");
	$log->debug("GraphQL URL: " . Plugins::Zvuk::API::GRAPHQL_URL);
	$log->debug("GraphQL Token: " . substr($token, 0, 8) . "..." . substr($token, -4));

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

	return Plugins::Zvuk::API::USER_CONTENT_TTL if $operationName =~ m/^(getCollection|getUserPlaylists|getPersonalWave)$/;
	return Plugins::Zvuk::API::DYNAMIC_TTL if $operationName =~ m/^(getSearch|quickSearch|searchTracks|searchArtists|searchReleases|searchPlaylists|getTracks)$/;
	return Plugins::Zvuk::API::DEFAULT_TTL;
}

# --- API Methods ---

# Get user profile to validate token and get real userId
sub getProfile {
	my ($class, $cb, $token) = @_;

	# This is a GET request to a tiny API
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

# Quick search (getSearch) - limited results
sub search {
	my ($self, $cb, $args) = @_;

	my $query = $args->{query};
	my $limit = $args->{limit} || Plugins::Zvuk::API::DEFAULT_LIMIT;

	$log->info("Zvuk search: query='$query', limit=$limit (using quickSearch)");

	my $gql = <<'GRAPHQL';
query getSearch($query: String, $first: Int) {
  quickSearch(query: $query, limit: $first) {
    content {
      __typename
      ... on Track {
        id title artistTemplate duration availability
        release { title image { src } }
      }
      ... on Artist {
        id title image { src }
      }
      ... on Release {
        id title artistTemplate image { src }
      }
      ... on Playlist {
        id title image { src }
      }
    }
  }
}
GRAPHQL

	$self->_graphql(sub {
		my $data = shift;
		$log->debug("quickSearch response: " . (ref $data ? "Got hash with " . (scalar(@{$data->{quickSearch}{content} || []}) . " items") : "Error: $data"));
		$cb->($data);
	}, 'getSearch', $gql, { query => $query, first => $limit });
}

# Get stream URL for tracks
sub getStream {
	my ($self, $cb, $ids) = @_;

	my $gql = <<'GRAPHQL';
query getStream($ids: [ID!]!) {
  mediaContents(ids: $ids) {
    __typename
    ... on Track {
      stream {
        expire
        expireDelta
        high
        mid
        flac
        flacdrm
      }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getStream', $gql, { ids => $ids });
}

# Get full track data
sub getTracks {
	my ($self, $cb, $ids) = @_;

	my $gql = <<'GRAPHQL';
query getTracks($ids: [ID!]!) {
  getTracks(ids: $ids) {
    id title duration availability artistTemplate
    release { id title image { src } }
    artists { id title }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getTracks', $gql, { ids => $ids });
}

# Get album info with tracks
sub getAlbum {
	my ($self, $cb, $id) = @_;

	my $gql = <<'GRAPHQL';
query getAlbum($ids: [ID!]!) {
  getReleases(ids: $ids, withTracks: true) {
    id title artistTemplate image { src }
    tracks {
      id title duration availability artistTemplate
      release { title image { src } }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getAlbum', $gql, { ids => [$id] });
}

# Get artist top tracks
sub getArtist {
	my ($self, $cb, $id) = @_;

	my $gql = <<'GRAPHQL';
query getArtist($ids: [ID!]!) {
  getArtists(ids: $ids) {
    id title image { src }
    topTracks {
      id title duration availability artistTemplate
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getArtist', $gql, { ids => [$id] });
}

# Get artist albums/releases
sub getArtistAlbums {
	my ($self, $cb, $id) = @_;

	my $gql = <<'GRAPHQL';
query getArtistReleases($ids: [ID!]!) {
  getArtists(ids: $ids) {
    releases(limit: 50) {
      id title type date artistTemplate
      image { src }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getArtistReleases', $gql, { ids => [$id] }, { ttl => 86400 });
}

# Get full playlist (all info except paginated tracks)
sub getPlaylist {
	my ($self, $cb, $id) = @_;

	my $gql = <<'GRAPHQL';
query getPlaylist($ids: [ID!]!) {
  playlists(ids: $ids) {
    id title image { src } description
  }
}
GRAPHQL

	$self->_graphql($cb, 'getPlaylist', $gql, { ids => [$id] });
}

# Get paginated playlist tracks
sub getPlaylistTracks {
	my ($self, $cb, $id, $limit, $offset) = @_;
	$limit ||= Plugins::Zvuk::API::DEFAULT_LIMIT;
	$offset ||= 0;

	my $gql = <<'GRAPHQL';
query getPlaylistTracks($id: ID!, $limit: Int, $offset: Int) {
  playlistTracks(id: $id, limit: $limit, offset: $offset) {
    items {
      id title duration availability artistTemplate
      release { title image { src } }
    }
    total
  }
}
GRAPHQL

	$self->_graphql($cb, 'getPlaylistTracks', $gql, { id => $id, limit => $limit, offset => $offset }, { nocache => 1 });
}

# Get user collection (My Music tracks)
sub getCollection {
	my ($self, $cb, $args) = @_;

	my $limit = $args->{limit} || 30;
	my $after = $args->{after} || "";

	my $gql = <<'GRAPHQL';
query getPaginatedCollection($first: Int, $after: String) {
  paginatedCollection {
    tracks(pagination: {first: $first, after: $after}) {
      items {
        id title duration availability artistTemplate
        release { title image { src } }
      }
      page { endCursor }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getPaginatedCollection', $gql, { first => $limit, after => $after });
}

# Get user playlists
sub getUserPlaylists {
	my ($self, $cb, $args) = @_;

	my $limit = $args->{limit} || 30;
	my $after = $args->{after} || "";

	my $gql = <<'GRAPHQL';
query getUserPlaylists($limit: Int = 30, $after: String = null) {
  paginatedCollection {
    playlists(pagination: {first: $limit, after: $after}) {
      items {
        id title
        image { src }
      }
      page { endCursor }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getUserPlaylists', $gql, { limit => $limit, after => $after });
}

# Get personal wave tracks
sub getPersonalWave {
	my ($self, $cb, $args) = @_;

	my $first = $args->{first} || 30;

	my $gql = <<'GRAPHQL';
query getPersonalWave($first: PositiveInt! = 30) {
  personalWaveContent(first: $first) {
    id title duration availability artistTemplate
    release { title image { src } }
  }
}
GRAPHQL

	$self->_graphql($cb, 'getPersonalWave', $gql, { first => $first });
}

# Full categorized search - Tracks
sub searchTracks {
	my ($self, $cb, $args) = @_;

	my $query  = $args->{query};
	my $limit  = $args->{first} || Plugins::Zvuk::API::DEFAULT_LIMIT;
	my $offset = $args->{offset} || 0;

	$log->info("searchTracks: query='$query', limit=$limit, offset=$offset");

	my $gql = <<'GRAPHQL';
query searchTracks($query: String, $first: Int, $offset: Int) {
  searchTracks(query: $query, first: $first, offset: $offset) {
    total
    items {
      id title duration availability artistTemplate
      release { title image { src } }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'searchTracks', $gql, { query => $query, first => $limit, offset => $offset }, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Full categorized search - Artists
sub searchArtists {
	my ($self, $cb, $args) = @_;

	my $query  = $args->{query};
	my $limit  = $args->{first} || Plugins::Zvuk::API::DEFAULT_LIMIT;
	my $offset = $args->{offset} || 0;

	$log->info("searchArtists: query='$query', limit=$limit, offset=$offset");

	my $gql = <<'GRAPHQL';
query searchArtists($query: String, $first: Int, $offset: Int) {
  searchArtists(query: $query, first: $first, offset: $offset) {
    total
    items {
      id title image { src }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'searchArtists', $gql, { query => $query, first => $limit, offset => $offset }, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Full categorized search - Releases (Albums)
sub searchReleases {
	my ($self, $cb, $args) = @_;

	my $query  = $args->{query};
	my $limit  = $args->{first} || Plugins::Zvuk::API::DEFAULT_LIMIT;
	my $offset = $args->{offset} || 0;

	$log->info("searchReleases: query='$query', limit=$limit, offset=$offset");

	my $gql = <<'GRAPHQL';
query searchReleases($query: String, $first: Int, $offset: Int) {
  searchReleases(query: $query, first: $first, offset: $offset) {
    total
    items {
      id title type date artistTemplate
      image { src }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'searchReleases', $gql, { query => $query, first => $limit, offset => $offset }, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Full categorized search - Playlists
sub searchPlaylists {
	my ($self, $cb, $args) = @_;

	my $query  = $args->{query};
	my $limit  = $args->{first} || Plugins::Zvuk::API::DEFAULT_LIMIT;
	my $offset = $args->{offset} || 0;

	$log->info("searchPlaylists: query='$query', limit=$limit, offset=$offset");

	my $gql = <<'GRAPHQL';
query searchPlaylists($query: String, $first: Int, $offset: Int) {
  searchPlaylists(query: $query, first: $first, offset: $offset) {
    total
    items {
      id title image { src }
    }
  }
}
GRAPHQL

	$self->_graphql($cb, 'searchPlaylists', $gql, { query => $query, first => $limit, offset => $offset }, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

1;
