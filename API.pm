package Plugins::Zvuk::API;

use strict;

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
use constant QUALITY_MID  => 'mid';   # MP3 ~192kbps
use constant QUALITY_HIGH => 'high';  # MP3 320kbps
use constant QUALITY_FLAC => 'flac';  # FLAC lossless

# --- HTTP headers required to pass WAF ---
use constant APP_NAME => 'web-zvuk-service-desktop-app';
use constant USER_AGENT =>
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

# --- Image resolutions ---
use constant IMAGE_SIZE => '500x500';

my $cache = Slim::Utils::Cache->new;
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

        my $meta = {
            id          => $id,
            title       => $track->{title}          || '',
            artist      => $artist,
            album       => ($track->{release} && $track->{release}->{title}) ? $track->{release}->{title} : '',
            duration    => $track->{duration}        || 0,
            icon        => $icon,
            cover       => $icon,
        };

        $cache->set( "zvuk_meta_$id", $meta, DEFAULT_TTL );
        $meta;
    } @$tracks ];
}

sub _getArtistName {
    my ($class, $item) = @_;
    
    return $item->{artistTemplate} if $item->{artistTemplate};
    
    if ($item->{artists} && ref $item->{artists} eq 'ARRAY' && scalar @{$item->{artists}}) {
        return join(', ', map { $_->{title} } @{$item->{artists}});
    }
    
    return '';
}

1;
