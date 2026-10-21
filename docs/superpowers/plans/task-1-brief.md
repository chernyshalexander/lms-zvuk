# Task 1: Add getSynthesisPlaylists GraphQL Operation

**Where this fits:** First of 6 tasks to implement "Плейлисты для вас" (For You personalized recommendations). This task creates the API foundation that later tasks depend on.

**What to build:**
1. Create `t/personalized_playlists.t` with unit tests for the API operation
2. Add `getSynthesisPlaylists($self, $cb)` method to `API/Async.pm`
3. Method fetches Zvuk synthesis playlists (IDs: 3, 4, 6, 11, 12, 13, 14, 15)
4. Returns GraphQL query result via callback
5. Use DYNAMIC_TTL (1 hour) for caching

**Test cases (4 assertions minimum):**
- Test that getSynthesisPlaylists calls _graphql with correct operation name
- Test that query is defined and valid
- Test that callback receives array result
- Test that result contains correct number of playlists (use 2 mock playlists)

**Implementation specifics:**
- Synthesis playlist IDs are hardcoded: [3, 4, 6, 11, 12, 13, 14, 15]
- GraphQL operation name: `getSynthesisPlaylists`
- Return fields: id, title, description, playlistId, release { image { pic: pictureXBig } }, trackCount
- Caching: handled automatically by _graphql() via DYNAMIC_TTL

**Follow TDD exactly:**
1. Write failing test first (Step 1)
2. Run test to confirm it fails (Step 2)
3. Implement getSynthesisPlaylists method (Step 3)
4. Run test to confirm it passes (Step 4)
5. Commit with message starting with "feat: " (Step 5)

**Critical:** All 4 tests must pass before commit. No merging until green.
