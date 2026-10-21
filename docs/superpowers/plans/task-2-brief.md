# Task 2: Add Menu Handler (handlePersonalizedPlaylists)

**Where this fits:** Second of 6 tasks. Task 1 (API operation) is complete. This task creates the menu handler that uses the API to fetch and render personalized playlists.

**What to build:**
1. Add `handlePersonalizedPlaylists($client, $cb)` method to Plugin.pm
2. Method fetches synthesis playlists via `$api->getSynthesisPlaylists()`
3. Renders playlists as menu items using existing `_renderPlaylist()` helper
4. Handles three cases: success (render playlists), error (show error message), empty (show no results message)
5. Add unit tests to t/personalized_playlists.t

**Handler behavior (three paths):**

**Path 1 - Success:**
- Get API client via `_get_api_client($client)`
- Call `$api->getSynthesisPlaylists(sub { ... })`
- If result has no error: map playlists through `_renderPlaylist()`, return items array

**Path 2 - API Error:**
- If `$result->{error}` is set: return single menu item with error message via cstring()
- Log error: `$log->error("Personalized Playlists API error: ...")`

**Path 3 - Empty Result:**
- If playlists array is empty: return single menu item with "no results" message via cstring()

**Test cases (add to t/personalized_playlists.t):**
1. Test handler calls getSynthesisPlaylists via API
2. Test handler renders playlists when successful (use 2 mock playlists)
3. Test handler shows error message on API error
4. Test handler shows empty message when no playlists

**Error message localization keys** (will be added in Task 4):
- `PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR` — shown on API error
- `PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY` — shown when no results

**Implementation notes:**
- Use existing `_get_api_client()` pattern (used in other handlers)
- Use existing `_renderPlaylist()` pattern (used for other playlists)
- Callback signature: sub { my $result = shift; ... }
- Result structure: `{ error => '...', code => HTTP_CODE }` OR array of playlists

**Follow TDD exactly:**
1. Add test cases first (3 tests minimum)
2. Run tests to confirm they fail
3. Implement handlePersonalizedPlaylists
4. Run tests to confirm they pass
5. Commit with "feat: Add handlePersonalizedPlaylists menu handler"

**Critical:** No breaking changes. Use existing patterns only.
