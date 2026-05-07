package Plugins::Zvuk::API;

use strict;
use warnings;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# --- URLs ---
use constant GRAPHQL_URL  => 'https://zvuk.com/api/v1/graphql';
use constant PROFILE_URL  => 'https://zvuk.com/api/tiny/profile';
use constant TINY_API_URL => 'https://zvuk.com/api/tiny';

# --- Cache TTLs (seconds) ---
use constant DEFAULT_TTL      => 86400;   # 24h  - albums, artists, static content
use constant DYNAMIC_TTL      => 3600;    # 1h   - playlists, search
use constant USER_CONTENT_TTL => 300;     # 5m   - user collection, saved tracks
use constant STREAM_TTL       => 0;       # no cache for stream URLs

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

# Return userId of the first configured account
sub getSomeUserId {
    my $accounts = $prefs->get('accounts') || {};
    my ($account) = keys %$accounts;
    return $account;
}

# Return account data for a given userId
sub getUserdata {
    my ($class, $userId) = @_;
    return unless $userId;
    my $accounts = $prefs->get('accounts') || return;
    return $accounts->{$userId};
}

# Return the token for a given userId
sub getToken {
    my ($class, $userId) = @_;
    my $data = $class->getUserdata($userId);
    return unless $data;
    return $data->{token};
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
        # Handle {size} placeholder if present
        $src =~ s/\{size\}/500x500/g;
        
        # Add size parameters if no parameters present
        if ($src !~ /\?/) {
            $src .= '?width=500&height=500';
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
    return [] unless $tracks && @$tracks;

    return [ map {
        my $track = $_;
        my $id    = $track->{id} or next;
        my $icon  = $class->getImageUrl($track, 'usePlaceholder');
        my $artist = $class->_getArtistName($track);

        my $dur = int($track->{duration} || 0);
        my $meta = {
            id          => $id,
            title       => $track->{title}          || '',
            artist      => $artist,
            album       => ($track->{release} && $track->{release}->{title}) ? $track->{release}->{title} : '',
            duration    => $dur,
            secs        => $dur,
            icon        => $icon,
            cover       => $icon,
        };

        if ($log->is_debug) {
            $log->debug("Caching metadata for track $id: " . $track->{title} . " (duration: $dur)");
        }

        $cache->set( "zvuk_meta_$id", $meta, DEFAULT_TTL );
        $meta;
    } @$tracks ];
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
