package Plugins::Zvuk::API::Sync;

=encoding utf8

=head1 NAME

Plugins::Zvuk::API::Sync - Synchronous Zvuk API client for library scanning

=head1 DESCRIPTION

Synchronous (blocking) HTTP wrapper around Zvuk GraphQL API endpoints.
Used by the library importer/scanner process to fetch user library data:
liked albums, artists, playlists, and track metadata.

All methods perform direct HTTP requests without async callbacks.
Includes rate-limiting (200ms between requests) and error logging.

=cut

use strict;
use warnings;
use utf8;

use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Digest::MD5 qw(md5_hex);
use Time::HiRes qw(time);
use Plugins::Zvuk::API;

my $cache = Slim::Utils::Cache->new();
my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

my $lastRequestTime    = 0;
my $minRequestInterval = 0.2;  # 200ms between requests to avoid rate limits

sub _post_graphql {
	my ($class, $operationName, $query, $variables, $userId) = @_;

	my $token = Plugins::Zvuk::API->getToken($userId);
	unless ($token) {
		$log->error("Zvuk Sync API: No token available for user " . ($userId || 'default'));
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

	# Rate limiting: avoid hitting Zvuk API too fast
	my $now = time();
	if ($lastRequestTime && ($now - $lastRequestTime) < $minRequestInterval) {
		my $sleepTime = $minRequestInterval - ($now - $lastRequestTime);
		select(undef, undef, undef, $sleepTime);
	}
	$lastRequestTime = time();

	my $body = encode_json({
		operationName => $operationName,
		query         => $query,
		variables     => $variables || {},
	});

	$log->is_info && $log->info("Zvuk Sync GraphQL: $operationName (user: " . ($userId || 'default') . ")");

	my $response = Slim::Networking::SimpleSyncHTTP->new({
		timeout => 15,
	})->post(
		Plugins::Zvuk::API::GRAPHQL_URL,
		'x-auth-token' => $token,
		'x-app-name'   => Plugins::Zvuk::API::APP_NAME,
		'x-device-id'  => $deviceId,
		'origin'       => 'https://zvuk.com',
		'referer'      => 'https://zvuk.com/',
		'user-agent'   => Plugins::Zvuk::API::USER_AGENT,
		'content-type' => 'application/json',
		'accept'       => 'application/graphql-response+json, application/json',
		$body
	);

	if ($response && $response->is_success) {
		my $content = $response->content;
		my $result = eval { decode_json($content) };
		if ($@ || !$result) {
			$log->error("Zvuk Sync API: Failed to decode JSON for $operationName: " . ($@ || 'empty'));
			return;
		}
		if ($result->{errors}) {
			$log->error("Zvuk Sync API: GraphQL errors in $operationName: " . encode_json($result->{errors}));
			return;
		}
		return $result->{data};
	} else {
		my $code = $response ? ($response->code || 'unknown') : 'no_response';
		my $err  = $response ? ($response->error || '') : '';
		$log->error("Zvuk Sync API: HTTP error $code for $operationName: $err");
		return;
	}
}

# User liked albums (releases)
sub users_likes_albums {
	my ($class, $userId) = @_;

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

	my $data = $class->_post_graphql('userCollectionReleases', $gql, {}, $userId);
	return unless $data;
	return $data->{collection}{releases} || [];
}

# Full album with all tracks
sub get_album_with_tracks {
	my ($class, $albumId, $userId) = @_;

	my $gql = q{
		query getAlbumTracks($ids: [ID!]!) {
			getReleases(ids: $ids) {
				id
				title
				image { src }
				tracks {
					id
					title
					duration
					availability
					artistTemplate
					position
					artists { id title }
					release { id title image { src } }
				}
			}
		}
	};

	my $data = $class->_post_graphql('getAlbumTracks', $gql, { ids => [$albumId] }, $userId);
	return unless $data && $data->{getReleases} && @{ $data->{getReleases} };
	return $data->{getReleases}[0];
}

# User liked artists
sub users_likes_artists {
	my ($class, $userId) = @_;

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

	my $data = $class->_post_graphql('userCollectionArtists', $gql, {}, $userId);
	return unless $data;
	return $data->{collection}{artists} || [];
}

# Single artist details
sub get_artist {
	my ($class, $artistId, $userId) = @_;

	my $gql = q{
		query getArtists($ids: [ID!]!) {
			getArtists(ids: $ids) {
				id
				title
				image { src }
			}
		}
	};

	my $data = $class->_post_graphql('getArtists', $gql, { ids => [$artistId] }, $userId);
	return unless $data && $data->{getArtists} && @{ $data->{getArtists} };
	return $data->{getArtists}[0];
}

# User playlists
sub users_likes_playlists {
	my ($class, $userId) = @_;

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

	my $data = $class->_post_graphql('getUserPlaylists', $gql, {}, $userId);
	return unless $data;
	return $data->{collection}{playlists} || [];
}

# Playlist tracks
sub get_playlist_tracks {
	my ($class, $playlistId, $userId) = @_;

	my $gql = q{
		query getPlaylistTracks($id: ID!, $limit: Int = 500, $offset: Int = 0) {
			playlistTracks(id: $id, limit: $limit, offset: $offset) {
				id
				title
				duration
				availability
				artistTemplate
				position
				artists { id title }
				release { id title image { src } }
			}
		}
	};

	my $data = $class->_post_graphql('getPlaylistTracks', $gql, { id => $playlistId, limit => 500, offset => 0 }, $userId);
	return unless $data;
	return $data->{playlistTracks} || [];
}

# User liked tracks
sub users_likes_tracks {
	my ($class, $userId) = @_;

	my $gql = q{
		query userTracks {
			collection {
				tracks {
					id
					title
					duration
					availability
					artistTemplate
					position
					explicit
					artists { id title image { src } }
					release { id title image { src } }
				}
			}
		}
	};

	my $data = $class->_post_graphql('userTracks', $gql, {}, $userId);
	return unless $data;
	return $data->{collection}{tracks} || [];
}

# MD5 hash of collection contents for change detection
sub get_library_fingerprint {
	my ($class, $userId) = @_;

	my $gql = q{
		query checkCollection {
			collection {
				releases { id }
				artists { id }
				playlists { id }
				tracks { id }
			}
		}
	};

	my $data = $class->_post_graphql('checkCollection', $gql, {}, $userId);
	return unless $data && $data->{collection};

	my $col = $data->{collection};
	my $rel = join(',', sort map { $_->{id} } @{ $col->{releases} || [] });
	my $art = join(',', sort map { $_->{id} } @{ $col->{artists} || [] });
	my $pl  = join(',', sort map { $_->{id} } @{ $col->{playlists} || [] });
	my $tr  = join(',', sort map { $_->{id} } @{ $col->{tracks} || [] });

	return md5_hex("rel:$rel|art:$art|pl:$pl|tr:$tr");
}

1;
