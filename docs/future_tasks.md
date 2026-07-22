# Roadmap & Future Tasks for lms-zvuk

This document outlines the planned roadmap and future tasks for the **LMS Zvuk Plugin**, along with references to local source files and adjacent repositories on the development system.

---

## 1. References & Information Sources

To implement the tasks below, refer to the following local codebases and guides:

* **This Plugin**: `/home/chernysh/Projects/lms-zvuk/`
* **Reference Plugin (Yandex Music)**: `/home/chernysh/Projects/yandex/`
  * Check `Browse/InfoMenu.pm` for LMS `TrackInfo`, `AlbumInfo`, `ArtistInfo` context menu providers.
  * Check `Plugin.pm` for InfoProvider registration patterns.
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

### 2. Context Menus & Actions (Track, Album, Playlist, Artist)
Implement LMS InfoProviders (`Slim::Menu::TrackInfo`, `Slim::Menu::AlbumInfo`, `Slim::Menu::ArtistInfo`) in `Plugins::Zvuk::Browse::InfoMenu`:
* **Track Context Menu**: Like/Unlike, Dislike/Hide from Wave (`addHiddenItem`), Start Personal Wave seeded by track, Add to User Playlist, View Artist/Album on Zvuk.
* **Album Context Menu**: Like/Unlike album, View Artist on Zvuk, Search album on Zvuk.
* **Artist Context Menu**: Like/Unlike artist, View albums/top tracks on Zvuk.
* **Playlist Context Menu**: Save/Unsave playlist, Add/Remove tracks (for user-owned playlists).

### 3. Library & Favorites Integration
* **Favorites Sync**: Automatically synchronize user favorite tracks, albums, and artists from Zvuk into the native LMS database so they appear alongside local files in the "My Music" library.
* **Unified Search**: Integrate Zvuk search results into the native LMS global search.

### 4. Personal Wave Enhancements
* **Infinite Wave (Don't Stop The Music)**: Integrate with LMS's `DontStopTheMusic` hook to automatically request more wave tracks when the current queue approaches the end.

### 5. Audiobooks & Podcasts
* **Podcasts**: Implement podcast browsing (`getPodcasts`) and episode playback (`getEpisodes`).
* **Audiobooks**: Implement audiobook details (`getBooks`), authors (`getBookAuthors`), and chapter playback (`getChapters`).

### 6. Playback History & Telemetry (Clickstream)
* **Telemetry Reporting**: Post play events to Zvuk's `/api/tiny/clickstream` (or `topics/cs_v4_raw_events` Kafka endpoints) when a track finishes or is skipped, ensuring the recommender dynamically adapts to user tastes in real-time. (See Section 3 for reverse engineering details).

### 7. Streaming Quality
* **Widevine DRM Investigation**: Research the `stream.flacdrm` URL to determine if lossless FLAC playback can be enabled in LMS (which natively does not support DRM-encrypted streams).

### 8. User Playlists Management
* **Playlist Actions**: Add support for creating, deleting, and editing Zvuk playlists (`addItemsToPlaylist`, `removeItemsFromPlaylist`, `setPublicVisibility`).

### 9. Authentication
* **SMS OTP Login**: Add support for logging in via phone number and SMS code (`/api/tiny/login/otp`).
* **SberID SSO**: Support SberID OAuth login.

### 10. Library Transfer Tool (Перенос библиотеки)
* **Library Migration**: Implement a script or built-in tool to copy a user's library (favorite tracks, albums, artists, and custom playlists) from one Zvuk account to another. 
  * Read from source account using token A via `userCollection`/`paginatedCollection`.
  * Batch-write to destination account using token B via `addCollectionItems` mutation (tracks, albums, artists) and playlist mutations (`createPlaylistV1` + `addItemsToPlaylist`).

---

## 3. Deep Dive: Clickstream Telemetry (Analytics v4 Architecture)

Based on reverse engineering of the official Zvuk Android app (`/home/chernysh/Projects/android_zvuk/`) and API specifications:

### 1. Codebase Sources & References
* **Retrofit2 Kafka Interface**: `defpackage/elv.java`
* **Event DTO & Enum**: `com.zvuk.network.models.rest.analytics.event.AnalyticsV4EventDto`
* **Local Offline SQLite Database**: `defpackage/asa.java` (tables: `analytics_v4_event`, `analytics_activity_context`, `analytics_device_context`).
* **REST Clickstream Endpoint**: `POST https://zvuk.com/api/tiny/clickstream`

### 2. Event Payload Structure (Kafka JSON Schema)

```json
{
  "records": [
    {
      "key": "777701291",
      "value": {
        "user_id": "777701291",
        "event_type": "play_stop",
        "event_client_timestamp": "2026-07-22T12:45:00.000Z",
        "event_send_timestamp": "2026-07-22T12:45:05.000Z",
        "event_body": {
          "track_id": "12345678",
          "played_duration_sec": 180,
          "total_duration_sec": 210,
          "source": "AMAZME"
        }
      }
    }
  ]
}
```

### 3. Key Telemetry Event Types (`AnalyticsV4EventDto.Type`)

| Event Type | Enum String | Description / Trigger |
|------------|-------------|-----------------------|
| `PLAY_START` | `play_start` | Triggered when a track begins playback |
| `PLAY_STOP` | `play_stop` | Triggered when playback stops or finishes (contains `played_duration_sec`) |
| `TAP_NEXT` | `tap_next` | User skipped to the next track |
| `TAP_PREV` | `tap_prev` | User navigated to the previous track |
| `PAUSE` | `pause` | Playback paused |
| `RESUME` | `resume` | Playback resumed |
| `LIKE` / `UNLIKE` | `like` / `unlike` | User liked or unliked a track/artist/release |
| `TUNER_SET` | `tuner_set` | User updated Personal Wave sliders (energy, fun, mood) |

---

## 4. Deep Dive: LMS Context Menus Architecture (`InfoProviders`)

Based on reference implementation from `/home/chernysh/Projects/yandex/Browse/InfoMenu.pm`:

### 1. LMS InfoProvider Registration (in `Plugin.pm`)

```perl
# Register Track InfoProvider
Slim::Menu::TrackInfo->registerInfoProvider( zvuk => (
    func => \&Plugins::Zvuk::Browse::InfoMenu::trackInfoMenu,
) );

# Register Album InfoProvider
Slim::Menu::AlbumInfo->registerInfoProvider( zvuk => (
    func => \&Plugins::Zvuk::Browse::InfoMenu::albumInfoMenu,
) );

# Register Artist InfoProvider
Slim::Menu::ArtistInfo->registerInfoProvider( zvuk => (
    func => \&Plugins::Zvuk::Browse::InfoMenu::artistInfoMenu,
) );
```

### 2. Context Menu Invocation Points
- **Web UI & Material Skin**: Triggered when clicking the 3-dots context menu icon (`...`) or track/album action menu.
- **SqueezePlay & Jive**: Triggered when pressing the hold/more button or right arrow on a selected item.
- **VFD Button Players (Boom, Classic, Transporter)**: Triggered when pressing the `HOLD` or `NOW PLAYING` / `INFO` buttons during playback or browsing.

### 3. Implementation Blueprint (`Plugins/Zvuk/Browse/InfoMenu.pm`)

#### Track Context Menu (`trackInfoMenu`)
Returns a hash ref:
```perl
{
    name => 'Звук',
    items => [
        { name => 'Нравится (Лайк)', type => 'link', url => \&_doLikeTrack, passthrough => [$trackId] },
        { name => 'Не нравится (Скрыть из волны)', type => 'link', url => \&_doDislikeTrack, passthrough => [$trackId] },
        { name => 'Моя волна по этому треку', type => 'audio', url => "zvuk://wave?track_id=$trackId", play => "zvuk://wave?track_id=$trackId" },
        { name => 'Добавить в плейлист...', type => 'link', url => \&handleAddToPlaylistMenu, passthrough => [$trackId] },
        { name => 'Исполнитель на Zvuk', type => 'link', url => \&handleSearchArtist, passthrough => [$artistName] },
        { name => 'Альбом на Zvuk', type => 'link', url => \&handleSearchAlbum, passthrough => [$albumName] },
    ]
}
```
