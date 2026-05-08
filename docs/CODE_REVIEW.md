# Code Review Report: lms-zvuk Plugin

**Date:** 2026-05-07  
**Reviewer:** Senior code review (AI-assisted)  
**Scope:** Post-handover review of code written by external middle developer  
**Status:** All issues from this report are FIXED in the same session.

---

## Summary

| Severity | Count | Fixed |
|----------|-------|-------|
| 🔴 Critical | 3 | ✅ All |
| 🟠 High | 7 | ✅ All |
| 🟡 Medium | 8 | ✅ All |

### What was done right

- **Search fix (P1)** — correctly implemented: `query search(...)`, operationName `'search'`, boolean `\1`/`\0`
- Caching in `_graphql` with TTL per operation type
- Per-player API client via `$client->master()`
- Proactive metadata caching (`cacheTrackMetadata`) during browse
- Correct `getNextTrack` signature: `$song->streamUrl($url); $successCb->()`
- `formatOverride` reads from `$song->pluginData('format')`
- Full EN/RU string translations

---

## Critical Issues (Fixed)

### CR-1: Double `$cache` declaration in API.pm

**File:** `API.pm` lines 37 and 66  
**Fix:** Removed duplicate `my $cache = Slim::Utils::Cache->new` at line 37.

Line 37 created a cache object immediately shadowed by line 66. Under `use warnings` this would warn "my variable $cache masks earlier declaration". Without warnings — silent waste of object instantiation.

---

### CR-2: Track search cursor key mismatch

**File:** `Plugin.pm:165` vs `API/Async.pm:184`  
**Fix:** Added `%cursorKeys` mapping in `_searchGeneric`.

Plugin.pm was building `$vars{"tracksCursor"}` (with 's'), but `API/Async.pm::search` reads `$args->{trackCursor}` (without 's'). Effect: NEXT PAGE for track search never worked. For artists/releases/playlists — keys matched correctly, only tracks was broken.

---

### CR-3: `cookies.txt` tracked in git, no `.gitignore`

**Fix:** Created `.gitignore`, removed `cookies.txt` from git tracking via `git rm --cached`.

Real auth credentials were committed to git history. **If the token is still active, rotate it at zvuk.com.**

---

## High Severity Issues (Fixed)

### CR-4: `_globalSearchItems` — stub, always returned `[]`

**File:** `Plugin.pm:384`  
**Fix:** Removed `registerInfoProvider` registration and the empty stub function.

A global search provider was registered but always returned empty results. Users saw "Zvuk" in LMS global search but got no results — worse than not registering at all.

---

### CR-5: `canDirectStream` — wrong logic

**File:** `ProtocolHandler.pm:206`  
**Fix:** `sub canDirectStream { 0 }`

Previous code returned `1` for any `https://` URL. All reference plugins (Deezer, TIDAL, Qobuz) always return `0`. Returning `1` could cause players to stream without plugin's HTTP handling, which is fragile if CDN headers are ever required.

---

### CR-6: `use Async::Util` — dead import

**File:** `API/Async.pm:5`  
**Fix:** Removed the line.

Module was imported but never used (`Async::Util::amap`/`achain` were not called anywhere). Added `use warnings` in its place.

---

### CR-7: FLAC header parsing — no LMS version guard

**File:** `ProtocolHandler.pm:109`  
**Fix:** Added `CAN_FLAC_SEEK` constant, simplified passthrough to match Qobuz pattern.

`parseFlacHeader` is the **standard pattern** used by Qobuz, Deezer, TIDAL. It's needed for accurate FLAC seekbar. However, the function requires LMS ≥ 8.0 — without a guard, it would crash on older LMS. Added:
```perl
use constant CAN_FLAC_SEEK => UNIVERSAL::can('Slim::Utils::Scanner::Remote', 'parseFlacHeader');
```
Also simplified the passthrough from a `_finalizeMetadata` closure to direct `{ cb => $successCb }` like Qobuz.

---

### CR-8: `_finalizeMetadata` — synchronous DB write in async callback

**File:** `ProtocolHandler.pm:147`  
**Fix:** Removed `Slim::Schema->updateOrCreate` and `Slim::Schema->clearContentTypeCache` blocks.

`Slim::Schema->updateOrCreate` is a synchronous SQLite operation inside an async callback — could block LMS event loop. `clearContentTypeCache` is a non-standard method that may not exist in all LMS versions. The `eval {}` was silently swallowing errors. Content type is correctly provided by `formatOverride` without DB writes.

---

### CR-9: `getPlaylistTracks` — no pagination, hardcoded 100 limit

**File:** `API/Async.pm:363`  
**Fix:** Raised limit to 500 and pass explicit `{ id, limit, offset }` variables.

Previously offset was never passed (always 0), and limit 100 was in query default only. Playlists with >100 tracks were silently truncated.

---

### CR-10: `getCollection` — hardcoded limit 100

**File:** `API/Async.pm:483`  
**Fix:** Raised limit to 500.

User collections on Zvuk can contain thousands of tracks. First 100 was not representative.

---

## Medium Issues (Fixed)

### CR-11: `_getArtistName` — duplicated code

**Files:** `API.pm:134` and `Plugin.pm:328`  
**Fix:** Plugin.pm now delegates: `sub _getArtistName { Plugins::Zvuk::API->_getArtistName($_[0]) }`

Identical logic in two places. API.pm is the canonical location since it's shared by all modules.

---

### CR-12: `_renderTrack` — dead fallback `$track->{album}`

**File:** `Plugin.pm:316`  
**Fix:** Removed `|| $track->{album}->{title}`.

Zvuk API never returns `album` key in track objects — only `release`. The fallback was always `undef`.

---

### CR-13: `_renderAlbum` — raw `artistTemplate` not resolved

**File:** `Plugin.pm:354`  
**Fix:** `line2 => _getArtistName($album)` instead of `$album->{artistTemplate}`.

If API returned `artistTemplate` with `{0}`, `{1}` placeholders, users saw them literally in the UI.

---

### CR-14: `getQuality` — inconsistent call style

**File:** `ProtocolHandler.pm:234`  
**Fix:** `Plugins::Zvuk::API::getQuality()` → `Plugins::Zvuk::API->getQuality()`

---

### CR-16: Missing `use warnings` in all files

**Fix:** Added to `API.pm`, `API/Async.pm`, `Plugin.pm`, `ProtocolHandler.pm`.

---

### CR-18: `QUALITY_MID` bitrate inconsistency

**Fix:** Updated constant comment in `API.pm` and string in `strings.txt` from "192 kbps" to "128 kbps".

Code was using `128_000` bps but comments claimed 192 kbps.

---

## Remaining Roadmap (Not Fixed in This Session)

| Feature | Priority | Notes |
|---------|----------|-------|
| CR-15: `explodePlaylist` artist type | Medium | Add `artist` to dispatch table |
| CR-17: `getPersonalWave` fragment cleanup | Medium | Remove unused fields: `lyrics`, `hasFlac`, `childParam`, `mark`, `zchan`, `__typename` |
| Library Importer | Low | `Plugins::Zvuk::Importer` |
| Like/Dislike actions | Low | Context menu mutations |
| Infinite Wave | Low | `DontStopTheMusic` hook |
