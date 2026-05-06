#!/bin/bash
# Тест Zvuk API с browser-like заголовками
# Сервис блокирует запросы без правильного User-Agent/Origin

TOKEN="${ZVUK_TOKEN:?'ZVUK_TOKEN environment variable is required'}"
GQL_URL="https://zvuk.com/api/v1/graphql"
PROFILE_URL="https://zvuk.com/api/tiny/profile"

# Заголовки, имитирующие браузер
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
ORIGIN="https://zvuk.com"
REFERER="https://zvuk.com/"

echo "=== Zvuk API Test Suite ==="
echo "Token: ${TOKEN:0:8}..."
echo ""

# ---- 1. Профиль пользователя ----
echo "--- [1] GET profile ---"
curl -s "$PROFILE_URL" \
  -H "X-Auth-Token: $TOKEN" \
  -H "User-Agent: $UA" \
  -H "Origin: $ORIGIN" \
  -H "Referer: $REFERER" \
  -H "Accept: application/json" \
  | python3 -m json.tool 2>/dev/null || echo "(non-JSON response or blocked)"
echo ""

# ---- 2. quickSearch ----
echo "--- [2] quickSearch: 'Кино' ---"
curl -s -X POST "$GQL_URL" \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: $TOKEN" \
  -H "User-Agent: $UA" \
  -H "Origin: $ORIGIN" \
  -H "Referer: $REFERER" \
  -d '{
    "operationName": "getSearch",
    "variables": { "query": "Кино", "limit": 5 },
    "query": "query getSearch($query: String, $limit: Int, $searchSessionId: String) { quickSearch(query: $query, limit: $limit, searchSessionId: $searchSessionId) { searchSessionId content { __typename ... on Track { id title artistTemplate availability release { image { src } } } ... on Artist { id title image { src } } ... on Release { id title date artistTemplate image { src } } ... on Playlist { id title isPublic image { src } } } } }"
  }' | python3 -m json.tool 2>/dev/null || echo "(non-JSON response or blocked)"
echo ""

# ---- 3. getStream для конкретного трека ----
TRACK_ID="${1:-}"
if [ -n "$TRACK_ID" ]; then
  echo "--- [3] getStream: track $TRACK_ID ---"
  curl -s -X POST "$GQL_URL" \
    -H "Content-Type: application/json" \
    -H "X-Auth-Token: $TOKEN" \
    -H "User-Agent: $UA" \
    -H "Origin: $ORIGIN" \
    -H "Referer: $REFERER" \
    -d "{
      \"operationName\": \"getStream\",
      \"variables\": { \"ids\": [\"$TRACK_ID\"] },
      \"query\": \"query getStream(\$ids: [ID!]!) { mediaContents(ids: \$ids) { __typename ... on Track { stream { expire expireDelta flacdrm high mid } } } }\"
    }" | python3 -m json.tool 2>/dev/null || echo "(non-JSON response or blocked)"
  echo ""

  echo "--- [4] getFullTrack: $TRACK_ID ---"
  curl -s -X POST "$GQL_URL" \
    -H "Content-Type: application/json" \
    -H "X-Auth-Token: $TOKEN" \
    -H "User-Agent: $UA" \
    -H "Origin: $ORIGIN" \
    -H "Referer: $REFERER" \
    -d "{
      \"operationName\": \"getFullTrack\",
      \"variables\": { \"ids\": [\"$TRACK_ID\"], \"withReleases\": true, \"withArtists\": true },
      \"query\": \"query getFullTrack(\$ids: [ID!]!, \$withReleases: Boolean = false, \$withArtists: Boolean = false) { getTracks(ids: \$ids) { id title duration availability artistTemplate explicit lyrics hasFlac genres { id name } artists @include(if: \$withArtists) { id title image { src } } release @include(if: \$withReleases) { id title type date image { src } } } }\"
    }" | python3 -m json.tool 2>/dev/null || echo "(non-JSON response or blocked)"
fi

echo ""
echo "=== Usage: $0 [TRACK_ID] ==="
echo "Note: Direct curl may be blocked by WAF. The LMS plugin should work"
echo "      because it sends proper headers from within Slim::Networking::SimpleAsyncHTTP"
