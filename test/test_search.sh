#!/bin/bash
# Тест поиска в Zvuk API с подробным логированием

set -e

TOKEN="${ZVUK_TOKEN:?'ZVUK_TOKEN environment variable is required'}"
GQL_URL="https://zvuk.com/api/v1/graphql"

# Заголовки
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
ORIGIN="https://zvuk.com"
REFERER="https://zvuk.com/"

log() {
    echo "[$(date +'%H:%M:%S')] $*" >&2
}

gql_request() {
    local operation="$1"
    local variables="$2"
    local query="$3"

    log "Sending: $operation with variables: $variables"

    local response=$(curl -s -X POST "$GQL_URL" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Token: $TOKEN" \
        -H "User-Agent: $UA" \
        -H "Origin: $ORIGIN" \
        -H "Referer: $REFERER" \
        -d "{
            \"operationName\": \"$operation\",
            \"variables\": $variables,
            \"query\": \"$query\"
        }")

    if echo "$response" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
        echo "$response"
    else
        log "ERROR: Invalid JSON response"
        echo "$response"
        return 1
    fi
}

echo "=== Zvuk Search Test Suite ==="
echo "Token: ${TOKEN:0:8}..."
echo ""

QUERY="${1:-jazz}"
LIMIT="${2:-10}"

log "Testing search for: '$QUERY' (limit: $LIMIT)"
echo ""

# --- 1. Test quickSearch (current implementation) ---
echo "--- [1] quickSearch (CURRENT) ---"
echo "Endpoint: quickSearch"
echo "Expected: 1 track + 1 artist + 1 album + 1 playlist mixed"
echo ""

QUICK_RESPONSE=$(gql_request "getSearch" \
    "{\"query\": \"$QUERY\", \"first\": $LIMIT}" \
    'query getSearch($query: String, $first: Int) { quickSearch(query: $query, limit: $first) { content { __typename ... on Track { id title artistTemplate } ... on Artist { id title } ... on Release { id title } ... on Playlist { id title } } } }')

echo "Raw Response:"
echo "$QUICK_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$QUICK_RESPONSE"
echo ""

# Parse results
QUICK_RESULTS=$(echo "$QUICK_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'data' in data and 'quickSearch' in data['data']:
        content = data['data']['quickSearch'].get('content', [])
        tracks = [x for x in content if x.get('__typename') == 'Track']
        artists = [x for x in content if x.get('__typename') == 'Artist']
        albums = [x for x in content if x.get('__typename') == 'Release']
        playlists = [x for x in content if x.get('__typename') == 'Playlist']

        print(f'Total items: {len(content)}')
        print(f'  Tracks: {len(tracks)}')
        print(f'  Artists: {len(artists)}')
        print(f'  Albums: {len(albums)}')
        print(f'  Playlists: {len(playlists)}')

        if tracks:
            print(f'\\nFirst track: {tracks[0].get(\"title\", \"N/A\")}')
        if artists:
            print(f'First artist: {artists[0].get(\"title\", \"N/A\")}')
    else:
        print('ERROR: No quickSearch data in response')
        if 'errors' in data:
            print('API Errors:', json.dumps(data['errors'], indent=2))
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null || echo "Failed to parse response")

echo "$QUICK_RESULTS"
echo ""

# --- 2. Test full search by type (what we should use) ---
echo "--- [2] Full Track Search ---"

TRACK_RESPONSE=$(gql_request "getSearchTracks" \
    "{\"query\": \"$QUERY\", \"first\": 10, \"offset\": 0}" \
    'query getSearchTracks($query: String, $first: Int, $offset: Int) { searchTracks(query: $query, first: $first, offset: $offset) { total items { id title artistTemplate duration availability } } }')

echo "Raw Response:"
echo "$TRACK_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$TRACK_RESPONSE"
echo ""

TRACK_RESULTS=$(echo "$TRACK_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'data' in data and 'searchTracks' in data['data']:
        search_data = data['data']['searchTracks']
        items = search_data.get('items', [])
        total = search_data.get('total', 0)

        print(f'Total tracks available: {total}')
        print(f'Returned in this batch: {len(items)}')

        for i, track in enumerate(items[:3], 1):
            print(f'  {i}. {track.get(\"title\", \"N/A\")} - {track.get(\"artistTemplate\", \"N/A\")}')
    else:
        print('ERROR: No searchTracks data')
        if 'errors' in data:
            print('API Errors:', json.dumps(data['errors'], indent=2))
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null || echo "Failed to parse")

echo "$TRACK_RESULTS"
echo ""

# --- 3. Test Artist Search ---
echo "--- [3] Full Artist Search ---"

ARTIST_RESPONSE=$(gql_request "getSearchArtists" \
    "{\"query\": \"$QUERY\", \"first\": 10, \"offset\": 0}" \
    'query getSearchArtists($query: String, $first: Int, $offset: Int) { searchArtists(query: $query, first: $first, offset: $offset) { total items { id title image { src } } } }')

echo "Raw Response:"
echo "$ARTIST_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$ARTIST_RESPONSE"
echo ""

ARTIST_RESULTS=$(echo "$ARTIST_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'data' in data and 'searchArtists' in data['data']:
        search_data = data['data']['searchArtists']
        items = search_data.get('items', [])
        total = search_data.get('total', 0)

        print(f'Total artists available: {total}')
        print(f'Returned in this batch: {len(items)}')

        for i, artist in enumerate(items[:3], 1):
            print(f'  {i}. {artist.get(\"title\", \"N/A\")}')
    else:
        print('ERROR: No searchArtists data')
        if 'errors' in data:
            print('API Errors:', json.dumps(data['errors'], indent=2))
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null || echo "Failed to parse")

echo "$ARTIST_RESULTS"
echo ""

# --- 4. Test Release Search ---
echo "--- [4] Full Release (Album) Search ---"

RELEASE_RESPONSE=$(gql_request "getSearchReleases" \
    "{\"query\": \"$QUERY\", \"first\": 10, \"offset\": 0}" \
    'query getSearchReleases($query: String, $first: Int, $offset: Int) { searchReleases(query: $query, first: $first, offset: $offset) { total items { id title artistTemplate type date image { src } } } }')

echo "Raw Response:"
echo "$RELEASE_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RELEASE_RESPONSE"
echo ""

RELEASE_RESULTS=$(echo "$RELEASE_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'data' in data and 'searchReleases' in data['data']:
        search_data = data['data']['searchReleases']
        items = search_data.get('items', [])
        total = search_data.get('total', 0)

        print(f'Total releases available: {total}')
        print(f'Returned in this batch: {len(items)}')

        for i, release in enumerate(items[:3], 1):
            print(f'  {i}. {release.get(\"title\", \"N/A\")} ({release.get(\"type\", \"N/A\")})')
    else:
        print('ERROR: No searchReleases data')
        if 'errors' in data:
            print('API Errors:', json.dumps(data['errors'], indent=2))
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null || echo "Failed to parse")

echo "$RELEASE_RESULTS"
echo ""

# --- 5. Test Playlist Search ---
echo "--- [5] Full Playlist Search ---"

PLAYLIST_RESPONSE=$(gql_request "getSearchPlaylists" \
    "{\"query\": \"$QUERY\", \"first\": 10, \"offset\": 0}" \
    'query getSearchPlaylists($query: String, $first: Int, $offset: Int) { searchPlaylists(query: $query, first: $first, offset: $offset) { total items { id title image { src } } } }')

echo "Raw Response:"
echo "$PLAYLIST_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$PLAYLIST_RESPONSE"
echo ""

PLAYLIST_RESULTS=$(echo "$PLAYLIST_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'data' in data and 'searchPlaylists' in data['data']:
        search_data = data['data']['searchPlaylists']
        items = search_data.get('items', [])
        total = search_data.get('total', 0)

        print(f'Total playlists available: {total}')
        print(f'Returned in this batch: {len(items)}')

        for i, playlist in enumerate(items[:3], 1):
            print(f'  {i}. {playlist.get(\"title\", \"N/A\")}')
    else:
        print('ERROR: No searchPlaylists data')
        if 'errors' in data:
            print('API Errors:', json.dumps(data['errors'], indent=2))
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null || echo "Failed to parse")

echo "$PLAYLIST_RESULTS"
echo ""

echo "=== Summary ==="
echo "Usage: $0 [QUERY] [LIMIT]"
echo "Default: $0 jazz 10"
echo ""
echo "Findings:"
echo "- quickSearch returns limited mixed results (max ~4 items total)"
echo "- Full search methods return paginated results with total count"
echo "- Need to implement categorized search UI with separate search methods"
