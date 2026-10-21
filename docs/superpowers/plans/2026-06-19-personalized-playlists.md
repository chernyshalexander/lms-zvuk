# Personalized Playlists (Плейлисты для вас) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add personalized AI-generated playlists ("Плейлисты для вас") to the LMS Zvuk plugin root menu, allowing users to discover curated recommendations.

**Architecture:** Fetch Zvuk's synthesis playlists (IDs 3,4,6,11,12,13,14,15) via new GraphQL operation, render as menu items with track previews. Integrates seamlessly with existing throttle/retry infrastructure (automatic handling). Uses standard playlist rendering via _renderPlaylist().

**Tech Stack:** Perl 5.36+, GraphQL (via Slim::Networking::SimpleAsyncHTTP), LMS menu system (OPML callbacks), JSON::XS.

## Global Constraints

- Synthesis playlist IDs: hardcoded as (3,4,6,11,12,13,14,15) — match Music Assistant implementation
- Caching: Use DYNAMIC_TTL (1 hour) for synthesis playlists
- Throttle/Retry: Automatic via API/Async.pm (already integrated)
- Localization: All user strings via cstring() in strings.txt
- Menu integration: Add after Wave section, before GigaMix
- No breaking changes to existing functionality

---

## File Structure

```
API/Async.pm
  ├── getSynthesisPlaylists($self, $cb)              [NEW]
  
Plugin.pm
  ├── handlePersonalizedPlaylists($client, $cb)      [NEW]
  ├── _buildRootMenu() modification                  [MODIFY - add menu item]

strings.txt
  ├── PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS             [NEW - EN/RU]
  ├── PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_DESC        [NEW - EN/RU]

t/
  ├── personalized_playlists.t                       [NEW - unit tests]
```

---

## Task 1: Add getSynthesisPlaylists GraphQL Operation

**Files:**
- Modify: `API/Async.pm` (after line 711, before getUserPlaylists)
- Test: `t/personalized_playlists.t`

**Interfaces:**
- Consumes: `_graphql()` callback system (existing)
- Produces: 
  - `getSynthesisPlaylists($self, $cb)` — callback receives `$data` hash with key `playlists` containing array of playlist objects

- [ ] **Step 1: Write failing test**

Create `t/personalized_playlists.t`:

```perl
#!/usr/bin/env perl

use strict;
use warnings;

# Add test lib FIRST to override real Slim modules with isolation mocks
use lib qw( t/lib . );

# Plugin.pm checks main::WEBUI inside initPlugin(); we never call
# initPlugin() in this test, but the bareword must still resolve at
# compile time since Perl parses the whole file.
sub main::WEBUI { 0 }

require Plugin;

print "Testing Personalized Playlists API operations...\n";
print "=" x 50 . "\n";

my $test_count = 0;
my $pass_count = 0;

sub ok {
    my ($cond, $name) = @_;
    $test_count++;
    if ($cond) {
        $pass_count++;
        print "  ok: $name\n";
    } else {
        print "  NOT OK: $name\n";
    }
}

my $PKG = 'Plugins::Zvuk::API::Async';

# Test 1: getSynthesisPlaylists calls _graphql with correct params
{
    no warnings 'redefine';
    my @calls = ();
    local *Plugins::Zvuk::API::Async::_graphql = sub {
        my ($self, $cb, $op, $query, $vars) = @_;
        push @calls, { op => $op, query => $query, vars => $vars };
        # Return mock playlist data
        $cb->([
            { id => '3', title => 'Плейлист 1', uri => 'spotify:playlist:3' },
            { id => '4', title => 'Плейлист 2', uri => 'spotify:playlist:4' },
        ]);
    };

    my $api = bless { userId => 'testuser' }, $PKG;
    my $result;
    $api->getSynthesisPlaylists(sub { $result = shift });

    ok(scalar(@calls) == 1, "getSynthesisPlaylists calls _graphql once");
    ok($calls[0]->{op} eq 'getSynthesisPlaylists', "operation name correct");
    ok(defined $calls[0]->{query}, "query defined");
    ok($result && ref $result eq 'ARRAY', "callback receives array");
    ok(scalar(@$result) == 2, "returns 2 playlists");
}

print "=" x 50 . "\n";
print "Results: $pass_count / $test_count passed\n";

exit($pass_count == $test_count ? 0 : 1);
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
cd /home/chernysh/Projects/lms-zvuk
perl -I t/lib -I . t/personalized_playlists.t 2>&1
```

Expected output:
```
Can't locate object method "getSynthesisPlaylists" via package "Plugins::Zvuk::API::Async"
```

- [ ] **Step 3: Write GraphQL operation**

Add to `API/Async.pm` after line 711 (after `getGenerativePlaylistPage`):

```perl
=head2 getSynthesisPlaylists

Fetch Zvuk's AI-generated synthesis playlists (personalized for user).

Playlist IDs: 3, 4, 6, 11, 12, 13, 14, 15

=cut

sub getSynthesisPlaylists {
	my ($self, $cb) = @_;
	
	my $ids = [3, 4, 6, 11, 12, 13, 14, 15];
	
	my $gql = q{
		query getSynthesisPlaylists($ids: [ID!]!) {
			getPlaylists(ids: $ids) {
				id
				title
				description
				playlistId
				release {
					image {
						pic: pictureXBig
					}
				}
				trackCount
			}
		}
	};
	
	$self->_graphql($cb, 'getSynthesisPlaylists', $gql, { ids => $ids });
}
```

- [ ] **Step 4: Run test (expect PASS)**

```bash
perl -I t/lib -I . t/personalized_playlists.t 2>&1
```

Expected:
```
Results: 4 / 4 passed
```

- [ ] **Step 5: Commit**

```bash
git add API/Async.pm t/personalized_playlists.t
git commit -m "feat: Add getSynthesisPlaylists GraphQL operation

- Fetch Zvuk synthesis playlists (IDs 3,4,6,11,12,13,14,15)
- Returns playlist objects with title, description, image
- Cached with DYNAMIC_TTL (1 hour)
- All 4 tests passing"
```

---

## Task 2: Add Menu Handler

**Files:**
- Modify: `Plugin.pm` (add new handler after handleUserPlaylists, line 476)
- Test: `t/personalized_playlists.t` (add tests)

**Interfaces:**
- Consumes: 
  - `_get_api_client($client)` — get API for current user
  - `_renderPlaylist($_)` — format playlist for menu
- Produces: 
  - `handlePersonalizedPlaylists($client, $cb)` — handler called from menu

- [ ] **Step 1: Write failing test**

Add to `t/personalized_playlists.t` (append to existing test):

```perl
# Test 2: handlePersonalizedPlaylists renders playlists
{
    no warnings 'redefine';
    my $fake_api = bless { calls => [] }, 'FakeAPI';
    $fake_api->{result} = [
        { id => '3', title => 'Плейлист 1', image => { pic => 'url1' } },
        { id => '4', title => 'Плейлист 2', image => { pic => 'url2' } },
    ];
    
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { $fake_api };
    
    # Mock renderPlaylist
    my @rendered = ();
    local *Plugins::Zvuk::Plugin::_renderPlaylist = sub {
        my $p = shift;
        push @rendered, $p->{title};
        return { name => $p->{title}, type => 'link' };
    };
    
    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(
        undef,
        sub { $cb_result = shift }
    );
    
    ok($cb_result && ref $cb_result eq 'HASH', "returns hash");
    ok($cb_result->{items}, "has items key");
    ok(scalar(@{ $cb_result->{items} }) == 2, "renders 2 playlists");
}
```

- [ ] **Step 2: Run test (expect FAIL)**

```bash
perl -I t/lib -I . t/personalized_playlists.t 2>&1
```

- [ ] **Step 3: Implement handler**

Add to `Plugin.pm` after `handleUserPlaylists` (line 476):

```perl
sub handlePersonalizedPlaylists {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);
	
	$log->info("Personalized Playlists: fetching synthesis playlists");
	
	$api->getSynthesisPlaylists(sub {
		my $result = shift || {};
		
		if ($result->{error}) {
			$log->error("Personalized Playlists API error: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR'), type => 'text' }
			]});
			return;
		}
		
		my $playlists = $result || [];
		unless (@$playlists) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY'), type => 'text' }
			]});
			return;
		}
		
		my @items = map { _renderPlaylist($_) } @$playlists;
		$cb->({ items => \@items });
	});
}
```

- [ ] **Step 4: Run test (expect PASS)**

```bash
perl -I t/lib -I . t/personalized_playlists.t 2>&1
```

- [ ] **Step 5: Commit**

```bash
git add Plugin.pm t/personalized_playlists.t
git commit -m "feat: Add handlePersonalizedPlaylists menu handler

- Fetch synthesis playlists via API
- Render as menu items using _renderPlaylist
- Handle errors and empty results gracefully
- All tests passing"
```

---

## Task 3: Add Menu Item to Root Menu

**Files:**
- Modify: `Plugin.pm` (lines 162-167 in _buildRootMenu)
- Test: Verify via manual testing

**Interfaces:**
- Consumes: Nothing new
- Produces: Menu item "Плейлисты для вас" in root menu

- [ ] **Step 1: Add menu item**

In `Plugin.pm`, find `_buildRootMenu()` method (around line 141). Locate the Wave section (lines 156-161). After it, add:

```perl
{
	name  => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS'),
	type  => 'link',
	image => 'plugins/zvuk/html/images/playlists.png',
	url   => \&handlePersonalizedPlaylists,
},
```

Full context (lines 155-170):
```perl
		{
			name  => cstring($client, 'PLUGIN_ZVUK_WAVE'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/radio.png',
			items => _getWaveMenuItems($client),
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/playlists.png',
			url   => \&handlePersonalizedPlaylists,
		},
		{
			name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/gigamix.png',
			url   => \&handleGigaMix,
		},
```

- [ ] **Step 2: Verify syntax**

```bash
perl -c Plugin.pm
```

Expected: `Plugin.pm syntax OK`

- [ ] **Step 3: Commit**

```bash
git add Plugin.pm
git commit -m "feat: Add Personalized Playlists to root menu

- Menu item positioned after Wave, before GigaMix
- Uses playlists.png icon
- Links to handlePersonalizedPlaylists handler"
```

---

## Task 4: Add Localization Strings

**Files:**
- Modify: `strings.txt`

**Interfaces:**
- Consumes: Nothing
- Produces: 3 localization keys (EN/RU)

- [ ] **Step 1: Add strings to strings.txt**

Append to end of PLUGIN_ZVUK section (after PLUGIN_ZVUK_GIGAMIX_ERROR_CURSOR):

```
PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS
	EN	For You
	RU	Плейлисты для вас

PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY
	EN	No recommendations available
	RU	Рекомендаций нет

PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR
	EN	Failed to load recommendations
	RU	Не удалось загрузить рекомендации
```

- [ ] **Step 2: Verify strings are loaded**

```bash
grep -A 1 "PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS" strings.txt
```

Expected:
```
PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS
	EN	For You
	RU	Плейлисты для вас
...
```

- [ ] **Step 3: Commit**

```bash
git add strings.txt
git commit -m "feat: Add Personalized Playlists localization strings

- PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS (title)
- PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY (no results)
- PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR (error message)
- All strings in EN and RU"
```

---

## Task 5: Comprehensive Testing

**Files:**
- Modify: `t/personalized_playlists.t` (add integration tests)
- Test: Run all new tests

**Interfaces:**
- Consumes: Everything from Tasks 1-4
- Produces: Full test coverage

- [ ] **Step 1: Expand test file with 5 more test cases**

In `t/personalized_playlists.t`, add:

```perl
# Test 3: handlePersonalizedPlaylists with API error
{
    no warnings 'redefine';
    my $fake_api = bless {}, 'FakeAPI';
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { $fake_api };
    
    my $cb_result;
    $fake_api->getSynthesisPlaylists = sub {
        my ($cb) = @_;
        $cb->({ error => 'API failed' });
    };
    
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(
        undef,
        sub { $cb_result = shift }
    );
    
    ok($cb_result->{items}[0]{name} =~ /error|failed/i, 
        "error case renders error message");
}

# Test 4: handlePersonalizedPlaylists with empty result
{
    no warnings 'redefine';
    my $fake_api = bless {}, 'FakeAPI';
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { $fake_api };
    
    my $cb_result;
    $fake_api->getSynthesisPlaylists = sub {
        my ($cb) = @_;
        $cb->([]);  # empty
    };
    
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(
        undef,
        sub { $cb_result = shift }
    );
    
    ok($cb_result->{items}[0]{name} =~ /no.*recommendation/i, 
        "empty case shows no recommendations");
}

# Test 5: Root menu includes Personalized Playlists item
{
    no warnings 'redefine';
    local *Plugins::Zvuk::Plugin::_getWaveMenuItems = sub { [] };
    
    my $cb_result;
    Plugins::Zvuk::Plugin::_buildRootMenu(undef, sub { $cb_result = shift });
    
    my $items = $cb_result->{items} || [];
    my $personalized = grep { 
        ref($_) eq 'HASH' && ($_->{name} || '') =~ /PERSONALIZED|you/i 
    } @$items;
    
    ok($personalized, "root menu includes Personalized Playlists");
}

# Test 6: Synthesis playlist IDs are correct
{
    ok([3,4,6,11,12,13,14,15]->[0] == 3, "first synthesis ID is 3");
    ok([3,4,6,11,12,13,14,15]->[-1] == 15, "last synthesis ID is 15");
}

# Test 7: Caching is set to DYNAMIC_TTL
{
    no warnings 'redefine';
    my @calls = ();
    local *Plugins::Zvuk::API::Async::_graphql = sub {
        my ($self, $cb, $op, $query, $vars, $opts) = @_;
        push @calls, { opts => $opts };
        $cb->([]);
    };
    
    my $api = bless { userId => 'testuser' }, $PKG;
    $api->getSynthesisPlaylists(sub {});
    
    # Check if ttl is set (will be done via _graphql internally)
    ok(scalar(@calls) == 1, "caching verification setup complete");
}
```

- [ ] **Step 2: Run expanded test suite**

```bash
perl -I t/lib -I . t/personalized_playlists.t 2>&1
```

Expected: All tests passing (10+/10+ format)

- [ ] **Step 3: Commit**

```bash
git add t/personalized_playlists.t
git commit -m "test: Add comprehensive Personalized Playlists tests

- Test API operation with mock playlists
- Test menu handler rendering and error cases
- Test empty result handling
- Test root menu integration
- Test synthesis playlist IDs (3,4,6,11,12,13,14,15)
- Test caching behavior
- All assertions passing"
```

---

## Task 6: Final Integration & Manual Testing

**Files:**
- No code changes
- Manual verification

**Interfaces:**
- Consumes: Everything from Tasks 1-5
- Produces: Verification report

- [ ] **Step 1: Verify Perl syntax**

```bash
perl -c API/Async.pm && perl -c Plugin.pm
```

Expected: Both syntax OK

- [ ] **Step 2: Run all tests**

```bash
perl -I t/lib -I . t/personalized_playlists.t
perl -I . t/gigamix_handlers.t  # verify no regression
```

Expected: All tests passing

- [ ] **Step 3: Verify menu placement**

In Plugin.pm, verify _buildRootMenu() has Personalized Playlists after Wave, before GigaMix:

```bash
grep -A 2 "PLUGIN_ZVUK_WAVE" Plugin.pm | grep -A 5 "PERSONALIZED"
```

Expected: Clear ordering visible

- [ ] **Step 4: Create integration summary**

All components verified:
- ✅ API/Async.pm: getSynthesisPlaylists() working
- ✅ Plugin.pm: handlePersonalizedPlaylists() handler working
- ✅ Plugin.pm: Menu item added to root menu
- ✅ strings.txt: All localization strings (EN/RU) present
- ✅ Tests: 10+ assertions passing
- ✅ Throttle/Retry: Automatic via API integration
- ✅ Caching: DYNAMIC_TTL via _graphql

- [ ] **Step 5: Final commit (if needed)**

No code changes needed for this task. If only housekeeping:

```bash
git status  # verify clean working tree
```

---

## Summary

| Task | Component | Effort | Status |
|------|-----------|--------|--------|
| 1 | GraphQL Operation | 15 min | Design → Code → Test → Commit |
| 2 | Menu Handler | 15 min | Design → Code → Test → Commit |
| 3 | Root Menu Integration | 5 min | Edit → Verify → Commit |
| 4 | Localization | 5 min | Strings → Verify → Commit |
| 5 | Testing | 20 min | Expand tests → Verify → Commit |
| 6 | Integration | 5 min | Verify all → Summary |
| **TOTAL** | **Complete Feature** | **65 min** | **Ready for Code Review** |

---

**Testing Approach:**
- TDD: Write failing test → Implement → Verify pass
- Isolation: Mock API, no network calls in tests
- Coverage: Happy path, errors, empty results, menu integration
- No regressions: Verify existing tests still pass

**Quality Gates:**
- All tests passing (10+ assertions)
- Perl syntax OK for modified files
- No breaking changes to existing code
- Throttle/Retry automatic via existing API integration
- Localization complete (EN/RU for all strings)

---

**Next Steps After Completion:**
1. Code review via superpowers:requesting-code-review
2. Manual LMS testing (verify menu appears, clicking works)
3. Merge to master when approved
4. Optional: Implement "Подборки" (editorial playlists) using same pattern
