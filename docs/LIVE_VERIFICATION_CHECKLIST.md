# Live LMS Environment Verification Checklist

## Pre-Flight Checks
- [ ] LMS server running and accessible
- [ ] Zvuk plugin enabled in LMS settings
- [ ] Valid Zvuk account credentials configured
- [ ] Plugin loaded without errors in LMS logs

## UI Verification

### 1. Menu Structure
- [ ] Navigate to Plugins → Zvuk in LMS web interface
- [ ] Verify "Подборки" (Editorial Playlists) menu item appears
- [ ] Confirm menu item position (after "Рекомендации" section)
- [ ] Check menu item displays correct localized name

### 2. Editorial Playlists Loading
- [ ] Click "Подборки" menu item
- [ ] Verify loading indicator appears (async loading)
- [ ] Confirm playlist list loads within reasonable time (<5 seconds)
- [ ] Check for error messages if API fails

### 3. Playlist Display
- [ ] Verify individual playlists display with:
  - [ ] Playlist title
  - [ ] Cover image/thumbnail
  - [ ] Track count (if available)
- [ ] Check playlist formatting matches other plugin lists
- [ ] Verify proper URL passthrough for playback

### 4. Error Handling
- [ ] Test with expired/invalid Zvuk token
- [ ] Verify user-friendly error message displays
- [ ] Check error doesn't crash plugin or LMS
- [ ] Confirm graceful degradation (empty list message)

### 5. Multi-Account Support
- [ ] If using multiple Zvuk accounts, test account switching
- [ ] Verify editorial playlists load for each account
- [ ] Check account-specific content displays correctly

### 6. UI Skin Compatibility
- [ ] Test with Default LMS skin
- [ ] Test with Material skin (if available)
- [ ] Test with mobile UI (if applicable)
- [ ] Verify responsive layout on different screen sizes

## Performance Verification

### 1. API Performance
- [ ] Measure Grid API response time (should be <2 seconds)
- [ ] Check memory usage during playlist loading
- [ ] Verify no memory leaks with repeated navigation
- [ ] Monitor concurrent request handling

### 2. Caching Behavior
- [ ] Check if playlists are cached appropriately
- [ ] Verify cache invalidation works correctly
- [ ] Test with different accounts (should not cross-contaminate)

## Integration Verification

### 1. Playback Integration
- [ ] Click playlist and verify track list loads
- [ ] Select track and verify playback starts
- [ ] Check track metadata displays correctly
- [ ] Verify seek functionality works

### 2. Existing Features
- [ ] Verify "Рекомендации" still works (unchanged)
- [ ] Check search functionality still works
- [ ] Verify other plugin features unaffected
- [ ] Check plugin settings page unchanged

## Log Monitoring

### 1. LMS Logs
- [ ] Check LMS error.log for plugin errors
- [ ] Verify no Perl warnings or syntax errors
- [ ] Check for API timeout messages
- [ ] Monitor memory usage patterns

### 2. Debug Output
- [ ] Enable plugin debug mode (if available)
- [ ] Verify Grid API requests are logged
- [ ] Check GraphQL metadata requests are logged
- [ ] Verify async callback handling is clean

## Regression Testing

### 1. Previous Functionality
- [ ] Test all existing plugin features work
- [ ] Verify no breaking changes to other features
- [ ] Check plugin loading time hasn't increased significantly
- [ ] Test with different LMS configurations

### 2. Cross-Feature Interaction
- [ ] Navigate between "Подборки" and "Рекомендации"
- [ ] Verify both features work independently
- [ ] Check no state pollution between features
- [ ] Test concurrent usage scenarios

## Edge Cases

### 1. Empty States
- [ ] Test with empty editorial playlists (if API returns empty)
- [ ] Verify user-friendly empty state message
- [ ] Check no crashes or errors on empty results

### 2. Network Issues
- [ ] Test with intermittent network connectivity
- [ ] Verify graceful handling of API failures
- [ ] Check retry logic works correctly
- [ ] Verify user gets meaningful error messages

### 3. Large Data Sets
- [ ] Test with large number of editorial playlists (50+)
- [ ] Verify pagination or scrolling works
- [ ] Check performance with large playlist metadata
- [ ] Monitor memory usage with large datasets

## Final Sign-Off

### Ready for Production
- [ ] All critical tests passed
- [ ] No blocking issues found
- [ ] Performance acceptable
- [ ] User experience validated
- [ ] Documentation complete

### Known Issues
- [ ] Document any non-critical issues found
- [ ] Note any workarounds or limitations
- [ ] Create follow-up tasks for improvements

### Post-Deployment
- [ ] Monitor production logs for issues
- [ ] Gather user feedback
- [ ] Track API performance metrics
- [ ] Plan future improvements based on usage
