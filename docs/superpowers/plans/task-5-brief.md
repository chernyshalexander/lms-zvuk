# Task 5: Comprehensive Testing

**Where this fits:** Fifth of 6 tasks. Tasks 1-4 complete (API, handler, menu, strings). This task adds advanced test cases covering edge cases and integration scenarios.

**What to build:**
Expand t/personalized_playlists.t with 5+ additional test cases covering:

**New Test Cases Required:**

1. **Test: Handler with null/undefined result**
   - Verify handler correctly handles undefined result
   - Should show empty message

2. **Test: Handler with large playlist list**
   - Use 10+ mock playlists
   - Verify all are rendered

3. **Test: Playlist rendering uses correct fields**
   - Verify _renderPlaylist receives correct data
   - Check that id, title, description are present

4. **Test: Pagination/caching behavior**
   - Verify DYNAMIC_TTL is used (already tested but reinforce)
   - Verify no duplicate requests

5. **Test: Error classification**
   - Verify different error types are handled:
     - HTTP error (code != 0)
     - Network timeout (error contains "timeout")
     - GraphQL error (error contains "GraphQL")

6. **Test: Localization keys exist**
   - Verify cstring() calls work with new keys
   - Test both error and empty message strings

**Implementation specifics:**
- Keep existing 21 tests
- Add 6+ new tests (minimum 5 required)
- All tests must pass
- Use proper mocking/isolation
- No breaking changes

**Testing approach:**
- Use mock API with override pattern (established in earlier tasks)
- Use cstring() mocking if needed
- Cover both success and failure paths
- Test edge cases: null, empty, large lists

**Follow TDD:**
1. Write failing tests first
2. Run to confirm they fail (or some fail)
3. Implement minimal code to make tests pass
4. Run all tests to verify pass
5. Commit with "test: Add comprehensive Personalized Playlists tests"

**Commit message:** `test: Add comprehensive Personalized Playlists tests`

**Expected test count:** 27+ total (21 current + 6 new minimum)

