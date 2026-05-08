# Zvuk LMS Plugin: Development Status & Hand-over Notes

## 📌 Project Overview
This plugin integrates the **Zvuk.com** (SberZvuk) music service into **Lyrion Music Server (LMS)**. It supports high-quality streaming (FLAC/MP3 320), personalized features like "Personal Wave", and user library browsing.

---

## 🚀 Current State (Production-Ready MVP)

### 1. Streaming & Audio
- **Protocol**: `HTTPS` based, inheriting from `Slim::Player::Protocols::HTTPS`.
- **Quality**: Supports `FLAC` (lossless), `High` (MP3 320kbps), and `Mid` (MP3 128kbps).
- **Resolution Strategy**: Uses GraphQL `getStream` query (fastest, provides `duration` in response). It checks both `flac` and `flacdrm` fields to find playable lossless streams.

### 2. Personalization & Browsing
- **Personal Wave (Моя Волна)**: Fully functional via `personalWaveContent` operation.
- **User Collection**: "Liked Tracks" and "User Playlists" are accessible.
- **Artist/Album/Search**: Standard browsing paths are implemented and optimized.

### 3. Architecture Highlights
- **Asynchronous API**: All networking is non-blocking using `Slim::Networking::SimpleAsyncHTTP`.
- **Centralized Cache**: A unified cache object in `Plugins::Zvuk::API` shared across all modules (`Plugin`, `ProtocolHandler`, `Async`). This is critical for metadata consistency.
- **Metadata Lifecycle**: Metadata (title, artist, duration) is proactively cached during browsing to ensure "Now Playing" screens update instantly.

---

## 🛠 Known Issues & Gotchas

### 1. SqueezePlay Progress Bar
**Status**: Improving.
**Issue**: Some players (SqueezePlay/Jive) might occasionally start playback without a progress bar if they don't receive the duration in the very first OMPL/Metadata response.
**Fixes Applied**:
- Added `duration` and `secs` to OPML items in `Plugin.pm`.
- Unified cache to ensure `ProtocolHandler` always has data.
- Forced integer casting for duration fields.

### 2. "FLAC DRM" Mystery
- The Zvuk API labels some FLAC URLs as `flacdrm`. In practice, these are playable by LMS (not encrypted with Widevine/PlayReady in a way that blocks standard HTTPS streaming). The plugin treats them as regular FLAC streams.

### 3. Linux File Casing
- LMS on Linux is case-sensitive. The plugin ID must be **lowercase `zvuk`** and match the directory name `Plugins/Zvuk` (where `Plugins` is the LMS root). We use `HTML/EN/plugins/zvuk/` for web assets.

---

## 🗺 Roadmap (Pending Features)

- [ ] **Library Importer**: Create `Plugins::Zvuk::Importer` to sync Liked Tracks and Playlists into the local LMS database.
- [ ] **Like/Dislike Actions**: Add context menu items to "Like" or "Dislike" tracks directly from the player.
- [ ] **Infinite Wave**: Extend the "Personal Wave" automatically when reaching the end of the current queue (using `DontStopTheMusic` hook).
- [ ] **Tiny API Fallback**: Implement a fallback to `/api/tiny/track/stream` if GraphQL resolution fails.

---

## 💡 Developer Notes (Quick Start)

### Key Files
1. **Plugin.pm**: Entry point. Handles menu generation and OPML rendering.
2. **ProtocolHandler.pm**: Resolves `zvuk://` URLs into actual stream URLs.
3. **API.pm**: Shared utilities, cache management, and data formatting.
4. **API/Async.pm**: The GraphQL client. Handles authentication, tokens, and raw API requests.

### Debugging
Enable debug logging in LMS Settings -> Advanced -> Logging:
- `plugin.zvuk` -> Set to **DEBUG**.

### Cache Keys
- `zvuk_meta_{id}`: Metadata hash (title, artist, duration, etc.)
- `zvuk_gql:{userId}:{operationName}:{variables_md5}`: Raw GraphQL responses.

---

## ✉️ Hand-over Checklist
- [ ] Verify `install.xml` versioning.
- [ ] Ensure `cookies.txt` is NOT included in public releases (used for development).
- [ ] Test with a clean LMS installation to verify directory casing.
