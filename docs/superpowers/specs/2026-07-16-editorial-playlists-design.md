# Editorial Playlists Feature Design

**Date:** 2026-07-16
**Status:** Approved
**Author:** AI Assistant with Alexander Chernysh

## Overview

Add a new "Editorial Playlists" (Подборки) menu item to the LMS-Zvuk plugin that displays curated genre-based playlists from Zvuk's editorial team. This feature uses the stable Tiny API Grid endpoint instead of the problematic dynamicBlock GraphQL query, providing WAF-safe access to high-quality curated content.

## Requirements

### Functional Requirements

1. **New Menu Item**: Add "Подборки" (Editorial Playlists) to the root menu after "Рекомендации"
2. **Grid API Integration**: Query `/api/tiny/grid/content?name=editorial_playlist` to get playlist IDs
3. **Metadata Loading**: Load lightweight playlist metadata using `getShortPlaylist` GraphQL query
4. **Playlist Display**: Show all available editorial playlists with titles, images, and descriptions
5. **Click Navigation**: Click on a playlist → existing `handlePlaylist` for track display

### Non-Functional Requirements

1. **WAF Safety**: Use simple GET requests to avoid triggering WAF blocks
2. **Performance**: Fast loading using lightweight metadata queries (no track details)
3. **Error Resilience**: Graceful handling of API failures without breaking the menu
4. **Multi-Account**: Support multiple user accounts with personalized recommendations
5. **Localization**: Support Russian and English languages

## Architecture

### Components

```
API/Async.pm
├── getEditorialPlaylistIds($cb)     # New: Grid API client
└── getShortPlaylist($cb, $ids)       # New: Lightweight metadata

Plugin.pm  
├── handleEditorialPlaylists($client, $cb)  # New: Menu handler
└── _renderEditorialPlaylist($playlist)     # New: Playlist rendering

strings.txt
└── PLUGIN_ZVUK_EDITORIAL_PLAYLISTS*       # New: Localization strings
```

### Component Interfaces

**API/Async.pm methods:**

```perl
sub getEditorialPlaylistIds($cb)
# Input: callback sub
# Output: $cb->(['123', '456', '789', ...]) 
#         or $cb->({error => 'error message'})
# Purpose: Fetch editorial playlist IDs from Grid API

sub getShortPlaylist($cb, $playlist_ids)
# Input: callback sub + array ref of playlist IDs
# Output: $cb->([{id, title, image, description, ...}, ...])
# Purpose: Load lightweight playlist metadata without tracks
```

**Plugin.pm methods:**

```perl
sub handleEditorialPlaylists($client, $cb)
# Input: LMS client + callback
# Output: $cb->({items => [...]})
# Purpose: Main menu handler for editorial playlists

sub _renderEditorialPlaylist($playlist)
# Input: Playlist object from API
# Output: OPML item hash
# Purpose: Render individual playlist for menu display
```

## Data Flow

```
User clicks "Подборки"
    ↓
handleEditorialPlaylists($client, $cb)
    ↓
_get_api_client($client) → API client for current user
    ↓
getEditorialPlaylistIds(sub {
    my $ids = shift;
    # GET /api/tiny/grid/content?name=editorial_playlist&ranker_enabled=true
    # Parse JSON: {page => {data => [{id => "123", type => "playlist"}, ...]}}
    # Filter: only items where type eq 'playlist'
    # Extract: ['123', '456', '789', ...]
})
    ↓
getShortPlaylist($ids, sub {
    my $playlists = shift;
    # GraphQL getShortPlaylist query with IDs
    # Parse: [{id, title, image {src}, description, ...}, ...]
    # Cache: standard TTL for playlist metadata
})
    ↓
_renderEditorialPlaylist($playlist) for each playlist
    ↓
$cb->({
    items => [
        {name => "Рок-хиты", type => 'link', url => \&handlePlaylist, passthrough => [{id => "123"}]},
        {name => "Поп-новинки", type => 'link', url => \&handlePlaylist, passthrough => [{id => "456"}]},
        ...
    ]
})
```

## Implementation Details

### Grid API Client (API/Async.pm)

**Endpoint:** `GET https://zvuk.com/api/tiny/grid/content`

**Parameters:**
- `name`: "editorial_playlist"
- `ranker_enabled`: "true" (enable personalization)

**Response parsing:**
```perl
my $data = $result->{page}{data};
my @playlist_ids = map { $_->{id} } grep { $_->{type} eq 'playlist' } @$data;
```

**Error handling:**
- Network error → return `{error => 'Network error'}`
- Empty data → return empty array `[]`
- API error → return `{error => $error_message}`

### GraphQL Metadata Query

**Query name:** `getShortPlaylist`

**Variables:** `{ids => ['123', '456', ...]}`

**Response fields:** `id, title, image {src}, description, trackCount`

**Integration:** Use existing `_graphql` method with standard error handling

### Menu Integration (Plugin.pm)

**Location in `_buildRootMenu`:**
```perl
# After recommendations section:
{
    name  => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS'),
    type  => 'link',
    image => 'plugins/zvuk/html/images/genres.png',
    url   => \&handleEditorialPlaylists,
}
```

**Rendering pattern:**
```perl
sub _renderEditorialPlaylist {
    my ($playlist) = @_;
    return {
        name      => $playlist->{title},
        line1     => $playlist->{title},
        line2     => $playlist->{description} || "",
        type      => 'link',
        url       => \&handlePlaylist,
        passthrough => [{ id => $playlist->{id} }],
        image     => Plugins::Zvuk::API->getImageUrl($playlist),
    };
}
```

## Error Handling Strategy

### Three-Layer Error Protection

1. **Grid API Layer:** 
   - Connection failure → Show error message, don't crash
   - Empty results → Show "No editorial playlists available"
   - API error → Log and show error message

2. **GraphQL Layer:**
   - Query failure → Fallback to basic info from Grid API
   - Partial results → Show available playlists
   - Timeout → Use cached data if available

3. **Menu Layer:**
   - No menu crash → Always return valid menu structure
   - Graceful degradation → Error messages instead of empty menu
   - Existing menu preservation → Other menu items unaffected

### Error Messages

```perl
# Localization keys
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_ERROR = "Error loading editorial playlists"
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY  = "No editorial playlists available"
```

## Localization

### strings.txt additions

```
# English
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS=Editorial Playlists
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_ERROR=Error loading editorial playlists
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY=No editorial playlists available

# Russian  
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS=Подборки
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_ERROR=Ошибка загрузки подборок
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY=Нет доступных подборок
```

## Integration Points

### Existing Components Used

1. **Multi-account system**: `_get_api_client($client)` for per-user API clients
2. **Image handling**: `Plugins::Zvuk::API->getImageUrl()` for image URLs
3. **Playlist viewing**: Existing `handlePlaylist` for track display
4. **Error handling**: Existing `_graphql` error management
5. **Caching**: Existing cache system for metadata

### New Dependencies

None - uses only existing infrastructure

## Testing Strategy

### Manual Testing

1. **Menu Display:**
   - Verify "Подборки" appears in root menu
   - Check correct icon and positioning
   - Test with multiple accounts

2. **Functionality:**
   - Click "Подборки" → verify playlist list loads
   - Click individual playlist → verify tracks display
   - Test with empty/no-token scenarios

3. **Error Handling:**
   - Test with invalid auth token
   - Test with network errors (mock offline)
   - Test with empty editorial playlists

### Integration Testing

1. **Multi-account:** Verify playlists are per-user
2. **Cache:** Verify metadata caching works correctly
3. **Existing features:** Verify "Рекомендации" still works
4. **Performance:** Measure load time for 50+ playlists

## Success Criteria

1. ✅ "Подборки" menu item visible and functional
2. ✅ Editorial playlists load without WAF blocks
3. ✅ All playlists clickable with track navigation
4. ✅ Error handling graceful (no menu crashes)
5. ✅ Multi-account support working
6. ✅ Localization complete (EN/RU)
7. ✅ Existing "Рекомендации" unaffected
8. ✅ Performance acceptable (< 2 seconds for full load)

## Future Enhancements

Out of scope for this implementation:

1. **Genre categorization:** Sub-folders for Rock, Pop, Jazz, etc.
2. **Playlist search:** Search within editorial playlists
3. **Favorites:** Add editorial playlists to user favorites
4. **More grid endpoints:** Additional grid content types beyond editorial_playlist

## Implementation Notes

- **WAF Safety:** Grid API uses simple GET requests, no problematic pagination
- **Performance:** Lightweight metadata queries without track details
- **Compatibility:** Follows existing LMS-Zvuk patterns and conventions
- **Maintainability:** Clean separation of concerns, minimal code changes

## References

- MA Provider implementation: `/home/chernysh/Projects/ma-provider-zvuk-music/provider/provider.py:429,781`
- zvuk-music library: `/home/chernysh/Projects/zvuk-music/zvuk_music/client_async.py:811`
- COMPARISON_REPORT.md: Section on editorial playlists vs dynamicBlock
