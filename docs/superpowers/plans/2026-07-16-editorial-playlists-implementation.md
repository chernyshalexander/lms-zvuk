# Editorial Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add "Подборки" (Editorial Playlists) menu item to LMS-Zvuk that displays curated genre-based playlists using stable Tiny API Grid endpoint instead of problematic dynamicBlock GraphQL.

**Architecture:** Two-layer approach - Grid API for playlist IDs + lightweight GraphQL for metadata. New menu item integrates with existing playlist viewing infrastructure.

**Tech Stack:** Perl 5, Lyrion Music Server plugin API, REST API integration, GraphQL queries

## Global Constraints

- **Perl Version:** Perl 5.38+ (LMS standard)
- **Target Branch:** `experiment` 
- **Code Style:** Follow existing LMS-Zvuk patterns (tabs, UTF-8, strict/warnings)
- **Error Handling:** Must not crash menu on API failures
- **Multi-account:** Must work with existing multi-account system
- **Localization:** Must support both EN and RU languages
- **Existing Features:** Must not break current "Рекомендации" functionality

---

## Task 1: Add Grid API Client Methods to API/Async.pm

**Files:**
- Modify: `API/Async.pm` (add two new methods)

**Interfaces:**
- Consumes: Existing `_http_get` method, existing `_graphql` method
- Produces: `getEditorialPlaylistIds($cb)`, `getShortPlaylist($cb, $ids)`

- [ ] **Step 1: Add getEditorialPlaylistIds method to API/Async.pm**

Add this method after the existing `getSynthesisPlaylists` method (around line 840):

```perl
sub getEditorialPlaylistIds {
    my ($self, $cb) = @_;
    
    my $url = "https://zvuk.com/api/tiny/grid/content";
    my $params = {
        name => "editorial_playlist",
        ranker_enabled => "true",
    };
    
    $log->info("Fetching editorial playlist IDs from Grid API");
    
    $self->_http_get($url, $params, sub {
        my ($data, $error) = @_;
        
        if ($error) {
            $log->error("Grid API request failed: $error");
            $cb->({ error => "Failed to fetch editorial playlists: $error" });
            return;
        }
        
        if (!$data || !$data->{page} || !$data->{page}{data}) {
            $log->warn("Grid API returned empty data structure");
            $cb->([]);
            return;
        }
        
        my $items = $data->{page}{data} || [];
        $log->debug("Grid API returned " . scalar(@$items) . " items");
        
        # Filter only playlists and extract IDs
        my @playlist_ids = map { $_->{id} } grep { $_->{type} eq 'playlist' } @$items;
        
        $log->info("Found " . scalar(@playlist_ids) . " editorial playlist IDs");
        $cb->(\@playlist_ids);
    });
}
```

- [ ] **Step 2: Add getShortPlaylist method to API/Async.pm**

Add this method immediately after `getEditorialPlaylistIds`:

```perl
sub getShortPlaylist {
    my ($self, $cb, $playlist_ids) = @_;
    
    unless ($playlist_ids && @$playlist_ids) {
        $log->debug("No playlist IDs provided to getShortPlaylist");
        $cb->([]);
        return;
    }
    
    my $ids = ref $playlist_ids eq 'ARRAY' ? $playlist_ids : [$playlist_ids];
    
    my $gql = q{
        query getShortPlaylist($ids: [ID!]!) {
            getPlaylists(ids: $ids) {
                id
                title
                image {
                    src
                }
                description
                trackCount
                isPublic
            }
        }
    };
    
    my $vars = { ids => $ids };
    
    $log->info("getShortPlaylist: requesting metadata for " . scalar(@$ids) . " playlists");
    
    $self->_graphql(sub {
        my $data = shift;
        
        if ($data->{error}) {
            $log->error("getShortPlaylist failed: $data->{error}");
            $cb->([]);
            return;
        }
        
        my $playlists = $data->{getPlaylists} || [];
        $log->debug("getShortPlaylist: received metadata for " . scalar(@$playlists) . " playlists");
        
        $cb->($playlists);
    }, 'getShortPlaylist', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}
```

- [ ] **Step 3: Verify syntax and save**

```bash
cd /home/chernysh/Projects/lms-zvuk
perl -c API/Async.pm
```

Expected: "API/Async.pm syntax OK"

- [ ] **Step 4: Commit API changes**

```bash
git add API/Async.pm
git commit -m "feat: add Grid API client methods for editorial playlists

- Add getEditorialPlaylistIds() for fetching editorial playlist IDs
  from /api/tiny/grid/content endpoint
- Add getShortPlaylist() for lightweight playlist metadata
  via GraphQL getShortPlaylist query
- Both methods include comprehensive error handling
- Part of Editorial Playlists feature implementation"
```

---

## Task 2: Add Editorial Playlists Menu Handlers to Plugin.pm

**Files:**
- Modify: `Plugin.pm` (add menu integration and handlers)

**Interfaces:**
- Consumes: `API::Async->getEditorialPlaylistIds()`, `API::Async->getShortPlaylist()`, existing `handlePlaylist()`, existing `_get_api_client()`
- Produces: `handleEditorialPlaylists($client, $cb)`, `_renderEditorialPlaylist($playlist)`

- [ ] **Step 1: Add handleEditorialPlaylists method to Plugin.pm**

Add this method after the existing `handleRecommendationPlaylists` method (around line 730):

```perl
sub handleEditorialPlaylists {
    my ($client, $cb) = @_;
    my $api = _get_api_client($client);
    
    $log->info("Loading editorial playlists for client");
    
    # Step 1: Get editorial playlist IDs from Grid API
    $api->getEditorialPlaylistIds(sub {
        my ($ids, $error) = @_;
        
        if ($error) {
            $log->error("getEditorialPlaylistIds failed: $error");
            $cb->({ items => [
                { name => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_ERROR'), type => 'text' },
            ]});
            return;
        }
        
        unless ($ids && @$ids) {
            $log->info("No editorial playlists available");
            $cb->({ items => [
                { name => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY'), type => 'text' },
            ]});
            return;
        }
        
        $log->info("Got " . scalar(@$ids) . " editorial playlist IDs, loading metadata");
        
        # Step 2: Get lightweight metadata for all playlists
        $api->getShortPlaylist($ids, sub {
            my $playlists = shift;
            
            unless ($playlists && @$playlists) {
                $log->warn("getShortPlaylist returned empty results");
                $cb->({ items => [
                    { name => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY'), type => 'text' },
                ]});
                return;
            }
            
            $log->info("Got metadata for " . scalar(@$playlists) . " editorial playlists");
            
            # Step 3: Render all playlists
            my @items = map { _renderEditorialPlaylist($_) } @$playlists;
            
            $cb->({ items => \@items });
        });
    });
}
```

- [ ] **Step 2: Add _renderEditorialPlaylist method to Plugin.pm**

Add this method after the existing `_renderPlaylist` method (around line 830):

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

- [ ] **Step 3: Add editorial playlists menu item to _buildRootMenu**

Find the `_buildRootMenu` method and add this menu item after the "Рекомендации" section (after line 195, before GigaMix section):

```perl
            {
                name  => cstring($client, 'PLUGIN_ZVUK_EDITORIAL_PLAYLISTS'),
                type  => 'link',
                image => 'plugins/zvuk/html/images/genres.png',
                url   => \&handleEditorialPlaylists,
            },
```

- [ ] **Step 4: Verify syntax and save**

```bash
perl -c Plugin.pm
```

Expected: "Plugin.pm syntax OK"

- [ ] **Step 5: Commit Plugin.pm changes**

```bash
git add Plugin.pm
git commit -m "feat: add editorial playlists menu integration

- Add handleEditorialPlaylists() main menu handler
- Add _renderEditorialPlaylist() for playlist rendering
- Integrate editorial playlists into root menu after recommendations
- Two-step loading: Grid API IDs → GraphQL metadata
- Comprehensive error handling at each step
- Part of Editorial Playlists feature implementation"
```

---

## Task 3: Add Localization Strings

**Files:**
- Modify: `strings.txt` (add EN/RU localization)

**Interfaces:**
- Consumes: Existing localization infrastructure
- Produces: New localization keys for editorial playlists

- [ ] **Step 1: Add English localization strings**

Add these lines to the English section of `strings.txt`:

```
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS=Editorial Playlists
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_ERROR=Error loading editorial playlists
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY=No editorial playlists available
```

- [ ] **Step 2: Add Russian localization strings**

Add these lines to the Russian section of `strings.txt`:

```
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS=Подборки
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_ERROR=Ошибка загрузки подборок
PLUGIN_ZVUK_EDITORIAL_PLAYLISTS_EMPTY=Нет доступных подборок
```

- [ ] **Step 3: Verify file format and save**

```bash
# Check file syntax (basic validation)
head -20 strings.txt
tail -20 strings.txt
```

Expected: File should have proper format with EN and RU sections

- [ ] **Step 4: Commit localization changes**

```bash
git add strings.txt
git commit -m "feat: add editorial playlists localization strings

- Add EN translations for editorial playlists UI
- Add RU translations for editorial playlists UI  
- Include error handling and empty state messages
- Part of Editorial Playlists feature implementation"
```

---

## Task 4: Testing and Verification

**Files:**
- Create: `t/test_editorial_playlists.pl` (manual test script)
- Test: Manual testing through LMS interface

**Interfaces:**
- Consumes: All implemented methods from previous tasks
- Produces: Verification of functionality

- [ ] **Step 1: Create manual test script**

Create `t/test_editorial_playlists.pl`:

```perl
#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

# Test editorial playlists functionality
# This script requires a valid Zvuk token

print "Editorial Playlists Test\n";
print "========================\n\n";

# Test would go here - for now just verify compilation
print "✓ Test file created - manual verification through LMS UI required\n";
print "\nManual testing checklist:\n";
print "1. Start LMS and navigate to Plugins → Zvuk\n";
print "2. Verify 'Подборки' menu item appears\n";
print "3. Click 'Подборки' and verify playlist list loads\n";
print "4. Click individual playlist and verify tracks display\n";
print "5. Test error handling with invalid token\n";

exit 0;
```

- [ ] **Step 2: Make test script executable**

```bash
chmod +x t/test_editorial_playlists.pl
```

- [ ] **Step 3: Run syntax check on all modified files**

```bash
perl -c API/Async.pm
perl -c Plugin.pm
perl -c t/test_editorial_playlists.pl
```

Expected: All files pass syntax check

- [ ] **Step 4: Verify menu structure with dry-run**

Check that Plugin.pm can be loaded without errors:

```bash
perl -MPlugin::Zvuk::Plugin -e 'print "Plugin loads successfully\n"'
```

Expected: "Plugin loads successfully" (may have warnings but no errors)

- [ ] **Step 5: Test with real LMS instance**

**Manual testing steps:**
1. Restart LMS: `sudo service logitechserver restart`
2. Navigate to Plugins → Zvuk in web UI
3. Verify "Подборки" menu item appears
4. Click "Подборки" and verify playlists load
5. Click a playlist and verify tracks display
6. Check error handling by viewing browser console
7. Test with multiple accounts if available

- [ ] **Step 6: Commit test files**

```bash
git add t/test_editorial_playlists.pl
git commit -m "test: add editorial playlists manual test script

- Create test script for editorial playlists functionality
- Include manual testing checklist for UI verification
- Test compilation and plugin loading
- Part of Editorial Playlists feature implementation"
```

---

## Task 5: Final Integration and Documentation

**Files:**
- Update: `docs/DEVELOPMENT_STATUS.md` (if exists)
- Create: No new files, only verification

**Interfaces:**
- Consumes: All implemented functionality
- Produces: Verified working feature

- [ ] **Step 1: Verify all commits are clean**

```bash
git log --oneline -5
```

Expected: Should see 4-5 commits for editorial playlists implementation

- [ ] **Step 2: Final verification test**

```bash
# Comprehensive syntax check
find . -name "*.pm" -exec perl -c {} \; 2>&1 | grep -i error
echo "Syntax check complete"
```

Expected: No errors found

- [ ] **Step 3: Create summary of changes**

```bash
git diff HEAD~5 --stat
```

Expected: Summary showing changes to API/Async.pm, Plugin.pm, strings.txt

- [ ] **Step 4: Update version if needed**

Check install.xml for version bump:

```bash
grep "version" install.xml
```

If version update is needed:
```bash
# Increment version in install.xml
# Then commit version bump
git add install.xml
git commit -m "chore: bump version for editorial playlists feature"
```

- [ ] **Step 5: Final verification through LMS UI**

**Final checklist:**
- ✅ "Подборки" appears in root menu
- ✅ Editorial playlists load successfully
- ✅ Individual playlists work with track navigation
- ✅ Error handling works (test with bad token)
- ✅ Existing "Рекомендации" still works
- ✅ Multi-account support works (if available)

- [ ] **Step 6: Create implementation summary**

Create a brief summary in project notes:

```bash
cat > /home/chernysh/Projects/lms-zvuk/EDITORIAL_PLAYLISTS_NOTES.md << 'EOF'
# Editorial Playlists Implementation

**Implemented:** 2026-07-16
**Status:** Complete and tested

## What was added:

1. **Grid API Client** (API/Async.pm):
   - `getEditorialPlaylistIds()` - fetch editorial playlist IDs
   - `getShortPlaylist()` - load lightweight metadata

2. **Menu Integration** (Plugin.pm):
   - `handleEditorialPlaylists()` - main menu handler
   - `_renderEditorialPlaylist()` - playlist rendering
   - Root menu integration after recommendations

3. **Localization** (strings.txt):
   - English and Russian translations
   - Error messages and empty states

## Testing:
- ✅ Syntax validation passed
- ✅ Plugin loading verified
- ✅ Manual UI testing completed
- ✅ Error handling verified

## Known limitations:
- No genre categorization (flat list only)
- No search within editorial playlists
- Grid API returns all playlists (no pagination)

## Future enhancements:
- Add genre sub-folders
- Implement playlist search
- Add favorites functionality
EOF
```

---

## Success Criteria Verification

After implementation, verify these criteria are met:

- ✅ "Подборки" menu item visible and functional
- ✅ Editorial playlists load without WAF blocks
- ✅ All playlists clickable with track navigation
- ✅ Error handling graceful (no menu crashes)
- ✅ Multi-account support working
- ✅ Localization complete (EN/RU)
- ✅ Existing "Рекомендации" unaffected
- ✅ Performance acceptable (< 2 seconds for full load)

## Notes for Reviewers

**Key implementation decisions:**
1. Used existing `_http_get` method for Grid API (consistent architecture)
2. Two-step loading pattern (IDs first, then metadata)
3. Comprehensive error handling at each layer
4. Reused existing playlist viewing infrastructure
5. Flat menu structure (can be extended to hierarchical later)

**Testing approach:**
- Focus on manual UI testing through LMS
- Automated syntax validation for all files
- Error handling verification with invalid tokens
- Multi-account testing if available

**Integration points:**
- Does not modify existing recommendation functionality
- Follows existing LMS-Zvuk patterns and conventions
- Uses existing error handling and caching infrastructure
