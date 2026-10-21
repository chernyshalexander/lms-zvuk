# P3.4 Code Hygiene Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 2204-line `Plugin.pm` monolith into focused modules (Wave UI, Wave Wizard, GigaMix, Web/OAuth handlers), fix two real bugs uncovered while mapping the file (unplayable podcast episodes, missing pagination on recommendation categories), and retire two GraphQL discovery scripts whose hypotheses are now known to be wrong.

**Architecture:** Perl/LMS plugin (`Plugins::Zvuk::*`, package-per-file, no OO). New modules are plain siblings of `Plugin.pm` — they call back into `Plugin.pm`'s remaining shared helpers (`_get_api_client`, `_renderTrack`, `_renderAlbum`, etc.) via fully-qualified sub names (`Plugins::Zvuk::Plugin::_get_api_client($client)`). No module `use`s another Zvuk module that would create a cycle back to itself; only `Plugin.pm` `use`s the four new modules, so there is no circular `use`. This mirrors the pattern already established by `ProtocolHandler.pm::_getAPIHandler`, which has delegated to `Plugins::Zvuk::Plugin::_get_api_client` since the P0.1 fix.

**Tech Stack:** Perl 5, Lyrion Music Server (LMS) plugin framework (`Slim::Plugin::OPMLBased`), JSON::XS, GraphQL over HTTPS.

## Global Constraints

- Never rename or change the signature of a sub that's called via `\&subname` in a `url =>` menu-item field unless every caller is updated in the same task — LMS resolves these as code refs at menu-build time, a stale ref is a silent dead menu item, not an error.
- Preserve tabs-for-indentation (the file uses tabs, not spaces) in every new/moved file — check with `cat -A` if unsure, don't let an editor silently convert them.
- `docs/`, `test/`, and `t/` are all gitignored (see `.gitignore`) — changes there are local-only and never show up in `git status`/`git diff`; do not expect `git add` to pick them up, and don't skip updating them just because they won't appear in a diff.
- The regression harness `t/reproduce_p0_multiaccount_bugs.pl` is the only executable safety net in this repo. It must exit 0 both before you start (baseline) and after every task that touches `Plugin.pm`, `ProtocolHandler.pm`, `Settings.pm`, or `WaveSettings.pm`. Run it with `perl t/reproduce_p0_multiaccount_bugs.pl`.
- For each new/modified `.pm` file, run `perl -c -I<repo-root's-parent-with-Plugins-symlink>` (see Task 1 for the exact throwaway-symlink trick already used by the test harness) or simply run the regression harness, which `require`s every file and will fail loudly with a Perl compile error if anything is broken — don't hand-wave "should work," always show the actual command output.
- This is a mechanical file-split for Tasks 1–4: the goal is behavior-identical code in new locations. Don't "clean up while you're at it" beyond what's specified (no renames, no dead-code removal beyond what's explicitly listed) — that's how a refactor task quietly turns into an unreviewable diff.
- Follow the existing module header convention exactly (see `WaveSettings.pm:1-11`): `package NAME;` / `use strict;` / `use warnings;` / `use utf8;` / imports / `my $log = logger('plugin.zvuk');`.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `Plugin.pm` | Menu tree, search, browse handlers (artist/album/playlist/podcast/collection), rendering helpers (`_renderTrack` etc.), account resolution (`_get_api_client`), recommendations | Shrinks from 2204 → ~1050 lines |
| `WaveWizardUI.pm` | The unused-but-kept OPML step wizard (`handleWaveWizardStart` and friends) | New |
| `WaveUI.pm` | Wave Settings OPML menu: sliders, genre/language/vocal sub-menus, the web-vs-OPML router | New |
| `GigaMix.pm` | GigaMix AI playlist generator: search/remake/add-more/next-page/rendering | New |
| `WebHandlers.pm` | Raw HTTP AJAX handlers: wave settings web UI, OAuth token capture, anonymous token | New |
| `t/reproduce_p0_multiaccount_bugs.pl` | Existing regression harness | Modified (package-qualified call sites updated) |
| `t/test_episode_playback.pl` | New | Unit test for the episode playability fix |
| `t/test_recommendation_pagination.pl` | New | Unit test for recommendation category pagination |
| `test/test_synthesis_playlists.pl`, `test/test_editorial_playlists.pl` | GraphQL discovery scripts with disproven hypotheses | Deleted |
| `test/GRAPHQL_TESTING_README.md` | References the two deleted scripts | Modified |

---

### Task 1: Extract `WaveWizardUI.pm` (the "not currently used" wizard)

**Files:**
- Create: `WaveWizardUI.pm`
- Modify: `Plugin.pm:1296-1614` (delete this block after moving it)
- Modify: `t/reproduce_p0_multiaccount_bugs.pl` (add a `require`)

**Interfaces:**
- Consumes: `Plugins::Zvuk::Plugin::_get_api_client($client)` (for `_getWizardLaunch`'s account resolution), `Plugins::Zvuk::WaveSettings::getGenres()`, `Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings)`.
- Produces: `Plugins::Zvuk::WaveWizardUI::handleWaveWizardStart($client, $callback, $args)` — not currently wired into any menu (kept for the future device-type-based routing work tracked separately), but must remain callable so re-enabling it later is a one-line change in `handleWaveSettingsRouter`.

- [ ] **Step 1: Create the new file with the moved block**

Read `Plugin.pm` lines 1310–1613 (everything between the `# WAVE SETTINGS WIZARD` banner's closing `# ====` line and the start of `_getSliderItems`) — i.e. `handleWaveWizardStart`, `_getWizardStep`, `_getWizardStepLabel`, `_getWizardPopularityStep`, `_getWizardEnergyStep`, `_getWizardFunStep`, `_getWizardLanguageStep`, `_getWizardVocalStep`, `_getWizardGenresStep`, `handleWizardStepSelect`, `handleWizardGenreToggle`, `handleWizardGenresDone`, `_getWizardLaunch` — verbatim, unchanged, into a new file:

```perl
package Plugins::Zvuk::WaveWizardUI;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::Zvuk::WaveSettings;

my $log = logger('plugin.zvuk');

# =====================================================================
# WAVE SETTINGS WIZARD - NOT CURRENTLY USED
# =====================================================================
# The wizard interface below was originally designed for OPML menu navigation
# but has been replaced with a modal-based slider form (waveSliders.html) in
# the Web UI settings page for better user experience.
#
# The wizard code is preserved here for future experimentation and can be
# re-enabled if needed by modifying handleWaveSettingsRouter to route
# Web/Material UI clients to handleWaveWizardStart instead of the web UI.
#
# For OPML clients (Jive, SqueezePlay), use handleWaveSettings instead.
# =====================================================================

<...paste the 13 subs from Plugin.pm:1310-1613 here verbatim...>

sub _getAPIHandler {
	my ($client) = @_;
	return unless $client;
	return Plugins::Zvuk::Plugin::_get_api_client($client);
}

1;
```

Inside the pasted `_getWizardLaunch`, the only cross-file reference is the existing call `_getAPIHandler($client)` — leave that call site untouched; it now resolves to the small delegating wrapper you just added at the bottom of this same file (mirrors `ProtocolHandler.pm:420-429`'s existing pattern, so don't invent a different shape).

- [ ] **Step 2: Delete the moved block from `Plugin.pm`**

Delete `Plugin.pm` lines 1296–1614 (the banner comment through the end of `_getWizardLaunch`). Line 1615 (`sub _getSliderItems`) becomes the next thing after whatever remains at line 1295 (`sub handleWaveSettings { ... }`, unchanged).

- [ ] **Step 3: Load the new module from `Plugin.pm`**

In `Plugin.pm`'s `use` block (around line 18-22), add:

```perl
use Plugins::Zvuk::WaveWizardUI;
```

(Nothing in `_buildRootMenu` currently references the wizard, so no menu wiring changes.)

- [ ] **Step 4: Update the regression harness to load the new file**

In `t/reproduce_p0_multiaccount_bugs.pl`, after line 32 (`require Plugins::Zvuk::WaveSettings;`), add:

```perl
require Plugins::Zvuk::WaveWizardUI;
```

- [ ] **Step 5: Verify**

Run: `perl t/reproduce_p0_multiaccount_bugs.pl`
Expected: `All assertions passed` and exit code 0 (same as baseline — this task changes zero behavior, only file location).

- [ ] **Step 6: Commit**

```bash
git add WaveWizardUI.pm Plugin.pm
git commit -m "refactor: extract unused Wave Settings wizard into WaveWizardUI.pm"
```

---

### Task 2: Extract `GigaMix.pm`

**Files:**
- Create: `GigaMix.pm`
- Modify: `Plugin.pm:147-218` (`_buildRootMenu`, one `url =>` line), `Plugin.pm:730-934` (delete after moving)

**Interfaces:**
- Consumes: `Plugins::Zvuk::Plugin::_get_api_client($client)`, `Plugins::Zvuk::Plugin::_renderTrack($track, $showArtist)`.
- Produces: `Plugins::Zvuk::GigaMix::handleGigaMix($client, $cb)` — this is the sub `_buildRootMenu`'s menu item must point `url =>` at.

- [ ] **Step 1: Create the new file**

Move `Plugin.pm:732-934` (`handleGigaMix` through the end of `_renderGigaMixPlaylist`, i.e. `handleGigaMix`, `handleGigaMixSearch`, `handleGigaMixRemake`, `handleGigaMixAddMore`, `handleGigaMixNextPage`, `_renderGigaMixPlaylist`) verbatim into:

```perl
package Plugins::Zvuk::GigaMix;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Control::Request;

my $log = logger('plugin.zvuk');

# --- GigaMix AI Playlist Generator ---

<...paste handleGigaMix..._renderGigaMixPlaylist from Plugin.pm:732-934 verbatim...>

1;
```

Inside the pasted code, two call sites need a package prefix (everything else — `cstring`, `$log`, `Slim::Control::Request::executeRequest`, `$client->pluginData(...)` — already works unqualified because it's either imported or a method call on `$client`):

1. In `handleGigaMixSearch` and `handleGigaMixRemake`, `_renderGigaMixPlaylist($client, $cb, $result, $prompt)` is a same-file call — **no change needed**, it stays unqualified since `_renderGigaMixPlaylist` moved into this same new file.
2. Every `_get_api_client($client)` call (in `handleGigaMixSearch`, `handleGigaMixRemake`, `handleGigaMixAddMore`, `handleGigaMixNextPage`) becomes `Plugins::Zvuk::Plugin::_get_api_client($client)`.
3. Every `_renderTrack($_, 1)` / `_renderTrack($track, 1)` call (in `handleGigaMixNextPage`, `_renderGigaMixPlaylist`) becomes `Plugins::Zvuk::Plugin::_renderTrack($_, 1)`.

- [ ] **Step 2: Delete the moved block and the now-empty section comment from `Plugin.pm`**

Delete `Plugin.pm:730-934` (the `# --- GigaMix AI Playlist Generator ---` comment through the end of `_renderGigaMixPlaylist`). What was `Plugin.pm:936` (`# --- Rendering Helpers ---`) becomes the next line after `_renderPlaylistItem` (formerly ending at line 728).

- [ ] **Step 3: Repoint the menu item and load the module**

In `Plugin.pm`'s `use` block, add:

```perl
use Plugins::Zvuk::GigaMix;
```

In `_buildRootMenu` (`Plugin.pm:180-185`), change:

```perl
		{
			name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/playlists.png',
			url   => \&handleGigaMix,
		},
```

to:

```perl
		{
			name  => cstring($client, 'PLUGIN_ZVUK_GIGAMIX'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/playlists.png',
			url   => \&Plugins::Zvuk::GigaMix::handleGigaMix,
		},
```

- [ ] **Step 4: Verify**

Run: `perl t/reproduce_p0_multiaccount_bugs.pl`
Expected: `All assertions passed`, exit 0. (This harness doesn't exercise GigaMix directly, but it will fail to even load if `Plugin.pm` or `GigaMix.pm` have a syntax error or an unresolved package-qualified call.)

Also do a manual load smoke-test since the harness doesn't hit GigaMix:

```bash
perl -e '
use FindBin qw($Bin);
require "'"$(pwd)"'/t/slim_mocks.pl";
require "'"$(pwd)"'/t/test_helpers.pl";
use File::Temp qw(tempdir);
my $tmp = tempdir(CLEANUP => 1);
mkdir "$tmp/Plugins"; symlink("'"$(pwd)"'", "$tmp/Plugins/Zvuk");
unshift @INC, $tmp;
require Plugins::Zvuk::Plugin;
print "loaded ok, handleGigaMix=", (defined &Plugins::Zvuk::GigaMix::handleGigaMix ? "yes" : "no"), "\n";
'
```

Expected: `loaded ok, handleGigaMix=yes`.

- [ ] **Step 5: Commit**

```bash
git add GigaMix.pm Plugin.pm
git commit -m "refactor: extract GigaMix handlers into GigaMix.pm"
```

---

### Task 3: Extract `WaveUI.pm`

**Files:**
- Create: `WaveUI.pm`
- Modify: `Plugin.pm:162-167` (`_buildRootMenu`'s Wave menu item), `Plugin.pm:1025-1295` and `Plugin.pm:1615-1770` (delete after moving)
- Modify: `t/reproduce_p0_multiaccount_bugs.pl`

**Interfaces:**
- Consumes: `Plugins::Zvuk::Plugin::_get_api_client($client)`, `Plugins::Zvuk::WaveSettings::{loadSettings,saveSettings,getGenres}`.
- Produces: `Plugins::Zvuk::WaveUI::{_getWaveMenuItems($client), handleWaveSettingsRouter, handleWaveSettings, handleSlider, handleGenresMenu, handleGenreToggle, handleLanguageMenu, handleLanguageSelect, handleVocalMenu, handleVocalSelect, handleSliderValue, _getAPIHandler($client)}`. `_getAPIHandler` in particular must stay a public (non-renamed) sub here — `t/reproduce_p0_multiaccount_bugs.pl:64,77` calls it directly to assert the multi-account fix still holds, and this task updates those call sites to the new package name.

- [ ] **Step 1: Create the new file**

Move two ranges from `Plugin.pm` verbatim into a single new file, in this order:

1. `Plugin.pm:1027-1295` — everything from `sub _getWaveSettingsItems` through the end of `sub handleWaveSettings` (`_getWaveSettingsItems`, `_getSliderLabel`, `_getLangLabel`, `_getVocalLabel`, `_getSettingValue`, `_updateSetting`, `handleGenresMenu`, `_getGenresMenu`, `handleGenreToggle`, `_getAPIHandler`, `handleSlider`, `_getWaveMenuItems`, `handleWaveSettingsRouter`, `handleWaveSettings`).
2. `Plugin.pm:1615-1764` — everything from `sub _getSliderItems` through the end of `sub _getVocalMenu` (`_getSliderItems`, `handleSliderValue`, `handleLanguageSelect`, `handleVocalSelect`, `handleLanguageMenu`, `_getLanguageMenu`, `handleVocalMenu`, `_getVocalMenu`).

```perl
package Plugins::Zvuk::WaveUI;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::Zvuk::WaveSettings;

my $log = logger('plugin.zvuk');

# --- Wave Settings ---

<...paste range 1 (Plugin.pm:1027-1295) verbatim...>

<...paste range 2 (Plugin.pm:1615-1764) verbatim...>

1;
```

The only sub inside these two ranges that isn't already self-contained is `_getAPIHandler` itself — it's already defined in range 1 (`Plugin.pm:1195-1203`) and already delegates to `_get_api_client($client)`. Change that one call site (inside `_getAPIHandler`'s own body) from `_get_api_client($client)` to `Plugins::Zvuk::Plugin::_get_api_client($client)`. Every other call in both ranges (`_getAPIHandler($client)`, `_getSettingValue(...)`, `_updateSetting(...)`, `_getSliderItems(...)`, `_getGenresMenu(...)`, `_getLanguageMenu(...)`, `_getVocalMenu(...)`) stays unqualified — all of those subs now live in this same new file.

- [ ] **Step 2: Delete both moved ranges from `Plugin.pm`**

Delete `Plugin.pm:1615-1764` first (the higher line range, so line numbers for the second delete don't shift), then delete `Plugin.pm:1025-1295` (including the `# --- Wave Settings ---` comment at 1025). What remains directly adjacent: `_renderEpisode` (formerly ending at 1023) is immediately followed by `_clientForWebRequest`'s leading comment (formerly at 1765-1770).

- [ ] **Step 3: Repoint the menu item and load the module**

In `Plugin.pm`'s `use` block, add:

```perl
use Plugins::Zvuk::WaveUI;
```

In `_buildRootMenu` (`Plugin.pm:162-167`), change:

```perl
		{
			name  => cstring($client, 'PLUGIN_ZVUK_WAVE'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/radio.png',
			items => _getWaveMenuItems($client),
		},
```

to:

```perl
		{
			name  => cstring($client, 'PLUGIN_ZVUK_WAVE'),
			type  => 'link',
			image => 'plugins/zvuk/html/images/radio.png',
			items => Plugins::Zvuk::WaveUI::_getWaveMenuItems($client),
		},
```

- [ ] **Step 4: Update the regression harness's call sites**

In `t/reproduce_p0_multiaccount_bugs.pl`:
- After the `require Plugins::Zvuk::WaveSettings;` line, add `require Plugins::Zvuk::WaveUI;`.
- Lines 64 and 77 (`Plugins::Zvuk::Plugin::_getAPIHandler($client)`) become `Plugins::Zvuk::WaveUI::_getAPIHandler($client)` — the test descriptions on lines 65-66 and 78-79 still say `"Plugin::_getAPIHandler resolves..."`; update the strings to say `"WaveUI::_getAPIHandler resolves..."` so the test output isn't misleading about which package it's calling.
- Line 68 and 81 (`Plugins::Zvuk::ProtocolHandler::_getAPIHandler`) are untouched — `ProtocolHandler.pm` isn't moving.

- [ ] **Step 5: Verify**

Run: `perl t/reproduce_p0_multiaccount_bugs.pl`
Expected: `All assertions passed`, exit 0 — this now specifically re-checks that `WaveUI::_getAPIHandler` (not just `Plugin::_getAPIHandler`) still resolves the live account after a switch, i.e. the extraction didn't reintroduce the P0.1 bug in its new location.

- [ ] **Step 6: Commit**

```bash
git add WaveUI.pm Plugin.pm t/reproduce_p0_multiaccount_bugs.pl
git commit -m "refactor: extract Wave Settings OPML UI into WaveUI.pm"
```

---

### Task 4: Extract `WebHandlers.pm`

**Files:**
- Create: `WebHandlers.pm`
- Modify: `Plugin.pm:29-94` (`initPlugin`'s `addRawFunction` calls), `Plugin.pm:1766-2204` (delete after moving)
- Modify: `t/reproduce_p0_multiaccount_bugs.pl`

**Interfaces:**
- Consumes: `Plugins::Zvuk::Plugin::_getUserIdForClient($client)`, `Plugins::Zvuk::WaveSettings::{loadSettings,saveSettings,getGenres}`, `Plugins::Zvuk::API::{PROFILE_URL,USER_AGENT}`.
- Produces: `Plugins::Zvuk::WebHandlers::{handleWaveSettingsWebUI, handleSaveWaveSettingsWeb, handleSaveOAuthToken, handleOAuthCallback, handleGetAnonymousToken}` — these are the five subs `initPlugin` registers with `Slim::Web::Pages->addRawFunction`.

- [ ] **Step 1: Create the new file**

Move `Plugin.pm:1766-2203` verbatim (the comment above `_clientForWebRequest` through the end of `handleGetAnonymousToken`: `_clientForWebRequest`, `handleWaveSettingsWebUI`, `handleSaveWaveSettingsWeb`, `handleSaveOAuthToken`, `handleOAuthCallback`, `handleGetAnonymousToken`):

```perl
package Plugins::Zvuk::WebHandlers;

use strict;
use warnings;
use utf8;

use JSON::XS;
use JSON::XS::VersionOneAndTwo;
use URI::QueryParam;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;

use Plugins::Zvuk::API;
use Plugins::Zvuk::WaveSettings;

my $log = logger('plugin.zvuk');

<...paste Plugin.pm:1766-2203 verbatim...>

1;
```

Inside the pasted code, the only cross-file reference is `_getUserIdForClient($client)` (used in `handleWaveSettingsWebUI` and `handleSaveWaveSettingsWeb`) — change both call sites to `Plugins::Zvuk::Plugin::_getUserIdForClient($client)`. Everything else (`_clientForWebRequest`, `Plugins::Zvuk::WaveSettings::*`, `preferences('plugin.zvuk')`, `Plugins::Zvuk::API::PROFILE_URL`/`USER_AGENT`, `encode_json`/`decode_json`, `Slim::Web::HTTP::*`) is already fully self-contained or fully qualified in the original code.

- [ ] **Step 2: Delete the moved block from `Plugin.pm`**

Delete `Plugin.pm:1766-2203`. `_renderEpisode` (ending at line 1023 after Task 3) is now the last handler in `Plugin.pm`.

- [ ] **Step 3: Repoint the five route registrations and load the module**

In `Plugin.pm`'s `use` block, add:

```perl
use Plugins::Zvuk::WebHandlers;
```

In `initPlugin` (`Plugin.pm:48-76`), change all five `Slim::Web::Pages->addRawFunction(...)` targets from `\&Plugins::Zvuk::Plugin::handleXxx` to `\&Plugins::Zvuk::WebHandlers::handleXxx`:

```perl
	if (main::WEBUI) {
		Plugins::Zvuk::Settings->new();

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/waveSettings',
			\&Plugins::Zvuk::WebHandlers::handleWaveSettingsWebUI
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/saveWaveSettings',
			\&Plugins::Zvuk::WebHandlers::handleSaveWaveSettingsWeb
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/saveOAuthToken',
			\&Plugins::Zvuk::WebHandlers::handleSaveOAuthToken
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/oauthCallback',
			\&Plugins::Zvuk::WebHandlers::handleOAuthCallback
		);

		Slim::Web::Pages->addRawFunction(
			'plugins/zvuk/getAnonymousToken',
			\&Plugins::Zvuk::WebHandlers::handleGetAnonymousToken
		);
	}
```

- [ ] **Step 4: Update the regression harness's call site**

In `t/reproduce_p0_multiaccount_bugs.pl`:
- Add `require Plugins::Zvuk::WebHandlers;` after the other requires.
- Line 106 (`Plugins::Zvuk::Plugin::handleSaveWaveSettingsWeb(undef, $response);`) becomes `Plugins::Zvuk::WebHandlers::handleSaveWaveSettingsWeb(undef, $response);`.

- [ ] **Step 5: Verify**

Run: `perl t/reproduce_p0_multiaccount_bugs.pl`
Expected: `All assertions passed`, exit 0 — the P0.2 assertions (lines 108-114) now specifically confirm `WebHandlers::handleSaveWaveSettingsWeb` still resolves the real account from `?player=`, not just that it moved without erroring.

- [ ] **Step 6: Commit**

```bash
git add WebHandlers.pm Plugin.pm t/reproduce_p0_multiaccount_bugs.pl
git commit -m "refactor: extract web/OAuth AJAX handlers into WebHandlers.pm"
```

---

### Task 5: Final size/sanity check on the split

**Files:** None changed — verification only.

- [ ] **Step 1: Confirm the line-count shift matches expectations**

Run: `wc -l Plugin.pm WaveWizardUI.pm GigaMix.pm WaveUI.pm WebHandlers.pm`
Expected: `Plugin.pm` around 1000-1100 lines (down from 2204); the four new files sum to roughly the difference. If `Plugin.pm` is still close to 2000 lines, a move step was skipped — go back and check.

- [ ] **Step 2: Confirm no leftover unqualified calls to moved subs**

Run: `grep -n "\\\\&handle\(WaveWizard\|GigaMix\|WaveSettings\|Slider\|GenresMenu\|GenreToggle\|LanguageMenu\|LanguageSelect\|VocalMenu\|VocalSelect\|SaveWaveSettingsWeb\|SaveOAuthToken\|OAuthCallback\|GetAnonymousToken\)" Plugin.pm`
Expected: no output (every reference to a moved handler in `Plugin.pm` should now be fully package-qualified, or gone entirely because the whole call site moved with it).

- [ ] **Step 3: Full regression run**

Run: `perl t/reproduce_p0_multiaccount_bugs.pl`
Expected: `All assertions passed`, exit 0.

- [ ] **Step 4: Commit (only if Steps 1-2 required fixes; otherwise skip, nothing to commit)**

---

### Task 6: Fix unplayable podcast episodes

Per `docs/zvuk_api.md:626-639` (APK-verified): episodes have their own `id` (used by `getEpisodes`) plus a separate `trackId` — streaming goes through `mediaContents(ids: [$episodeTrackId]) { ... on Episode { stream { mid high } } }`, the same union query tracks already use. There is no `flac`/`flacdrm` for episodes, only `mid`/`high`. The design below plays an episode by putting its `trackId` — not its own `id` — directly into a plain `zvuk://<trackId>` URL, exactly like a normal track. This needs **zero `ProtocolHandler.pm` changes**, because the existing `zvuk://(\d+)` parsing, `getStream`'s `high`/`mid` fallback chain, and `getFormatForURL`'s already-existing typed-URL guard (`zvuk://\w+:`, which only matches when there's a `:` after the scheme) never see anything episode-specific — from `ProtocolHandler.pm`'s point of view it's just another track ID. (This diverges from `COMPARISON_REPORT.md:364`'s literal suggestion of a `zvuk://episode:<id>` URL scheme; that scheme would require teaching `getNextTrack`/`getMetadataFor` a second ID-resolution path for no functional benefit today. If a future feature needs the episode's own `id` — e.g. liking an episode — solve that then, don't build it now.)

**Files:**
- Modify: `API/Async.pm:531-567` (`getPodcastEpisodes`'s inner `getEpisodes` query — add `trackId`)
- Modify: `API/Async.pm:414-432` (`getTracks` — add an `Episode` fragment)
- Modify: `API/Async.pm:435-459` (`getStream` — add an `Episode` fragment)
- Modify: `Plugin.pm:1011-1023` (`_renderEpisode`)
- Test: `t/test_episode_playback.pl`

**Interfaces:**
- Consumes: `Plugins::Zvuk::API->getImageUrl($item)` (unchanged, already used).
- Produces: `_renderEpisode($episode)` now returns `{ type => 'audio', url => 'zvuk://<trackId>', play => same, on_select => 'play', playall => 1, ... }` when `$episode->{trackId}` is present, and falls back to the previous non-playable `type => 'text'` row when it's absent (defensive — don't crash the podcast browse menu if the API ever omits it).

- [ ] **Step 1: Write the failing test**

Create `t/test_episode_playback.pl`:

```perl
#!/usr/bin/env perl
# Regression test for the podcast-episode playability fix.
# Run: perl t/test_episode_playback.pl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;

my $failures = 0;
sub ok {
    my ($cond, $desc) = @_;
    if ($cond) { print "ok - $desc\n"; }
    else { print "NOT OK - $desc\n"; $failures++; }
}

# Episode with a trackId (the common case once the API fix lands)
my $episode = {
    id       => 'ep1',
    title    => 'Episode One',
    duration => 1800,
    trackId  => 'trk999',
    podcast  => { id => 'pod1', title => 'My Podcast' },
};

my $item = Plugins::Zvuk::Plugin::_renderEpisode($episode);

ok($item->{type} eq 'audio', "_renderEpisode with trackId returns type=audio (was 'text')");
ok($item->{url} eq 'zvuk://trk999', "_renderEpisode uses the episode's trackId as the play URL, not its own id");
ok($item->{play} eq 'zvuk://trk999', "play field matches url field");
ok($item->{on_select} eq 'play', "on_select is 'play'");
ok($item->{playall} == 1, "playall is set so the podcast queue can autoplay");
ok($item->{line2} eq 'My Podcast', "line2 still shows the podcast title");

# Episode without a trackId (defensive fallback - must not crash the menu)
my $episode_no_track = {
    id       => 'ep2',
    title    => 'Episode Two',
    duration => 900,
    podcast  => { id => 'pod1', title => 'My Podcast' },
};
my $item2 = Plugins::Zvuk::Plugin::_renderEpisode($episode_no_track);
ok($item2->{type} eq 'text', "_renderEpisode without trackId falls back to non-playable type=text");
ok(!exists $item2->{url}, "no url field when there's no trackId to play");

print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");
exit($failures ? 1 : 0);
```

- [ ] **Step 2: Run it to verify it fails**

Run: `perl t/test_episode_playback.pl`
Expected: FAIL — the first assertion fails because current `_renderEpisode` always returns `type => 'text'` with no `url`/`play`/`on_select`/`playall` fields at all.

- [ ] **Step 3: Add `trackId` to the `getEpisodes` query**

In `API/Async.pm`, inside `getPodcastEpisodes` (around line 553-560), change:

```perl
		my $gql2 = q{
			query getEpisodes($ids: [ID!]!) {
				getEpisodes(ids: $ids) {
					id title duration
					image { src }
					podcast { id title image { src } }
				}
			}
		};
```

to:

```perl
		my $gql2 = q{
			query getEpisodes($ids: [ID!]!) {
				getEpisodes(ids: $ids) {
					id title duration trackId
					image { src }
					podcast { id title image { src } }
				}
			}
		};
```

- [ ] **Step 4: Add an `Episode` fragment to `getTracks` and `getStream`**

In `API/Async.pm`, `getTracks` (around line 417-426), change:

```perl
	my $gql = q{
		query getTracks($ids: [ID!]!) {
			mediaContents(ids: $ids) {
				... on Track {
					id title duration availability artistTemplate
					release { id title image { src } }
				}
			}
		}
	};
```

to:

```perl
	my $gql = q{
		query getTracks($ids: [ID!]!) {
			mediaContents(ids: $ids) {
				... on Track {
					id title duration availability artistTemplate
					release { id title image { src } }
				}
				... on Episode {
					id title duration
					podcast { id title image { src } }
				}
			}
		}
	};
```

In `getStream` (around line 438-453), change:

```perl
	my $gql = q{
		query getStream($ids: [ID!]!) {
			mediaContents(ids: $ids) {
				... on Track {
					id
					duration
					stream {
						high
						mid
						flac
						flacdrm
					}
				}
			}
		}
	};
```

to:

```perl
	my $gql = q{
		query getStream($ids: [ID!]!) {
			mediaContents(ids: $ids) {
				... on Track {
					id
					duration
					stream {
						high
						mid
						flac
						flacdrm
					}
				}
				... on Episode {
					id
					duration
					stream {
						high
						mid
					}
				}
			}
		}
	};
```

- [ ] **Step 5: Fix `_renderEpisode`**

In `Plugin.pm`, change (currently lines 1011-1023):

```perl
sub _renderEpisode {
	my ($episode) = @_;
	my $podcast_name = $episode->{podcast} ? $episode->{podcast}->{title} : "Podcast";
	return {
		name      => $episode->{title},
		line1     => $episode->{title},
		line2     => $podcast_name,
		duration  => $episode->{duration},
		secs      => $episode->{duration},
		type      => 'text',
		image     => $episode->{podcast} ? Plugins::Zvuk::API->getImageUrl($episode->{podcast}) : "",
	};
}
```

to:

```perl
sub _renderEpisode {
	my ($episode) = @_;
	my $podcast_name = $episode->{podcast} ? $episode->{podcast}->{title} : "Podcast";
	my $image = $episode->{podcast} ? Plugins::Zvuk::API->getImageUrl($episode->{podcast}) : "";

	unless ($episode->{trackId}) {
		return {
			name      => $episode->{title},
			line1     => $episode->{title},
			line2     => $podcast_name,
			duration  => $episode->{duration},
			secs      => $episode->{duration},
			type      => 'text',
			image     => $image,
		};
	}

	my $url = 'zvuk://' . $episode->{trackId};
	return {
		name      => $episode->{title},
		line1     => $episode->{title},
		line2     => $podcast_name,
		duration  => $episode->{duration},
		secs      => $episode->{duration},
		on_select => 'play',
		url       => $url,
		play      => $url,
		playall   => 1,
		type      => 'audio',
		image     => $image,
	};
}
```

- [ ] **Step 6: Run the new test to verify it passes**

Run: `perl t/test_episode_playback.pl`
Expected: `All assertions passed`, exit 0.

- [ ] **Step 7: Run the full regression harness**

Run: `perl t/reproduce_p0_multiaccount_bugs.pl`
Expected: `All assertions passed`, exit 0 (this task didn't touch anything the P0 harness covers, but confirm anyway since `Plugin.pm` changed).

- [ ] **Step 8: Manual live-account verification (cannot be mocked)**

This is the one part of the plan that depends on Zvuk's real GraphQL schema actually shaping `mediaContents` the way `docs/zvuk_api.md:639` documents — the mocked tests above only prove the Perl logic is correct given that shape, not that the shape is correct. Before considering this task fully done: log into a real LMS instance with this plugin, browse to a podcast with episodes, select an episode, and confirm audio actually plays (not just that the menu item now looks like a track). If it fails, check the LMS server log for the actual `mediaContents` response shape for an episode `trackId` and adjust the `Episode` fragment fields in Step 4 to match what the live API actually returns.

- [ ] **Step 9: Commit**

```bash
git add API/Async.pm Plugin.pm
git commit -m "fix: make podcast episodes playable via their trackId"
```

(`t/test_episode_playback.pl` is gitignored — nothing to add there.)

---

### Task 7: Add pagination to recommendation categories

Per `COMPARISON_REPORT.md:117`: `handleRecommendationArtists/Albums/Playlists` always request `pages: [1]` and never expose a "Next page" link, unlike `_searchGeneric` which already has cursor pagination (`Plugin.pm:332-339`). `API/Async.pm::getMusicRecommendations` (`API/Async.pm:1056-1161`) already accepts a `page` arg and returns `totalPages` — it just isn't being used by the three category handlers.

**Files:**
- Modify: `Plugin.pm:604-692` (`handleRecommendationArtists`, `handleRecommendationAlbums`, `handleRecommendationPlaylists`)
- Test: `t/test_recommendation_pagination.pl`

**Interfaces:**
- Consumes: `Plugins::Zvuk::API::Async::getMusicRecommendations($cb, { contentType, itemTypes, page })` → `$cb->({ artists/releases/playlists, totalPages, totalCount, error })` (unchanged existing shape).
- Produces: each of the three handlers now accepts `($client, $cb, $args, $params)` (was `($client, $cb)`) and reads `$params->{page} // 1`; when the result's `totalPages` is greater than the requested page, appends a `NEXT_PAGE` link item whose `passthrough` carries `{ page => $page + 1 }`, mirroring `_searchGeneric`'s cursor-link shape at `Plugin.pm:332-339`.

- [ ] **Step 1: Write the failing test**

Create `t/test_recommendation_pagination.pl`:

```perl
#!/usr/bin/env perl
# Regression test for recommendation-category pagination.
# Run: perl t/test_recommendation_pagination.pl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::API::Async;

my $failures = 0;
sub ok {
    my ($cond, $desc) = @_;
    if ($cond) { print "ok - $desc\n"; }
    else { print "NOT OK - $desc\n"; $failures++; }
}

{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
        acctA => { token => 'tokA', name => 'Account A' },
    };
}
my $client = Test::FakeClient->new(id => 'player1');
$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';

# Stub the network call: record which page was requested, return a
# canned two-page result so we can assert on both "has next" and "no next".
my $requested_page;
no warnings 'redefine';
local *Plugins::Zvuk::API::Async::getMusicRecommendations = sub {
    my ($self, $cb, $args) = @_;
    $requested_page = $args->{page};
    $cb->({
        artists    => [ { id => 'a1', title => 'Artist One' } ],
        releases   => [],
        playlists  => [],
        totalPages => 2,
        totalCount => 1,
    });
};

# --- Page 1: expect a Next Page link present ---
my $result1;
Plugins::Zvuk::Plugin::handleRecommendationArtists($client, sub { $result1 = shift }, {}, {});
ok($requested_page == 1, "handleRecommendationArtists defaults to page 1 when no passthrough given");
my @next_links1 = grep { $_->{url} && $_->{passthrough} } @{ $result1->{items} };
ok(scalar(@next_links1) == 1, "page 1 of 2 shows exactly one Next Page link");
ok($next_links1[0]->{passthrough}[0]{page} == 2, "Next Page link passes page=2");

# --- Page 2: expect no Next Page link (totalPages == page) ---
my $result2;
Plugins::Zvuk::Plugin::handleRecommendationArtists($client, sub { $result2 = shift }, {}, { page => 2 });
ok($requested_page == 2, "handleRecommendationArtists honors passthrough page=2");
my @next_links2 = grep { $_->{url} && $_->{passthrough} } @{ $result2->{items} };
ok(scalar(@next_links2) == 0, "page 2 of 2 shows no Next Page link");

print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");
exit($failures ? 1 : 0);
```

- [ ] **Step 2: Run it to verify it fails**

Run: `perl t/test_recommendation_pagination.pl`
Expected: FAIL — `handleRecommendationArtists($client, $cb, {}, {})` errors out or ignores the extra args (current signature is `my ($client, $cb) = @_;`), and it always calls `getMusicRecommendations` without a `page` key at all, so `$requested_page` stays `undef` and the first `ok` fails.

- [ ] **Step 3: Implement pagination in all three handlers**

In `Plugin.pm`, change (currently lines 604-632):

```perl
sub handleRecommendationArtists {
	my ($client, $cb) = @_;
	my $api = _get_api_client($client);

	$api->getMusicRecommendations(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("getMusicRecommendations failed: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_ERROR'), type => 'text' },
			]});
			return;
		}

		my $artists = $result->{artists} || [];
		unless (@$artists) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_EMPTY'), type => 'text' },
			]});
			return;
		}

		$cb->({ items => [ map { _renderArtist($_) } @$artists ] });
	}, {
		contentType => 'Music',
		itemTypes   => ['Artist', 'Release', 'Playlist'],
	});
}
```

to:

```perl
sub handleRecommendationArtists {
	my ($client, $cb, $args, $params) = @_;
	my $api = _get_api_client($client);
	my $page = ($params && $params->{page}) || 1;

	$api->getMusicRecommendations(sub {
		my $result = shift || {};

		if ($result->{error}) {
			$log->error("getMusicRecommendations failed: $result->{error}");
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_ERROR'), type => 'text' },
			]});
			return;
		}

		my $artists = $result->{artists} || [];
		unless (@$artists) {
			$cb->({ items => [
				{ name => cstring($client, 'PLUGIN_ZVUK_RECOMMENDATIONS_EMPTY'), type => 'text' },
			]});
			return;
		}

		my @items = map { _renderArtist($_) } @$artists;

		if (($result->{totalPages} || 1) > $page) {
			push @items, {
				name        => cstring($client, 'NEXT_PAGE'),
				type        => 'link',
				url         => \&handleRecommendationArtists,
				passthrough => [{ page => $page + 1 }],
			};
		}

		$cb->({ items => \@items });
	}, {
		contentType => 'Music',
		itemTypes   => ['Artist', 'Release', 'Playlist'],
		page        => $page,
	});
}
```

Apply the identical shape to `handleRecommendationAlbums` (lines 634-662: swap `$result->{releases}` / `_renderAlbum` / `\&handleRecommendationAlbums`) and `handleRecommendationPlaylists` (lines 664-692: swap `$result->{playlists}` / `_renderPlaylist` / `\&handleRecommendationPlaylists`). Do not change `handleRecommendations` (the category-count menu at lines 541-602) — it only ever needs page 1 to show category counts, that's out of scope here.

- [ ] **Step 4: Run the new test to verify it passes**

Run: `perl t/test_recommendation_pagination.pl`
Expected: `All assertions passed`, exit 0.

- [ ] **Step 5: Run the full regression harness**

Run: `perl t/reproduce_p0_multiaccount_bugs.pl`
Expected: `All assertions passed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Plugin.pm
git commit -m "fix: add Next Page pagination to recommendation categories"
```

---

### Task 8: Retire the two disproven GraphQL discovery scripts

Per `COMPARISON_REPORT.md:367`: both scripts print out several *hypotheses* about GraphQL operation names for synthesis/editorial playlists (`getShortPlaylist`, `getPlaylistsShort`, GraphQL for editorial) that were investigated and found wrong — the real answers (`getPlaylists(ids: ...)` for synthesis, REST `/api/tiny/grid/content?name=editorial_playlist` for editorial) are now documented directly in `COMPARISON_REPORT.md` §4. Keeping the scripts around risks a future reader following their curl instructions and rediscovering the same dead end.

**Files:**
- Delete: `test/test_synthesis_playlists.pl`
- Delete: `test/test_editorial_playlists.pl`
- Modify: `test/GRAPHQL_TESTING_README.md`

**Interfaces:** None — this task has no code interfaces, it only removes stale investigation scripts and their README references.

- [ ] **Step 1: Delete both scripts**

```bash
rm test/test_synthesis_playlists.pl test/test_editorial_playlists.pl
```

- [ ] **Step 2: Update the README**

Read `test/GRAPHQL_TESTING_README.md` in full first (it's short, ~130 lines) to see exactly how it references both scripts (sections "1. `test_synthesis_playlists.pl`" and "2. `test_editorial_playlists.pl`", plus a "Phase 1: Manual Testing" section). Replace both numbered sections and any "Phase 1" instructions that tell the reader to run them with a short note pointing at the real answer, e.g.:

```markdown
### Synthesis & editorial playlists

These used to be open GraphQL-operation-name questions investigated via
`test_synthesis_playlists.pl` / `test_editorial_playlists.pl` (both removed
2026-07-09 — their hypotheses were wrong). The confirmed answers are in
`COMPARISON_REPORT.md` §4:

- Synthesis playlists: `getPlaylists(ids: [3,4,6,11-15])`, operation name
  `getShortPlaylist`.
- Editorial playlists: REST, not GraphQL —
  `/api/tiny/grid/content?name=editorial_playlist`.
```

Leave the rest of the README (any sections about `test_graphql_requests.pl` / `test_curl_examples.sh` that aren't about these two disproven scripts) untouched.

- [ ] **Step 3: Verify**

Run: `grep -rn "test_synthesis_playlists\|test_editorial_playlists" test/`
Expected: no output (both files gone, no dangling references left in the README or elsewhere in `test/`).

- [ ] **Step 4: Commit**

Since `/test/` is gitignored, there is nothing for git to track here — skip the commit step for this task. (If the user later un-ignores `test/`, this step would become `git add -u test/ && git commit -m "chore: remove disproven GraphQL discovery scripts"`.)

---

## Self-Review Notes

- **Spec coverage:** all 4 non-superseded items of `COMPARISON_REPORT.md` P3.4 are covered — item 1 (split, Tasks 1-4), item 3 (episodes, Task 6), item 4 (pagination, Task 7), item 6 (retire scripts, Task 8). Item 2 (single API-client mechanism) is explicitly out of scope — already shipped as P0.1. Item 5 (build out a broader unit-test suite for Throttle/Retry/WaveSettings/`_getArtistName`) is intentionally **not** in this plan — it's a separately-sized initiative per the roadmap memory, not part of "Stage 1," and folding it in here would blow up the scope of a hygiene pass into a testing initiative.
- **Wizard code fate:** kept and moved (per explicit user decision earlier in this conversation), not deleted — Task 1 reflects that, contradicting `COMPARISON_REPORT.md`'s "delete" framing on purpose.
- **Episode URL scheme:** deliberately diverges from `COMPARISON_REPORT.md`'s literal `zvuk://episode:<id>` suggestion in favor of reusing the plain `zvuk://<trackId>` scheme — documented inline in Task 6 with the reasoning, so a reviewer isn't surprised by the deviation.
