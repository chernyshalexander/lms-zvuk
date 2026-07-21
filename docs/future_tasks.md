# Roadmap & Future Tasks for lms-zvuk

This document outlines the planned roadmap and future tasks for the **LMS Zvuk Plugin**, along with references to local source files and adjacent repositories on the development system.

---

## 1. References & Information Sources

To implement the tasks below, refer to the following local codebases and guides:

* **This Plugin**: `/home/chernysh/Projects/lms-zvuk/`
* **Guides & API Documentation**: `/home/chernysh/Projects/lms-zvuk-guides/docs/`
  * Check `zvuk_api.md` (detailed endpoints, structures, and variables)
  * Check `GIGAMIX_API_EXAMPLES.md` (GigaMix implementation hints)
  * Check `architecture.md` (overall design)
* **Python API Client (Reference)**: `/home/chernysh/Projects/zvuk-music/zvuk_music/`
  * Look at `client.py` and `client_async.py` for API requests.
* **Music Assistant Provider (Reference)**: `/home/chernysh/Projects/ma-provider-zvuk-music/`
* **Decompiled Android App (Reference)**: `/home/chernysh/Projects/android_zvuk/`
* **SberZvuk API JS Library (Reference)**: `/home/chernysh/Projects/sberzvuk-api/src/`

---

## 2. Future Tasks Roadmap

### 1. Curated Lists & Content Grid (REST Grid Content)
Add support for the `/api/tiny/grid/content` endpoint to fetch and display curated playlists, genre releases, and editorial selections on the main menu:
* **Gold Popular Playlists**: `/api/tiny/grid/content?name=gold_popular_playlists`
* **Calm Playlists**: `/api/tiny/grid/content?name=calm_playlists`
* **Relax Playlists of the Week**: `/api/tiny/grid/content?name=week_relax_playlists`
* **New Jazz Releases**: `/api/tiny/grid/content?name=jazz_releases_new`
* **ECM Jazz Playlists**: `/api/tiny/grid/content?name=ecm_jazz_playlist`
* **Jazz Subgenres Playlists**: `/api/tiny/grid/content?name=jazz_subgenres_playlists`

### 2. Library & Favorites Integration
* **Favorites Sync**: Automatically synchronize user favorite tracks, albums, and artists from Zvuk into the native LMS database so they appear alongside local files in the "My Music" library.
* **Likes & Dislikes**: Add actions (heart button / context menus) in Web, Material, SqueezePlay, and physical displays to:
  * Like or unlike currently playing or browsed tracks, albums, and artists (`addItemV1`, `removeItem` mutations).
  * Dislike or hide tracks and artists from Personal Wave recommendations (`addHiddenItem` mutation).
* **Unified Search**: Integrate Zvuk search results into the native LMS global search.

### 3. Personal Wave Enhancements
* **Infinite Wave (Don't Stop The Music)**: Integrate with LMS's `DontStopTheMusic` hook to automatically request more wave tracks when the current queue approaches the end.

### 4. Audiobooks & Podcasts
* **Podcasts**: Implement podcast browsing (`getPodcasts`) and episode playback (`getEpisodes`).
* **Audiobooks**: Implement audiobook details (`getBooks`), authors (`getBookAuthors`), and chapter playback (`getChapters`).

### 5. Playback History & Telemetry (Clickstream)
* **Telemetry Reporting**: Post play events to Zvuk's `/api/tiny/clickstream` (or cs_v4 Kafka endpoints) when a track finishes or is skipped, ensuring the recommender dynamically adapts to user tastes.

### 6. Streaming Quality
* **Widevine DRM Investigation**: Research the `stream.flacdrm` URL to determine if lossless FLAC playback can be enabled in LMS (which natively does not support DRM-encrypted streams).

### 7. User Playlists Management
* **Playlist Actions**: Add support for creating, deleting, and editing Zvuk playlists (`addItemsToPlaylist`, `removeItemsFromPlaylist`, `setPublicVisibility`).

### 8. Authentication
* **SMS OTP Login**: Add support for logging in via phone number and SMS code (`/api/tiny/login/otp`).
* **SberID SSO**: Support SberID OAuth login.

### 9. Library Transfer Tool (Перенос библиотеки)
* **Library Migration**: Implement a script or built-in tool to copy a user's library (favorite tracks, albums, artists, and custom playlists) from one Zvuk account to another. 
  * Read from source account using token A via `userCollection`/`paginatedCollection`.
  * Batch-write to destination account using token B via `addCollectionItems` mutation (tracks, albums, artists) and playlist mutations (`createPlaylistV1` + `addItemsToPlaylist`).
