#!/bin/bash

# Clear Zvuk plugin cache from LMS SQLite database
# Usage: ./clear_cache.sh [--all]
#
# Without arguments: clears only Zvuk GraphQL cache (zvuk_gql:*)
# With --all: clears all Zvuk cache including metadata (zvuk_*)

set -e

# Detect LMS cache database location
if [ -f ~/.slimserver-lyrion/cache.db ]; then
    CACHE_DB=~/.slimserver-lyrion/cache.db
elif [ -f ~/.slimserver/cache.db ]; then
    CACHE_DB=~/.slimserver/cache.db
elif [ -f ~/.logitechmediaserver/cache.db ]; then
    CACHE_DB=~/.logitechmediaserver/cache.db
else
    echo "Error: Could not find LMS cache database"
    echo "Checked locations:"
    echo "  ~/.slimserver-lyrion/cache.db"
    echo "  ~/.slimserver/cache.db"
    echo "  ~/.logitechmediaserver/cache.db"
    exit 1
fi

if [ ! -f "$CACHE_DB" ]; then
    echo "Error: Cache database not found at: $CACHE_DB"
    exit 1
fi

# Determine what to clear
if [ "$1" = "--all" ]; then
    PATTERN="zvuk_%"
    MODE="all Zvuk cache (GraphQL + metadata)"
else
    PATTERN="zvuk_gql:%"
    MODE="Zvuk GraphQL cache only"
fi

echo "Clearing $MODE..."
echo "Database: $CACHE_DB"

# Count entries before
BEFORE=$(sqlite3 "$CACHE_DB" "SELECT COUNT(*) FROM cache WHERE key LIKE '$PATTERN'" 2>/dev/null || echo 0)

# Delete entries
sqlite3 "$CACHE_DB" "DELETE FROM cache WHERE key LIKE '$PATTERN'" 2>/dev/null || true

# Count entries after
AFTER=$(sqlite3 "$CACHE_DB" "SELECT COUNT(*) FROM cache WHERE key LIKE '$PATTERN'" 2>/dev/null || echo 0)

REMOVED=$((BEFORE - AFTER))

if [ $REMOVED -gt 0 ]; then
    echo "✓ Cleared $REMOVED cache entries"
    if [ "$1" != "--all" ]; then
        echo "  (Use --all flag to also clear metadata cache)"
    fi
else
    echo "ℹ No cache entries found to clear"
fi

exit 0
