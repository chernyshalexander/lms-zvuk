# Zvuk Cache Management

## Clear Cache Script

The `clear_cache.pl` script allows you to clear Zvuk plugin cache entries.

### Usage

```bash
# Clear only GraphQL query cache (fastest, recommended for testing)
cd /home/chernysh/Projects/lms-zvuk
perl clear_cache.pl

# Clear all Zvuk cache including metadata
perl clear_cache.pl --all
```

### What Gets Cleared

#### Without `--all` (default)
- **GraphQL query cache** (`zvuk_gql:*`)
- Collection data (albums, artists, tracks, podcasts)
- Artist/album details
- Podcast episodes
- Search results
- TTL: 5 minutes for user content, 1 hour for dynamic data, 24 hours for static data

#### With `--all`
- Everything above, plus:
- **Track metadata cache** (`zvuk_meta_*`) - used for playback duration/info
- TTL: 24 hours

### When to Clear Cache

1. **Testing new features:** Clear before and after code changes
2. **After API changes:** If Zvuk API structure changed
3. **Stale data:** If My Music shows outdated albums/artists
4. **Debug:** If you suspect caching issues

### Cache Structure

```
zvuk_gql:{userId}:{operationName}:{variablesHash}
  └─ GraphQL query results with TTL
  
zvuk_meta_{trackId}
  └─ Track metadata (duration, bitrate, etc.) with TTL
```

### Notes

- The cache is stored in SQLite and persists across LMS restarts
- Cache keys include user ID, so different accounts have separate caches
- Variables hash ensures different parameters create different cache entries
- After clearing, the next query will fetch fresh data from the API
