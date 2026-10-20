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

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

# Return userId of the active or default configured account
sub getSomeUserId {
    my $accounts = $prefs->get('accounts');
    return unless ref $accounts eq 'HASH' && keys %$accounts;

    my $defaultUserId = $prefs->get('defaultUserId');
    if (defined $defaultUserId && length($defaultUserId) && $accounts->{$defaultUserId} && $accounts->{$defaultUserId}{token}) {
        return $defaultUserId;
    }

    # Otherwise return the first account with a valid token
    foreach my $id (sort keys %$accounts) {
        if ($accounts->{$id} && $accounts->{$id}{token}) {
            return $id;
        }
    }
    return;
}

# Return account data for a given userId
sub getUserdata {
    my ($class, $userId);
    if (@_ <= 1) {
        $class = __PACKAGE__;
        $userId = $_[0] if @_ == 1 && $_[0] ne __PACKAGE__;
    } else {
        ($class, $userId) = @_;
    }
    $userId ||= Plugins::Zvuk::API->getSomeUserId();
    return unless defined $userId && length($userId);
    my $accounts = $prefs->get('accounts') || return;
    return unless ref $accounts eq 'HASH';
    return $accounts->{$userId};
}

# Return the token for a given userId
sub getToken {
    my ($class, $userId);
    if (@_ <= 1) {
        $class = __PACKAGE__;
        $userId = $_[0] if @_ == 1 && $_[0] ne __PACKAGE__;
    } else {
        ($class, $userId) = @_;
    }
    $userId ||= Plugins::Zvuk::API->getSomeUserId();
    return unless defined $userId && length($userId);
    my $data = Plugins::Zvuk::API->getUserdata($userId);
    return unless $data;
    return $data->{token};
}

# Extract human-readable account display name from profile object
sub extractAccountName {
    my ($class, $profile, $userId) = @_;
    my $accountName = "Account " . ($userId || '');

    if ($profile && ref($profile) eq 'HASH') {
        if ($profile->{external_profile} && ref($profile->{external_profile}) eq 'HASH') {
            my $extProf = $profile->{external_profile};
            my @nameParts;
            push @nameParts, $extProf->{first_name} if $extProf->{first_name};
            push @nameParts, $extProf->{middle_name} if $extProf->{middle_name};
            push @nameParts, $extProf->{last_name} if $extProf->{last_name};
            $accountName = join(' ', @nameParts) if @nameParts;
        }
        elsif ($profile->{name}) {
            $accountName = $profile->{name};
        }
        elsif ($profile->{username}) {
            $accountName = $profile->{username};
        }
    }
    return $accountName;
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
            $cache->set( "zvuk_meta_$id", $cached, DEFAULT_TTL ) if $updated;
            push @result, $cached;
            next;
        }

        my $dur = int($track->{duration} || 0);
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
