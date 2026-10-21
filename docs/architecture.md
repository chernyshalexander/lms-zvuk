# Архитектура плагина Zvuk для LMS

Плагин **Zvuk** для медиасервера **Logitech Media Server (LMS)**, написан на Perl.

---

## Основные модули

### 1. `Plugin.pm` — главный модуль
**Роль:** точка входа, регистрация плагина, навигационное меню (OPML), HTTP-маршруты.

- Регистрирует плагин как `OPMLBased` (тип `apps` в меню LMS).
- Строит корневое меню: Поиск → Wave → Моя музыка → Сменить аккаунт.
- Обрабатывает всю навигацию: обработчики `handleFeed`, `handleAlbum`, `handleArtist`, `handlePlaylist`, `handleCollection` и т.д.
- Содержит Web UI-маршруты (`addRawFunction`): OAuth-callback, сохранение Wave-настроек, анонимный токен.
- Содержит Jive-меню для Wave Settings (слайдеры, жанры, вокал, язык) + нерабочий wizard (сохранён как заготовка).
- Маршрутизатор `handleWaveSettingsRouter` автоматически выбирает Web UI или Jive-меню в зависимости от клиента.

### 2. `API.pm` — статика и утилиты
**Роль:** константы, общий кеш, утилитарные методы.

- Хранит URL-константы (`GRAPHQL_URL`, `PROFILE_URL`), константы качества (`mid/high/flac`), TTL кеша.
- Предоставляет синглтон `Slim::Utils::Cache` через `cache()` — им пользуются все модули.
- Методы: `getToken`, `getUserdata`, `getQuality`, `getImageUrl`, `cacheTrackMetadata`, `_getArtistName`.

### 3. `API/Async.pm` — асинхронные API-запросы
**Роль:** все GraphQL-запросы к `zvuk.com`, кеширование ответов.

- Синглтон на userId: объект создаётся один раз на аккаунт и переиспользуется.
- Центральный метод `_graphql($cb, $operationName, $query, $vars, $opts)` — POST на GraphQL endpoint с auth-токеном, deviceId, UA. Перед запросом проверяет кеш.
- TTL выбирается по имени операции (`_getCacheTTL`): 0 для потоков/Wave, 5м для коллекции, 1ч для поиска, 24ч для статики.
- Методы API: `search`, `getStream`, `getTracks`, `getAlbumTracks`, `getArtistTracks`, `getArtistAlbums`, `getPlaylistTracks`, `getPodcastEpisodes`, `getPersonalWave`, `getCollection`, `getUserPlaylists`, `getProfile`.

### 4. `ProtocolHandler.pm` — воспроизведение потоков
**Роль:** обработчик URL-схемы `zvuk://`, мост между LMS и CDN.

- Наследуется от `Slim::Player::Protocols::HTTPS`.
- `getNextTrack` — резолвит `zvuk://<id>` → реальный CDN-URL через `getStream`, выбирает формат (mp3/flac) по настройке качества. Парсит заголовок потока для точного определения длительности (`parseRemoteHeader`).
- `getMetadataFor` — возвращает метаданные трека из кеша; при отсутствии запускает `getTracks` асинхронно.
- `explodePlaylist` — разворачивает `zvuk://wave`, `zvuk://album:<id>` и т.п. в список URL треков.
- **Auto-load next batch:** в `getNextTrack` при приближении конца очереди Wave (≤2 трека) автоматически вызывает `_loadMoreWaveTracks`.

### 5. `Settings.pm` — настройки плагина (Web UI)
**Роль:** страница настроек в интерфейсе LMS.

- Наследуется от `Slim::Web::Settings`.
- Управляет аккаунтами (добавить по токену, удалить), качеством аудио.
- `beforeRender` готовит данные для шаблона: список аккаунтов, Wave-настройки в JSON для JS-слайдеров.

### 6. `WaveSettings.pm` — настройки персональной волны
**Роль:** CRUD для настроек Wave, хранящихся в `Slim::Utils::Prefs`.

- Хранит настройки под ключом `wave_settings_<account_id>`.
- Содержит константы жанров (`GENRES` — 11 жанров) с i18n-ключами.
- Методы: `loadSettings`, `saveSettings`, `getGenres`, `getGenreNames`.

---

## Ключевые структуры данных

| Структура | Где используется | Содержимое |
|---|---|---|
| **`$accounts`** (prefs) | Plugin, Settings, API | `{ userId => { token, name } }` |
| **`$wave_settings`** | WaveSettings, Plugin, ProtocolHandler | `{ popular, energy, fun, language, vocal, genres[] }` |
| **Track metadata cache** `zvuk_meta_<id>` | API, ProtocolHandler | `{ id, title, artist, album, duration, icon, type, _cached_quality }` |
| **GraphQL cache** `zvuk_gql:<userId>:<op>:<hash>` | API::Async | Сырые данные GraphQL-ответа |
| **OPML item** | Plugin | `{ name, type, url, image, passthrough, playall, ... }` |
| **`$api_clients`** (в памяти) | Plugin | `{ userId => Async объект }` |

---

## Поток данных: воспроизведение трека

```
Пользователь выбирает трек
  → Plugin._renderTrack → URL: zvuk://12345
  → LMS передаёт URL ProtocolHandler
  → ProtocolHandler.getNextTrack
    → API::Async.getStream (GraphQL) → CDN URL
    → parseRemoteHeader → длительность
  → LMS начинает стрим с CDN
```

## Поток данных: Personal Wave

```
zvuk://wave
  → ProtocolHandler.explodePlaylist → _explodeWave
  → API::Async.getPersonalWave (GraphQL с wave_settings)
  → Список zvuk://<id> добавляется в очередь LMS
  → При N≤2 треках в очереди: auto-load next batch → _loadMoreWaveTracks
```
