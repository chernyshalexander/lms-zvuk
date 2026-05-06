package Plugins::Zvuk::API;

use strict;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# --- URLs ---
use constant GRAPHQL_URL  => 'https://zvuk.com/api/v1/graphql';
use constant PROFILE_URL  => 'https://zvuk.com/api/tiny/profile';

# --- Cache TTLs (seconds) ---
use constant DEFAULT_TTL      => 86400;   # 24h  - albums, artists, static content
use constant DYNAMIC_TTL      => 3600;    # 1h   - playlists, search
use constant USER_CONTENT_TTL => 300;     # 5m   - user collection, saved tracks
use constant STREAM_TTL       => 0;       # no cache for stream URLs (they expire)

# --- API pagination ---
use constant DEFAULT_LIMIT => 50;
use constant MAX_LIMIT     => 200;

# --- Quality levels ---
use constant QUALITY_MID  => 'mid';   # MP3 ~192kbps, free
use constant QUALITY_HIGH => 'high';  # MP3 320kbps, subscription required
use constant QUALITY_FLAC => 'flac';  # FLAC lossless, subscription required

# --- HTTP headers required to pass WAF ---
# These were captured from browser DevTools analysis
use constant APP_NAME => 'web-zvuk-service-desktop-app';
use constant USER_AGENT =>
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

# --- Image resolutions ---
use constant IMAGE_SIZE => '500x500';

my $cache = Slim::Utils::Cache->new;
my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

# Return userId of the first configured account (for global operations)
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
    if (!$data) {
        $log->error("No account data found for userId: $userId");
        return;
    }
    my $token = $data->{token};
    if (!$token) {
        $log->error("No token found in account data for userId: $userId");
        return;
    }
    $log->debug("Token found for userId: $userId (" . substr($token, 0, 8) . "...)");
    return $token;
}

# Return the configured quality preference
sub getQuality {
    return $prefs->get('quality') || QUALITY_HIGH;
}

# Build image URL from the Zvuk CDN src field with optional size params
sub getImageUrl {
    my ($class, $item, $usePlaceholder) = @_;

    my $src = $item->{image}{src}
           || $item->{release}{image}{src}
           || $item->{cover}
           || '';

    if ($src && $src !~ /\?/) {
        $src .= '?width=500&height=500';
    }

    return $src if $src;

    return (!main::SCANNER && $usePlaceholder)
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

        my $meta = {
            id          => $id,
            title       => $track->{title}          || '',
            artist      => $track->{artistTemplate} || '',
            album       => $track->{release}{title} || '',
            duration    => $track->{duration}        || 0,
            icon        => $icon,
            cover       => $icon,
            type        => 'mp3',
            bitrate     => 'N/A',
        };

        $cache->set( "zvuk_meta_$id", $meta, DEFAULT_TTL );
        $meta;
    } @$tracks ];
}

1;
