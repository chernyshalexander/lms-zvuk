# Codebase Refactoring Plan & Progress

Repository: `lms-zvuk`
Branch: `experiment`

---

## Phase Summary

| Phase | Description | Status | Commit / Details |
|---|---|---|---|
| **Phase 1** | Hygiene, Security & Cleanup: security allowlist for image proxy, disable flacdrm, fix clearClient & GigaMix menu, clean dead code, add PLUGIN_ZVUK_ARTISTS, track tests in git | ✅ Completed | `ed79d9b` |
| **Phase 2** | Test Harness Normalization: normalize test suite to `Test::More` and enable `prove` test runner | ✅ Completed | `e5dd90c` |
| **Phase 3** | StreamManager & Stream Lifecycle Unification: unified atomic state, race condition prevention, external album change isolation, GigaMix stream launching & clean completion | ✅ Completed | `5a2bef6` |
| **Phase 4** | Code Duplication Elimination (DRY in WebHandlers/UI): `_sendJsonResponse`, external OAuth template, wave settings unification, `UI::Common` | ✅ Completed | Phase 4 implementation |
| **Phase 5** | Namespace Reorganization: `Session.pm` extraction, `API.pm` facade, UI/ relocation | ⏳ Next | Alignment & Implementation |

---

## Phase 3 Details: StreamManager and Stream Lifecycle Unification

### 1. `Plugins::Zvuk::StreamManager` (`StreamManager.pm`)
- **Lifecycle Encapsulation**: Created `StreamManager.pm` encapsulating stream lifecycle for all 4 stream types:
  - Wave (`wave`)
  - Radio (`radio`)
  - Atlas (`atlas`)
  - GigaMix (`gigamix`)
- **Unified State Management**: Replaced fragmented and conflicting client flags with atomic state in `$client->pluginData('zvuk_stream')`:
  ```perl
  {
      mode       => 'wave' | 'radio' | 'atlas' | 'gigamix' | undef,
      is_loading => 0,
      context    => { ... }
  }
  ```
- **Helper Methods**:
  - `startStream($client, $mode, $params)`
  - `stopStream($client)`
  - `getActiveMode($client)`
  - `isLoading($client)`
  - `checkAndExtendQueue($client)`
  - `extendQueue($client, $mode)`
  - `updateContext($client, $updates)`
  - `getContext($client)`
  - `onPlaylistChange($client, $request)`
- **Backwards-Compatibility Sync**:
  - Fully maintains legacy `pluginData` flags (`zvuk_wave_active`, `zvuk_radio_active`, `zvuk_atlas_active`, `zvuk_gigamix_active`) and legacy context keys (`zvuk_radio_entity_id`, `zvuk_atlas_island_id`, etc.) so that external and existing code remains 100% functional.
  - Fallbacks in `getActiveMode` and `isLoading` recognize legacy flags if set directly.
- **Race Condition Prevention & Stream Isolation**:
  - Single `is_loading` flag protects queue extension across ALL 4 modes, preventing duplicate track appending on rapid `getNextTrack` calls.
  - Stream instance token (`stream_id`) isolation: each stream generation is stamped with a unique monotonic ID. In-flight asynchronous callbacks from aborted or replaced streams automatically detect instance mismatches and discard stale batches, ensuring in-flight tracks NEVER leak into subsequently loaded albums or new streams, and never corrupt the new stream's `is_loading` state.
  - Explicit stream vs autoplay preference isolation: `checkAndExtendQueue` respects `gigamix_autoplay` preference for normal playlist playback while allowing continuous playback for streams explicitly launched via `zvuk://gigamix:...`.
- **External Album / Playlist Change Isolation**:
  - Subscribes to playlist change events (`stop`, `playlist clear`, `playlist play`, `playlist loadtracks`, `playlist loadalbum`, `playlist playalbum`, `playlist open`).
  - Resets active stream state when an external album/playlist/artist container is exploded or played.
  - Ensures stream tracks NEVER leak into ordinary albums or local media playback.

### 2. GigaMix URI & Protocol Handling
- **ProtocolHandler**:
  - Handled `zvuk://gigamix:<prompt>` in `getFormatForURL` (returns `undef` so LMS treats it as a playlist container), `getMetadataFor` (returns `{}`), `canDirectStream` (0), and `explodePlaylist` (starts GigaMix stream, fetches initial batch via API, returns track URLs).
  - Defensive error handling and empty prompt fallback support (`zvuk://gigamix:`).
- **GigaMix Menu (`GigaMix.pm`)**:
  - Added "▶ Play GigaMix Stream" item (`PLUGIN_ZVUK_GIGAMIX_PLAY_STREAM`) at the top of `_renderGigaMixPlaylist` with URL `zvuk://gigamix:$escaped_prompt` and proper `name` + `line1` fields.
  - Preserved the tracks list below for single-track selection.
- **Strings (`strings.txt`)**:
  - Added `PLUGIN_ZVUK_GIGAMIX_PLAY_STREAM` (EN: `Play GigaMix Stream`, RU: `Слушать поток GigaMix`).
  - Added `PLUGIN_ZVUK_GIGAMIX_FINISHED` (EN: `GigaMix playlist complete`, RU: `Плейлист GigaMix завершён`).
- **GigaMix Pagination & Honest Completion**:
  - Plays all generated tracks (~70-100). When the API returns the last batch with `cursor => null/undef`, tracks are appended and the cursor is explicitly set to `undef` (never retaining stale cursor).
  - When the final tracks finish and queue boundary is reached with `cursor == null`, GigaMix stops cleanly (`mode => undef`, all flags cleared) and sends a notification with `PLUGIN_ZVUK_GIGAMIX_FINISHED`. No infinite looping with stale cursor.

### 3. Refactored `ProtocolHandler.pm`
- Replaced the 4 repetitive auto-load blocks in `getNextTrack` with a single unified call:
  `Plugins::Zvuk::StreamManager->checkAndExtendQueue($client);`
- Added defensive client API resolution checks in `_explodeRadio` and `_explodeWave`.
- Retained `_loadMoreWaveTracks`, `_loadMoreRadioTracks`, `_loadMoreAtlasTracks`, and `_loadMoreGigaMixTracks` as backward-compatible delegates to `StreamManager->extendQueue`.

### 4. Verification Record
- Created `t/test_stream_manager.pl` and symlink `t/test_stream_manager.t` testing:
  - Atomic state transitions across Wave, Radio, Atlas, and GigaMix.
  - Clean state reset on stop, playlist clear, external album/track playback (`loadalbum`, `playalbum`, `play`), and external album explosion.
  - In-flight request stream isolation (discarding stale batches on stop/mode change without leaking tracks or corrupting `is_loading`).
  - GigaMix stream launching (`zvuk://gigamix:...`), empty prompt fallback, menu item generation (`name` + `line1`), auto-extension, `gigamix_autoplay` pref vs explicit stream mode, and clean termination when cursor=null.
  - Race condition protection (`is_loading` prevents duplicate concurrent calls across all 4 modes) and queue boundary verification (≤2 tracks remaining).
- All 21 test files pass 100% via `prove -I. -It t/` (544 tests total).
- Strict Perl 5.14+ compatibility verified (no lexical subroutines, no signatures).

---

## Phase 4 Details: Code Duplication Elimination (DRY in WebHandlers/UI)

### 1. `WebHandlers.pm` Streamlining (1,059 -> 738 lines, -321 lines)
- **JSON Response Consolidation**:
  - Implemented `_sendJsonResponse($httpClient, $response, $data, $code)` and `_sendJsonError($httpClient, $response, $error_msg, $code, $extra)`:
    - Standardized UTF-8 content type `application/json; charset=utf-8`.
    - Computed accurate `Content-Length`.
    - Used canonical `JSON::XS` encoding.
    - Replaced ~30 repetitive response blocks across all handlers (`handleSaveOAuthToken`, `handleGetAnonymousToken`, `handleRequestSmsCode`, `handleVerifySmsCode`, `handleGetAtlasMapWeb`, etc.).
- **Externalized OAuth Browser Callback HTML**:
  - Moved 175 lines of inline HTML/CSS/JS from `WebHandlers.pm` into `HTML/EN/plugins/zvuk/oauthCallback.html`.
  - Refactored `handleOAuthCallback` to cleanly render via `Slim::Web::HTTP::filltemplatefile('plugins/zvuk/oauthCallback.html', {})`.
- **Wave Settings Page Parameterization**:
  - Unified `handleWaveSettingsWebUI` and `handleWaveSettingsStandalone` into a single helper `_renderWaveSettingsPage($httpClient, $response, $template)`.
  - Eliminated 55 lines of identical genre mapping, JSON encoding, and template filling logic.

### 2. `Plugins::Zvuk::UI::Common` (`UI/Common.pm`)
- **Centralized UI Kind Resolution**:
  - Created `Plugins::Zvuk::UI::Common::uiKind($client, $args)` detecting:
    - `classic_web` (`isWeb => 1`)
    - `player_buttons` (`isButton => 1`)
    - `weblink_capable` (`Slim::Utils::Misc::canFollowWeblinks`)
    - `jive` (`SqueezePlay` user-agent or default fallback)
- **Safe VFD Mode Popping**:
  - Created `Plugins::Zvuk::UI::Common::popVfdMode($client)`: safely checks if `popMode` is available and current mode is `xmlbrowser` before popping to prevent menu crashes and stack underflow.
- **Backward-Compatible Integration**:
  - `WaveUI.pm` and `AtlasUI.pm` delegate their `_uiKind` and `popMode` calls to `UI::Common`.

### 3. Verification
- Created `t/test_phase4_dry.pl` and symlink `t/test_phase4_dry.t`:
  - Verified `UI::Common::uiKind` across all 4 client kinds + fallbacks.
  - Verified `UI::Common::popVfdMode` execution and guards.
  - Verified `_sendJsonResponse` and `_sendJsonError` status codes, JSON payload, extra attributes, and charset.
  - Verified physical template file existence and rendering in `handleOAuthCallback`, `handleWaveSettingsWebUI`, and `handleWaveSettingsStandalone`.
- Test harness: 22 test files, 548 tests, **100% PASS**.

