# Zvuk Search Testing Guide

## Problem

Current implementation uses `quickSearch` which returns very limited mixed results (~2-4 items total across all types).

Example: searching "jazz" returns only 1-2 strange/unrelated items instead of full search results.

## Root Cause

The `quickSearch` GraphQL endpoint is designed for quick type-ahead/autocomplete, not full search results. It mixes all types (tracks, artists, albums, playlists) and limits results heavily.

## Solution

Implemented categorized search with separate API methods:
- `searchTracks` - returns tracks with pagination (total count)
- `searchArtists` - returns artists with pagination (total count)  
- `searchReleases` - returns albums with pagination (total count)
- `searchPlaylists` - returns playlists with pagination (total count)

## Testing

### Option 1: Test GraphQL API directly

```bash
# Requires ZVUK_TOKEN environment variable
export ZVUK_TOKEN="your_32_char_token_here"

# Run comprehensive search test
./test/test_search.sh jazz

# Test different query
./test/test_search.sh "Pink Floyd" 

# Test with custom limit
./test/test_search.sh "Rolling Stones" 20
```

This tests:
1. **Current implementation** (`quickSearch`) - shows why it's limited
2. **searchTracks** - full track results with pagination
3. **searchArtists** - full artist results with pagination
4. **searchReleases** - full album results with pagination  
5. **searchPlaylists** - full playlist results with pagination

### Option 2: Test through LMS Web UI

1. Start LMS server
2. Navigate to: **Plugins > Zvuk Music**
3. See new menu structure:
   ```
   Search
   ├─ Tracks     <- search by track name
   ├─ Artists    <- search by artist name
   ├─ Albums     <- search by album title
   └─ Playlists  <- search by playlist name
   ```
4. Click on category and enter search query (e.g., "jazz")
5. Should see full results with pagination "Load More" button if more exist

## What changed

### Plugin.pm
- Updated main menu to show categorized Search sub-menu
- Added `searchTracks()`, `searchArtists()`, `searchAlbums()`, `searchPlaylists()` handlers
- Each handler displays full paginated results for that category
- Added logging for debugging

### API/Async.pm
- Added 4 new GraphQL search methods with full results
- Each returns: `{ total, items: [...] }`
- Proper pagination support (limit + offset)
- Cached with DYNAMIC_TTL (1 hour)

### strings.txt
- Already contains translations for:
  - `PLUGIN_ZVUK_SEARCH_TRACKS`
  - `PLUGIN_ZVUK_SEARCH_ARTISTS`
  - `PLUGIN_ZVUK_SEARCH_ALBUMS`
  - `PLUGIN_ZVUK_SEARCH_PLAYLISTS`

## Logging Output

When testing through LMS, check logs:

```bash
tail -f ~/.squeezebox/cache/log/server.log | grep -i zvuk
```

Expected output for search "jazz":
```
[plugin.zvuk] Searching Zvuk for: jazz
[plugin.zvuk] searchTracks: query='jazz', limit=50, offset=0
[plugin.zvuk] Zvuk search: query='jazz', limit=50 (using quickSearch)
[plugin.zvuk] Search breakdown - Tracks: 1, Artists: 1, Albums: 1, Playlists: 0
[plugin.zvuk] Search results: 4 items returned
```

vs. with new categorized search:

```
[plugin.zvuk] Searching Zvuk tracks for: jazz (offset: 0)
[plugin.zvuk] searchTracks: query='jazz', limit=50, offset=0
[plugin.zvuk] Track search results: 342 total, 50 in this batch
```

## Implementation Details

### GraphQL Queries

Each search method uses full-featured GraphQL query:

```graphql
query searchTracks($query: String, $first: Int, $offset: Int) {
  searchTracks(query: $query, first: $first, offset: $offset) {
    total          # Total results available (for pagination)
    items {        # Items in this batch
      id
      title
      duration
      availability
      artistTemplate
      release { title image { src } }
    }
  }
}
```

### Cache TTL

All search methods use `DYNAMIC_TTL` (1 hour):
- User searches may return different results over time
- Caching for 1 hour prevents repeated API hits for same query
- Controlled by: `_getCacheTTL('searchTracks')` etc.

### No cache for stream URLs

Important: Stream URLs (from `getStream`) are NOT cached:
- They have time-limited validity
- Requests use `nocache => 1`

## Known Issues & TODOs

1. **Global search integration** - Currently uses old `search()` method
   - Need to update `_globalSearchItems()` to use categorized methods
   - But global search may want mixed results (1 track + 1 artist + 1 album)
   - Decision: Keep `search()` for global, use categorized for full search menu

2. **Search history** - Not implemented
   - Could cache recent searches for quick access
   - Low priority

3. **Advanced filters** - Not implemented
   - Could add: year range, genre, etc.
   - Zvuk API may not support these
   - Low priority

## Troubleshooting

### "2 strange items" problem

If still seeing only 2-4 items:

1. Check that menu shows categorized search (Tracks/Artists/Albums/Playlists)
2. If menu still shows single "Search" button, Plugin.pm changes didn't load
   - Restart LMS: `sudo systemctl restart slimserver`
   
3. Check logs for API errors:
   ```bash
   grep -i "error\|searchTracks" ~/.squeezebox/cache/log/server.log
   ```

4. Test API directly with curl:
   ```bash
   export ZVUK_TOKEN="your_token"
   ./test/test_search.sh jazz
   ```
   
   If curl test fails:
   - Token may be invalid or expired
   - WAF may be blocking requests (check IP)
   - Try from same IP as LMS server

### Cache issues

If results seem stale:

```bash
# Clear Slim cache
rm ~/.squeezebox/cache/zvuk_*

# Restart LMS
sudo systemctl restart slimserver
```

## References

- Zvuk GraphQL API: https://zvuk.com/api/v1/graphql
- Previous implementation: Music Assistant Server (MAS) uses full search in Python client
- LMS plugin patterns: Deezer, Tidal, Qobuz plugins use similar pagination
