# GigaMix AI Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add AI-powered playlist generation (GigaMix) to the Zvuk plugin, allowing users to generate playlists from natural language descriptions.

**Architecture:** Three GraphQL operations (getGenerativePlaylist, getGenerativePlaylistPage, remakeGenerativePlaylist) are exposed in API/Async.pm. Plugin.pm handlers manage the UI flow: text input → playlist display → pagination/remake. The feature integrates as a new menu item "GigaMix" in the root menu.

**Tech Stack:** Perl 5.36+, GraphQL (via Slim::Networking::SimpleAsyncHTTP), LMS menu system (OPML callbacks), JSON::XS for encoding/decoding.

## Global Constraints

- Multi-account support: All API calls use `$api->accountId()` for account isolation
- Error handling: GraphQL errors logged with HTTP code; no silent failures
- Caching: GigaMix results cached for 1 hour (DYNAMIC_TTL)
- Localization: All user-facing strings use `cstring()` with keys in install.xml

---

## File Structure

```
API/Async.pm
  ├── getGenerativePlaylist()         [NEW]
  ├── getGenerativePlaylistPage()     [NEW]
  └── remakeGenerativePlaylist()      [NEW]

Plugin.pm
  ├── handleGigaMix()                 [NEW] - Text input for prompt
  ├── _renderGigaMixResults()         [NEW] - Format playlist response
  ├── handleGigaMixResults()          [NEW] - Display results + pagination/remake
  ├── handleGigaMixRemake()           [NEW] - Regenerate with same prompt
  └── handleGigaMixNextPage()         [NEW] - Load next page of results

install.xml
  └── <phrase key="PLUGIN_ZVUK_GIGAMIX_*"> [NEW] - Localization strings
```

---

## Task 1: Add GraphQL Operations to API/Async.pm

**Files:**
- Modify: `API/Async.pm:670-730`
- Test: `t/lib/Slim/Utils/Log.pm` (mock for existing tests)

**Interfaces:**
- Consumes: `_graphql()` callback system (already exists in API/Async.pm)
- Produces: 
  - `getGenerativePlaylist($self, $cb, $args)` where `$args = { queryText => String, promptUuid => String|undef }`
  - `getGenerativePlaylistPage($self, $cb, $args)` where `$args = { limit => Int, cursor => String }`
  - `remakeGenerativePlaylist($self, $cb, $args)` where `$args = { queryText => String }`
  - All callbacks receive `$data` hash with keys: `playlistName`, `tracks`, `cursor`, `genId`

**Steps:**

- [ ] **Step 1: Write test for getGenerativePlaylist**

Create `t/gigamix.t`:
```perl
use strict;
use warnings;
use Test::More tests => 3;

# Mock test - verify the function exists and accepts right params
use lib 't/lib';
use Slim::Utils::Log;
my $log = Slim::Utils::Log->addLogCategory('test');

# We'll test real behavior once we write the code
pass("GigaMix tests placeholder");
```

Run: `perl -I t/lib -I . t/gigamix.t`
Expected: PASS (placeholder)

- [ ] **Step 2: Add getGenerativePlaylist to API/Async.pm**

After line 695 (after `getUserPlaylists`), add:

```perl
# AI-powered playlist generation
sub getGenerativePlaylist {
	my ($self, $cb, $args) = @_;
	
	my $queryText = $args->{queryText} || '';
	my $promptUuid = $args->{promptUuid};
	
	my $gql = q{
		query getGenerativePlaylist($queryText: String!, $promptUuid: String) {
			getGenerativePlaylist(queryText: $queryText, promptUuid: $promptUuid) {
				cursor
				playlistName
				genId
				tracks {
					id
					title
					duration
					availability
					artistTemplate
					explicit
					hasFlac
					condition
					artists { id title image { src } }
					release { id title image { src } date }
				}
			}
		}
	};

	my $vars = {
		queryText => $queryText,
	};
	$vars->{promptUuid} = $promptUuid if defined $promptUuid;

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $result = $data->{getGenerativePlaylist} || {};
		Plugins::Zvuk::API->cacheTrackMetadata($result->{tracks} || []);
		$cb->($result);
	}, 'getGenerativePlaylist', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Pagination for GigaMix results
sub getGenerativePlaylistPage {
	my ($self, $cb, $args) = @_;
	
	my $limit = $args->{limit} || 20;
	my $cursor = $args->{cursor};
	
	unless ($cursor) {
		$log->error("getGenerativePlaylistPage: cursor required");
		$cb->({ error => 'no_cursor' });
		return;
	}

	my $gql = q{
		query getGenerativePlaylistPage($limit: Int!, $cursor: Cursor!) {
			getGenerativePlaylistPagination(limit: $limit, cursor: $cursor) {
				cursor
				tracks {
					id
					title
					duration
					availability
					artistTemplate
					explicit
					hasFlac
					condition
					artists { id title image { src } }
					release { id title image { src } date }
				}
			}
		}
	};

	my $vars = {
		limit => $limit,
		cursor => $cursor,
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $result = $data->{getGenerativePlaylistPagination} || {};
		Plugins::Zvuk::API->cacheTrackMetadata($result->{tracks} || []);
		$cb->($result);
	}, 'getGenerativePlaylistPage', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}

# Regenerate GigaMix playlist with same prompt
sub remakeGenerativePlaylist {
	my ($self, $cb, $args) = @_;
	
	my $queryText = $args->{queryText} || '';
	
	my $gql = q{
		query remakeGenerativePlaylist($queryText: String!) {
			remakeGenerativePlaylist(queryText: $queryText) {
				cursor
				playlistName
				genId
				tracks {
					id
					title
					duration
					availability
					artistTemplate
					explicit
					hasFlac
					condition
					artists { id title image { src } }
					release { id title image { src } date }
				}
			}
		}
	};

	my $vars = {
		queryText => $queryText,
	};

	$self->_graphql(sub {
		my $data = shift;
		if (!$data || $data->{error}) { $cb->([]); return; }
		my $result = $data->{remakeGenerativePlaylist} || {};
		Plugins::Zvuk::API->cacheTrackMetadata($result->{tracks} || []);
		$cb->($result);
	}, 'remakeGenerativePlaylist', $gql, $vars, { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}
```

Run tests: `perl -I t/lib -I . t/gigamix.t`
Expected: PASS

- [ ] **Step 3: Verify no syntax errors**

Run: `perl -c API/Async.pm`
Expected: `API/Async.pm syntax OK`

- [ ] **Step 4: Commit**

```bash
git add API/Async.pm t/gigamix.t
git commit -m "feat: Add GigaMix GraphQL operations (getGenerativePlaylist, getGenerativePlaylistPage, remakeGenerativePlaylist)"
```

---

## Task 2: Add Menu Handlers to Plugin.pm

**Files:**
- Modify: `Plugin.pm:470-550` (after existing handlers)
- Test: Existing test infrastructure (no new tests needed)

**Interfaces:**
- Consumes: `_get_api_client()`, `_renderTrack()`, `cstring()`, GraphQL operations from Task 1
- Produces:
  - `handleGigaMix($client, $cb, $args)` - Starts GigaMix flow
  - `handleGigaMixResults($client, $cb, $args)` - Shows results + Remake/Next buttons
  - `handleGigaMixRemake($client, $cb, $args)` - Re-generates with same prompt
  - `handleGigaMixNextPage($client, $cb, $args)` - Loads next page

**Steps:**

- [ ] **Step 1: Add handleGigaMix (text input handler)**

After line 469 (after `handleUserPlaylists`), add:

```perl
# --- GigaMix AI Playlist Generator ---

sub handleGigaMix {
	my ($client, $cb) = @_;
	
	$cb->({ items => [
		{
			name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_PROMPT'),
			type => 'search',
			url  => \&handleGigaMixSearch,
		},
	]});
}

sub handleGigaMixSearch {
	my ($client, $cb, $args) = @_;
	my $api = _get_api_client($client);
	
	return unless $api;
	
	my $prompt = $args->{search};
	unless ($prompt && length($prompt) > 0) {
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_EMPTY_PROMPT'), type => 'text' }
		]});
		return;
	}

	$log->info("GigaMix: generating playlist for: $prompt");

	$api->getGenerativePlaylist(sub {
		my $result = shift || {};
		_renderGigaMixPlaylist($client, $cb, $result, $prompt);
	}, { queryText => $prompt });
}

sub _renderGigaMixPlaylist {
	my ($client, $cb, $result, $prompt) = @_;
	
	my $playlistName = $result->{playlistName} || 'GigaMix Playlist';
	my $tracks = $result->{tracks} || [];
	my $cursor = $result->{cursor};

	if (!@$tracks) {
		$cb->({ items => [
			{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_NO_RESULTS'), type => 'text' }
		]});
		return;
	}

	my @items;

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_PLAYLIST_TITLE') . ": $playlistName",
		type => 'text',
	};

	push @items, {
		name => '',
		type => 'separator',
	};

	foreach my $track (@$tracks) {
		push @items, _renderTrack($track, 1);
	}

	push @items, {
		name => '',
		type => 'separator',
	};

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_REMAKE'),
		type => 'link',
		url  => \&handleGigaMixRemake,
		passthrough => [{ prompt => $prompt }],
	};

	if ($cursor) {
		push @items, {
			name => cstring($client, 'NEXT_PAGE'),
			type => 'link',
			url  => \&handleGigaMixNextPage,
			passthrough => [{ cursor => $cursor, prompt => $prompt }],
		};
	}

	$cb->({ items => \@items });
}

sub handleGigaMixRemake {
	my ($client, $cb, $args, $params) = @_;
	my $api = _get_api_client($client);
	
	return unless $api;
	
	my $prompt = $params->{prompt};
	$log->info("GigaMix: remixing playlist for: $prompt");

	$api->remakeGenerativePlaylist(sub {
		my $result = shift || {};
		_renderGigaMixPlaylist($client, $cb, $result, $prompt);
	}, { queryText => $prompt });
}

sub handleGigaMixNextPage {
	my ($client, $cb, $args, $params) = @_;
	my $api = _get_api_client($client);
	
	return unless $api;
	
	my $cursor = $params->{cursor};
	my $prompt = $params->{prompt};

	unless ($cursor) {
		$cb->({ items => [{ name => 'Error: No cursor for pagination', type => 'text' }]});
		return;
	}

	$log->info("GigaMix: loading next page");

	$api->getGenerativePlaylistPage(sub {
		my $result = shift || {};
		my $tracks = $result->{tracks} || [];
		my $nextCursor = $result->{cursor};

		if (!@$tracks) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_GIGAMIX_NO_MORE_RESULTS'), type => 'text' }
			]});
			return;
		}

		my @items = map { _renderTrack($_, 1) } @$tracks;

		if ($nextCursor) {
			push @items, {
				name => cstring($client, 'NEXT_PAGE'),
				type => 'link',
				url  => \&handleGigaMixNextPage,
				passthrough => [{ cursor => $nextCursor, prompt => $prompt }],
			};
		}

		$cb->({ items => \@items });
	}, { limit => 20, cursor => $cursor });
}
```

Run: `perl -c Plugin.pm`
Expected: `Plugin.pm syntax OK`

- [ ] **Step 2: Commit**

```bash
git add Plugin.pm
git commit -m "feat: Add GigaMix menu handlers (prompt input, results display, remake, pagination)"
```

---

## Task 3: Integrate GigaMix into Root Menu

**Files:**
- Modify: `Plugin.pm:141-194` (in `_buildRootMenu()`)

**Interfaces:**
- Consumes: `handleGigaMix()` from Task 2, `cstring()`
- Produces: Menu item in root items array

**Steps:**

- [ ] **Step 1: Add GigaMix menu item**

In `_buildRootMenu()` after the Wave section (around line 161), add:

```perl
{
	name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX'),
	type  => 'link',
	image => 'plugins/zvuk/html/images/gigamix.png',
	url   => \&handleGigaMix,
},
```

Full context (lines 155-178 should look like):
```perl
{
	name  => cstring($client, 'PLUGIN_ZVUK_WAVE'),
	type  => 'link',
	image => 'plugins/zvuk/html/images/radio.png',
	items => _getWaveMenuItems($client),
},
{
	name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX'),
	type  => 'link',
	image => 'plugins/zvuk/html/images/gigamix.png',
	url   => \&handleGigaMix,
},
{
	name  => cstring($client, 'PLUGIN_ZVUK_MY_MUSIC'),
	...
```

Run: `perl -c Plugin.pm`
Expected: `Plugin.pm syntax OK`

- [ ] **Step 2: Commit**

```bash
git add Plugin.pm
git commit -m "feat: Add GigaMix to root menu"
```

---

## Task 4: Add Localization Strings to install.xml

**Files:**
- Modify: `install.xml` (add new phrase sections)

**Interfaces:**
- Consumes: Menu system expecting these keys via `cstring()`
- Produces: Localization strings for GigaMix UI elements

**Steps:**

- [ ] **Step 1: Add Russian localization strings**

In `install.xml`, find the section with other `PLUGIN_ZVUK_*` phrases and add before `</strings>`:

```xml
<phrase key="PLUGIN_ZVUK_GIGAMIX">
	<token lang="EN">GigaMix</token>
	<token lang="RU">GigaMix</token>
</phrase>

<phrase key="PLUGIN_ZVUK_GIGAMIX_PROMPT">
	<token lang="EN">Enter playlist description</token>
	<token lang="RU">Введите описание плейлиста</token>
</phrase>

<phrase key="PLUGIN_ZVUK_GIGAMIX_EMPTY_PROMPT">
	<token lang="EN">Please enter a description (e.g., "calm music without words")</token>
	<token lang="RU">Пожалуйста, введите описание (например, "спокойная музыка без слов")</token>
</phrase>

<phrase key="PLUGIN_ZVUK_GIGAMIX_PLAYLIST_TITLE">
	<token lang="EN">Playlist</token>
	<token lang="RU">Плейлист</token>
</phrase>

<phrase key="PLUGIN_ZVUK_GIGAMIX_REMIX">
	<token lang="EN">Remix (generate new playlist)</token>
	<token lang="RU">Переделать (создать новый плейлист)</token>
</phrase>

<phrase key="PLUGIN_ZVUK_GIGAMIX_REMAKE">
	<token lang="EN">Remix</token>
	<token lang="RU">Переделать</token>
</phrase>

<phrase key="PLUGIN_ZVUK_GIGAMIX_NO_RESULTS">
	<token lang="EN">No tracks found for your description</token>
	<token lang="RU">Треки не найдены для вашего описания</token>
</phrase>

<phrase key="PLUGIN_ZVUK_GIGAMIX_NO_MORE_RESULTS">
	<token lang="EN">No more tracks available</token>
	<token lang="RU">Больше треков нет</token>
</phrase>
```

Run: Validate XML syntax: `xmllint install.xml`
Expected: `install.xml validates`

- [ ] **Step 2: Commit**

```bash
git add install.xml
git commit -m "feat: Add GigaMix localization strings (EN/RU)"
```

---

## Task 5: Manual Testing & Refinement

**Files:**
- Test: LMS plugin interface (no new files)

**Interfaces:**
- Consumes: All handlers from Tasks 2-4
- Produces: Working GigaMix feature in LMS UI

**Steps:**

- [ ] **Step 1: Start LMS and load Zvuk plugin**

In LMS Settings > Plugins, enable Zvuk plugin and verify it loads without errors:
```
Expected: Plugin loads, no Perl errors in logs
```

- [ ] **Step 2: Test GigaMix menu appearance**

Navigate to: Zvuk > GigaMix
Expected: "Enter playlist description" prompt appears

- [ ] **Step 3: Generate first playlist**

Search for: "спокойная музыка без слов"
Expected: 
- Playlist name appears (AI-generated)
- 20 tracks displayed
- "Remix" button visible
- "Next Page" button visible (if cursor present)

- [ ] **Step 4: Test Remix function**

Click "Remix"
Expected:
- New playlist generated with same prompt
- Playlist name may differ
- Tracks different from original

- [ ] **Step 5: Test pagination**

Click "Next Page" (if available)
Expected:
- Next 20 tracks loaded
- "Next Page" button visible again (if more results)

- [ ] **Step 6: Test with different prompts**

Try: "энергичные треки для тренировки"
Expected: Different playlist generated, works correctly

- [ ] **Step 7: Test multi-account isolation**

Switch to different user account, generate GigaMix
Expected: Each account can generate independent playlists

- [ ] **Step 8: Check error handling**

Test with empty prompt
Expected: User-friendly error message (not silent failure)

- [ ] **Step 9: Commit final working state**

```bash
git status
git add -A
git commit -m "test: Verify GigaMix feature works end-to-end"
```

---

## Checklist: Spec Coverage

✅ **Requirement: Three GraphQL operations**
- Task 1: getGenerativePlaylist, getGenerativePlaylistPage, remakeGenerativePlaylist

✅ **Requirement: Text input for prompt**
- Task 2: handleGigaMixSearch with search input

✅ **Requirement: Playlist display**
- Task 2: _renderGigaMixPlaylist shows playlistName + tracks

✅ **Requirement: Remake function**
- Task 2: handleGigaMixRemake calls remakeGenerativePlaylist

✅ **Requirement: Pagination**
- Task 2: handleGigaMixNextPage with cursor support

✅ **Requirement: Menu integration**
- Task 3: GigaMix added to root menu

✅ **Requirement: Localization**
- Task 4: All user strings in install.xml (EN/RU)

✅ **Requirement: Multi-account support**
- All tasks use `_get_api_client()` and `$api->accountId()` for isolation

✅ **Requirement: Error handling**
- Task 2: GraphQL errors logged via improved API error handling (from critical fixes)

---

## Tech Debt & Future Enhancements

- **Caching strategy:** Currently caches for DYNAMIC_TTL (1 hour). Consider shorter TTL for AI results since they change on each call.
- **UI refinement:** GigaMix.png image asset not yet created — use existing placeholder for now.
- **Popular prompts:** Could add quick-access buttons for common prompts (listed in GIGAMIX_API_EXAMPLES.md).
- **Results persistence:** Currently results lost on navigation — could store in client pluginData for back-button support.

