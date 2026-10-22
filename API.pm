package Plugins::Zvuk::API;

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# --- URLs ---
use constant GRAPHQL_URL    => 'https://zvuk.com/api/v1/graphql';
use constant PROFILE_URL    => 'https://zvuk.com/api/tiny/profile';
use constant REFRESH_URL    => 'https://zvuk.com/api/tiny/refresh';
use constant ROUTE_AUTH_URL => 'https://zvuk.com/api/tiny/route-authorization-type';
use constant GET_MCODE_URL  => 'https://zvuk.com/api/tiny/get-mcode';
use constant LOGIN_OTP_URL  => 'https://zvuk.com/api/tiny/login/otp';
use constant TINY_API_URL   => 'https://zvuk.com/api/tiny';
use constant ATLAS_BASE_URL => 'https://atlas.zvuk.com';

# --- Mobile app constants (for Android OTP auth endpoints) ---
use constant APP_VERSION_ANDROID => '4.116.0rs';
use constant APP_BUILD_ANDROID   => '511600228';

# --- Cache TTLs (seconds) ---
use constant DEFAULT_TTL        => 86400;   # 24h  - albums, artists, static content
use constant DYNAMIC_TTL        => 3600;    # 1h   - playlists, search
use constant USER_CONTENT_TTL   => 300;     # 5m   - user collection, saved tracks
use constant GIGAMIX_CACHE_TTL  => 10;      # 10s  - GigaMix remix (short cache for fresh content)
use constant STREAM_TTL         => 0;       # no cache for stream URLs
use constant ATLAS_MAP_TTL      => 3600;    # 1h   - Atlas taste map
use constant ATLAS_ISLAND_TTL   => 86400;   # 24h  - Atlas island track listings

# --- API pagination ---
use constant DEFAULT_LIMIT => 50;
use constant MAX_LIMIT     => 200;

# --- Quality levels ---
use constant QUALITY_MID  => 'mid';   # MP3 128kbps
use constant QUALITY_HIGH => 'high';  # MP3 320kbps
use constant QUALITY_FLAC => 'flac';  # FLAC lossless

# --- HTTP headers required to pass WAF ---
use constant APP_NAME => 'web-zvuk-service-desktop-app';
use constant USER_AGENT =>
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

# --- Image resolutions ---
use constant IMAGE_SIZE => '500x500';

use Plugins::Zvuk::Session;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

# --- Session & Multi-Account Management (delegated to Plugins::Zvuk::Session) ---

sub getSomeUserId      { shift; Plugins::Zvuk::Session->getSomeUserId(@_) }
sub getUserdata        { shift; Plugins::Zvuk::Session->getUserdata(@_) }
sub getToken           { shift; Plugins::Zvuk::Session->getToken(@_) }
sub extractAccountName { shift; Plugins::Zvuk::Session->extractAccountName(@_) }
sub getUserIdForClient { shift; Plugins::Zvuk::Session->getUserIdForClient(@_) }
sub hasAccounts        { shift; Plugins::Zvuk::Session->hasAccounts(@_) }
sub getAccounts        { shift; Plugins::Zvuk::Session->getAccounts(@_) }
sub saveAccount        { shift; Plugins::Zvuk::Session->saveAccount(@_) }
sub deleteAccount      { shift; Plugins::Zvuk::Session->deleteAccount(@_) }

# --- Unified API Client Facade ---

# Returns unified async API client for a client player or userId
sub getClient {
	my ($class, $client_or_userId) = @_;
	my $userId;
	if (ref $client_or_userId) {
		$userId = Plugins::Zvuk::Session->getUserIdForClient($client_or_userId);
	} else {
		$userId = $client_or_userId || Plugins::Zvuk::Session->getSomeUserId();
	}
	return unless defined $userId && length($userId);

	require Plugins::Zvuk::API::Async;
	return Plugins::Zvuk::API::Async->new({ userId => $userId });
}

# Return the configured quality preference
# Centralized cache shared by all Zvuk modules (Plugin, ProtocolHandler, Async)
my $cache = Slim::Utils::Cache->new();

sub cache {
    return $cache;
}

sub getQuality {
    return $prefs->get('quality') || QUALITY_HIGH;
}

# Build image URL from the Zvuk CDN
sub getImageUrl {
    my ($class, $item, $usePlaceholder) = @_;

    my $src = $item->{image}{src}
           || $item->{release}{image}{src}
           || $item->{cover}
           || '';

    if ($src) {
        # Static files (like /static/avatar/...) require authentication to fetch from Zvuk.
        # Since the player/browser cannot fetch them directly without cookies/headers,
        # we route them through our authenticated image proxy.
        if ($src =~ m{/static/}) {
            if ($src =~ m{^/}) {
                $src = 'https://zvuk.com' . $src;
            }
            require URI::Escape;
            $src = '/plugins/zvuk/imageproxy?url=' . URI::Escape::uri_escape($src);
        }
        else {
            if ($src =~ m{^/}) {
                $src = 'https://zvuk.com' . $src;
            }
            # Handle {size} placeholder if present
            $src =~ s/\{size\}/500x500/g;
            
            # Add size parameters if no parameters present
            if ($src !~ /\?/) {
                $src .= '?width=500&height=500';
            }
        }
    }

    return $src if $src;

    return ($usePlaceholder)
        ? Plugins::Zvuk::Plugin->_pluginDataFor('icon')
        : '';
}

# Cache track metadata for getMetadataFor() in ProtocolHandler
sub cacheTrackMetadata {
    my ($class, $tracks) = @_;
    return [] unless $tracks && ref $tracks eq 'ARRAY' && @$tracks;

    my @result;
    for my $track (@$tracks) {
        next unless $track && ref $track eq 'HASH';
        my $id = $track->{id} || $track->{track_id} or next;

        my $icon   = $track->{cover_url} || $class->getImageUrl($track, 'usePlaceholder');
        my $artist = $track->{artist} || $class->_getArtistName($track);
        my $album  = ($track->{release} && $track->{release}->{title}) ? $track->{release}->{title} : ($track->{album} || '');

        my $artist_id = ($track->{artists} && ref $track->{artists} eq 'ARRAY' && $track->{artists}->[0])
            ? ($track->{artists}->[0]->{id})
            : ($track->{artist_id} || '');
        my $release_id = ($track->{release} && ref $track->{release} eq 'HASH')
            ? $track->{release}->{id}
            : ($track->{release_id} || '');

        my $dur = int($track->{duration} || 0);

        # Check if already cached, reuse if found
        if (my $cached = $cache->get("zvuk_meta_$id")) {
            my $updated = 0;
            if (!$cached->{artist_id} && $artist_id) {
                $cached->{artist_id} = $artist_id;
                $updated = 1;
            }
            if (!$cached->{release_id} && $release_id) {
                $cached->{release_id} = $release_id;
                $updated = 1;
            }
            if (!$cached->{artists} && $track->{artists}) {
                $cached->{artists} = $track->{artists};
                $updated = 1;
            }
            if (!$cached->{release} && $track->{release}) {
                $cached->{release} = $track->{release};
                $updated = 1;
            }
            if (!$cached->{album} && $album) {
                $cached->{album} = $album;
                $updated = 1;
            }
            if ((!$cached->{duration} || $cached->{duration} == 0) && $dur) {
                $cached->{duration} = $dur;
                $cached->{secs}     = $dur;
                $updated = 1;
            }
            $cache->set( "zvuk_meta_$id", $cached, DEFAULT_TTL ) if $updated;
            push @result, $cached;
            next;
        }
        my $meta = {
            id          => $id,
            title       => $track->{title}          || '',
            artist      => $artist,
            artist_id   => $artist_id,
            album       => $album,
            release_id  => $release_id,
            artists     => $track->{artists},
            release     => $track->{release},
            duration    => $dur,
            secs        => $dur,
            icon        => $icon,
            cover       => $icon,
        };

        $cache->set( "zvuk_meta_$id", $meta, DEFAULT_TTL );
        push @result, $meta;
    }

    return \@result;
}

sub _getArtistName {
    my ($class, $item) = @_;
    
    my $template = $item->{artistTemplate};
    my $artists  = $item->{artists} || [];
    
    if ($template) {
        # The Zvuk API uses templates like "{0} & {1}" for multiple artists.
        # We resolve these placeholders by replacing them with names from the 'artists' array.
        if ($template =~ /\{/) {
            $template =~ s/\{(\d+)\}/$artists->[$1] ? $artists->[$1]->{title} : ""/ge;
        }
        return $template;
    }
    
    if (ref $artists eq 'ARRAY' && scalar @$artists) {
        return join(', ', map { $_->{title} } @$artists);
    }
    
    return '';
}

1;
