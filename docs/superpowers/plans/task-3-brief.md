# Task 3: Add Menu Item to Root Menu

**Where this fits:** Third of 6 tasks. Tasks 1-2 complete (API + handler). This task exposes the handler in the menu.

**What to build:**
Add menu item to `_buildRootMenu()` in Plugin.pm that links to the `handlePersonalizedPlaylists` handler.

**Exact Implementation:**

Find `_buildRootMenu()` method in Plugin.pm (around line 141).

Locate the Wave section (lines 156-161):
```perl
{
    name  => cstring($client, 'PLUGIN_ZVUK_WAVE'),
    type  => 'link',
    image => 'plugins/zvuk/html/images/radio.png',
    items => _getWaveMenuItems($client),
},
```

Right after this block, add (before GigaMix):
```perl
{
    name  => cstring($client, 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS'),
    type  => 'link',
    image => 'plugins/zvuk/html/images/playlists.png',
    url   => \&handlePersonalizedPlaylists,
},
```

**Position:** After Wave section, before GigaMix section (which starts at line 162)

**Localization keys used:**
- `PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS` — menu item title (will be added in Task 4)

**Testing:**
1. Verify Perl syntax: `perl -c Plugin.pm`
2. Check menu structure by reading code: Wave → Personalized → GigaMix order
3. Run existing tests to verify no regressions

**No TDD here** — this is a simple one-line menu integration, not a logical unit with tests. Just edit Plugin.pm and verify syntax.

**Commit message:** `feat: Add Personalized Playlists to root menu`

