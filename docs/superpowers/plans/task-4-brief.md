# Task 4: Add Localization Strings

**Where this fits:** Fourth of 6 tasks. Tasks 1-3 complete. This task adds the English and Russian strings needed by the handler and menu.

**What to build:**
Add 3 localization string keys to `strings.txt`:
1. `PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS` — Menu item title
2. `PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY` — Message when no playlists available
3. `PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR` — Message when API error occurs

**Exact format:**
Each string follows LMS convention: key, then tabs, then language code, then string.

Append these to the end of the PLUGIN_ZVUK section in strings.txt (after PLUGIN_ZVUK_GIGAMIX_ERROR_CURSOR):

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

**Critical notes:**
- Use TAB characters between language code and string (not spaces)
- Exact strings as shown (EN/RU pairs must match)
- Position: at end of PLUGIN_ZVUK section, before next section (if any)
- No duplicate keys

**Testing:**
1. Verify strings are readable: `grep "PLUGIN_ZVUK_PERSONALIZED" strings.txt`
2. Run existing tests (no code changes, so all should still pass)

**No TDD here** — just adding data to strings.txt.

**Commit message:** `feat: Add Personalized Playlists localization strings`

