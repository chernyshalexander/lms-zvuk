# Zvuk.com API — Документация

> Последнее обновление: 2026-06-15 (на основе анализа APK v4.109.0rs + браузерных запросов)

## Обзор

Zvuk использует **GraphQL API** через единственный эндпоинт:

```
POST https://zvuk.com/api/v1/graphql
```

Для аутентификации используется заголовок `x-auth-token`.

> **Важно**: Сервис защищён WAF (Servicepipe). Прямые запросы с серверных IP блокируются (HTTP 307/418). Из LMS-плагина запросы должны работать при правильном наборе заголовков.

---

## Аутентификация

### Токен пользователя

Передаётся в каждом запросе как HTTP-заголовок `x-auth-token`. Формат — hex-строка 32 символа.

### Получение профиля (Anonymous или авторизованный)

```
GET https://zvuk.com/api/tiny/profile
Headers: x-auth-token: <token>
```

**Ответ:**
```json
{
  "result": {
    "id": 777701291,
    "is_anonymous": false,
    "token": "069fae1ab47847558000118524a26170"
  }
}
```

> **Анонимный токен**: если запросить `/api/tiny/profile` без токена или с пустым токеном, сервер возвращает анонимный токен. Анонимный аккаунт даёт доступ к `stream.mid` (128kbps). Это подтверждено кодом приложения (поле `is_anonymous: true`).

> Из профиля получаем `userId` — числовой ID пользователя для запросов коллекции.

### Механизм аутентификации (из APK)

Приложение поддерживает несколько методов входа (класс `PhoneAuthType`):
- **PHONE** — вход по номеру телефона + SMS-код (OTP)
- **SBER** — вход через SberID
- **AUTOROUTING** — автоматический выбор метода
- **AUTOROUTING_PLUS_SBER** — авторотинг с поддержкой Sber

Токен пользователя + `refreshToken` хранятся в `User` модели. При истечении токена используется refresh flow (класс `RefreshTokenException` в network модуле).

---

## GraphQL Endpoint

```
POST https://zvuk.com/api/v1/graphql
```

### Обязательные заголовки

```http
content-type: application/json
accept: application/graphql-response+json, application/json
x-auth-token: <token>
x-app-name: web-zvuk-service-desktop-app
x-device-id: <uuid>              # статичный UUID устройства (генерировать один раз и хранить)
origin: https://zvuk.com
referer: https://zvuk.com/
user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ...
```

> **x-app-name** и **x-device-id** критичны для прохождения WAF.
> Значение `x-app-name: web-zvuk-service-desktop-app` — константа из APK (альтернативно для Android: `com.zvooq.openplay`).

**Тело запроса:**
```json
{
  "operationName": "<OperationName>",
  "variables": { ... },
  "query": "<GraphQL query string>"
}
```

---

## REST API Эндпоинты

### Базовые пути (из HostConfigPreset)

| Путь | Описание |
|------|----------|
| `https://zvuk.com/api/tiny/` | Tiny REST API (профиль, простые запросы) |
| `https://zvuk.com/api/` | V1 REST API |
| `https://zvuk.com/api/v2/` | V2 REST API |
| `https://zvuk.com/sapi/` | Internal SAPI |
| `https://zvuk.com/api/ads/` | Реклама |
| `https://zvuk.com/api/v1/graphql` | GraphQL Federation |
| `https://zvuk.com/api/v1/stream/key` | Widevine DRM ключ |

### GET /api/tiny/profile

```
GET https://zvuk.com/api/tiny/profile
Headers: x-auth-token: <token>
```

Возвращает профиль пользователя с `id`, `token`, `is_anonymous`.

### GET /api/tiny/grid

```
GET https://zvuk.com/api/tiny/grid?name=<grid_name>
```

Сетки контента по имени. Используется для главного экрана / раздела "Открытие".

### CDN для стримов (из APK)

```
https://cdn-hls-slicer.zvuk.com/drm/track/<id>_<n>/init-smq-a1.mp4
```
Это HLS DRM потоки — **не для LMS**. Только `stream.mid` / `stream.high` из GraphQL.

### Widevine DRM

```
POST https://zvuk.com/api/v1/stream/key
```
Для FLAC DRM расшифровки — не реализовано в плагине.

---

## GraphQL Операции — Треки

### getStream — ссылки на потоки

```graphql
query getStream($ids: [ID!]!) {
  mediaContents(ids: $ids) {
    __typename
    ... on Track {
      id
      duration
      stream {
        expire
        expireDelta
        flacdrm
        high
        mid
      }
    }
    ... on Episode {
      stream { expire expireDelta high mid }
    }
    ... on Chapter {
      stream { expire expireDelta high mid }
    }
  }
}
```

**Поля stream:**
| Поле | Формат | Требования |
|------|--------|------------|
| `mid` | MP3 128kbps | Бесплатно / аноним |
| `high` | MP3 320kbps | Подписка |
| `flacdrm` | FLAC + Widevine DRM | Подписка |
| `expire` | string timestamp | TTL URL |
| `expireDelta` | int (секунды) | Секунд до истечения |

> URL потока временный — необходимо обновлять. Не кешировать.

### getFullTrack — полные данные трека

```graphql
query getFullTrack($ids: [ID!]!, $withReleases: Boolean = false, $withArtists: Boolean = false) {
  getTracks(ids: $ids) {
    id title searchTitle position duration availability
    artistTemplate condition explicit lyrics zchan hasFlac
    genres { id name shortName }
    collectionItemData { itemStatus }
    artists @include(if: $withArtists) {
      id title searchTitle description hasPage
      image { src palette paletteBottom }
    }
    release @include(if: $withReleases) {
      id title searchTitle type date
      image { src palette paletteBottom }
      genres { id name shortName }
      label { id title }
      availability artistTemplate
    }
  }
}
```

### getMeta — универсальный запрос метаданных

Мегазапрос из APK — получает всё за один запрос:

```graphql
query getMeta(
  $artistsIds: [ID!]!, $playlistsIds: [ID!]!, $releaseIds: [ID!]!,
  $trackIds: [ID!]!, $podcastIds: [ID!]!, $episodesIds: [ID!]!,
  $bookIds: [ID!]!, $chaptersIds: [ID!]!, $bookAuthorsIds: [ID!]!,
  $isIncludeArtistsIds: Boolean!, $isIncludeReleaseIds: Boolean!,
  $isIncludeBookIds: Boolean!, $isIncludeChaptersIds: Boolean!,
  $isIncludeTrackIds: Boolean!, ...
) {
  getArtists(ids: $artistsIds) @include(if: $isIncludeArtistsIds) { ...ArtistGqlFragment }
  getReleases(ids: $releaseIds) @include(if: $isIncludeReleaseIds) { ...ReleaseGqlFragment }
  getTracks(ids: $trackIds) @include(if: $isIncludeTrackIds) { ...TrackGqlFragment }
  getBooks(ids: $bookIds) @include(if: $isIncludeBookIds) { ...BookGqlFragment }
  getChapters(ids: $chaptersIds) @include(if: $isIncludeChaptersIds) { ...ChapterGqlFragment }
  getPodcasts(ids: $podcastIds) @include(if: $isIncludePodcastIds) { ...PodcastGqlFragment }
  getEpisodes(ids: $episodesIds) @include(if: $isIncludeEpisodesIds) { ...EpisodeGqlFragment }
  getBookAuthors(ids: $bookAuthorsIds) @include(if: $isIncludeBookAuthorsIds) { ...BookAuthorGqlFragment }
  playlists(ids: $playlistsIds) @include(if: $isIncludePlaylistsIds) { ...PlaylistGqlFragment }
}
```

---

## GraphQL Операции — Альбомы / Артисты

### getReleases — альбомы

```graphql
query getReleases($ids: [ID!]!, $withTracks: Boolean = false, $withArtists: Boolean = false) {
  getReleases(ids: $ids) {
    id title searchTitle type date availability artistTemplate
    image { src palette paletteBottom }
    genres { id name shortName }
    label { id title }
    artists @include(if: $withArtists) { id title image { src } }
    tracks @include(if: $withTracks) {
      id title duration availability artistTemplate
      stream { high mid flacdrm expire expireDelta }
    }
  }
}
```

### getArtists — артисты

```graphql
query getArtistAlbums($ids: [ID!]!, $releasesLimit: Int = 100, $releasesOffset: Int = 0) {
  getArtists(ids: $ids) {
    id title isVerified searchTitle description
    image { src palette paletteBottom }
    childParam mark isWave
    collectionItemData { likesCount }
    releases(offset: $releasesOffset, limit: $releasesLimit) {
      id title type date artistTemplate image { src }
    }
    popularTracks(offset: 0, limit: 50) {
      id title duration availability artistTemplate
      artists { id title }
      release { id title image { src } }
    }
  }
}
```

---

## GraphQL Операции — Плейлисты

### getPlaylists — данные плейлиста

```graphql
query getPlaylists($ids: [ID!]!) {
  playlists(ids: $ids) {
    id title userId description updated duration
    image { src palette paletteBottom }
    branded shared isPublic isDeleted
    chart { trackId positionChange }
    tracks {
      id title duration availability artistTemplate
      artists { id title image { src } }
      release { id title image { src } }
    }
    collectionItemData { likesCount }
    profile { name image { src } }
    typeInfo { type subType }
  }
}
```

### getPlaylistTracks — треки плейлиста (offset-based)

```graphql
query getPlaylistTracks($id: ID!, $limit: Int = 500, $offset: Int = 0) {
  playlistTracks(id: $id, limit: $limit, offset: $offset) {
    id title duration availability artistTemplate childParam mark zchan
    artists { id title image { src palette } mark }
    release { id title image { src palette } }
    __typename
  }
}
```

### Мутации плейлиста

```graphql
# Создать плейлист
mutation createPlaylist($items: [PlaylistItem!], $name: String!, $source: String) {
  playlist { createV1(items: $items, name: $name, source: $source) { ...PlaylistGqlFragment } }
}

# Добавить треки в плейлист
mutation addItemsToPlaylist($id: ID!, $items: [PlaylistItem!]) {
  playlist { addItemsV1(id: $id, items: $items) { ...PlaylistGqlFragment } }
}

# Удалить треки из плейлиста
mutation removeItemsFromPlaylist($id: ID!, $items: [PlaylistItem!]!) {
  playlist { removeItemsV1(id: $id, items: $items) { ...PlaylistGqlFragment } }
}

# Сделать публичным/приватным
mutation setPublicVisibility($id: ID!, $isPublic: Boolean!) {
  playlist { setPublicV1(id: $id, isPublic: $isPublic) { ...PlaylistGqlFragment } }
}
```

> `PlaylistItem` = `{ id: ID!, type: CollectionItemType! }`. Для треков type = `"track"`.

---

## GraphQL Операции — Поиск

### search — расширенный поиск с пагинацией (используется в плагине)

```graphql
query search(
  $query: String
  $limit: Int = 20
  $tracks: Boolean = true
  $trackCursor: Cursor = null
  $artists: Boolean = true
  $artistsCursor: Cursor = null
  $releases: Boolean = true
  $releasesCursor: Cursor = null
  $playlists: Boolean = true
  $playlistsCursor: Cursor = null
) {
  search(query: $query) {
    tracks(limit: $limit, cursor: $trackCursor) @include(if: $tracks) {
      items { id title duration availability artistTemplate
        artists { id title }
        release { id title image { src } }
      }
      page { total next }
    }
    artists(limit: $limit, cursor: $artistsCursor) @include(if: $artists) {
      items { id title image { src } }
      page { total next }
    }
    releases(limit: $limit, cursor: $releasesCursor) @include(if: $releases) {
      items { id title type date artistTemplate image { src } }
      page { total next }
    }
    playlists(limit: $limit, cursor: $playlistsCursor) @include(if: $playlists) {
      items { id title image { src } }
      page { total next }
    }
  }
}
```

> **Важно**: флаги `tracks`, `artists` и т.д. должны быть JSON boolean (`true`/`false`), а не числа. В Perl использовать `\1` / `\0`.

### quickSearch — быстрый поиск (смешанный)

```graphql
query quickSearch($query: String, $limit: Int, $searchSessionId: String) {
  quickSearch(query: $query, limit: $limit, searchSessionId: $searchSessionId) {
    searchSessionId
    content {
      __typename
      ... on Track { id title artistTemplate duration }
      ... on Artist { id title image { src } }
      ... on Release { id title date artistTemplate }
      ... on Playlist { id title isPublic }
    }
  }
}
```

---

## GraphQL Операции — Коллекция пользователя

### collection — получить всё сразу

```graphql
query userCollection {
  collection {
    tracks { id title duration availability artistTemplate
      artists { id title image { src } }
      release { id title image { src } }
    }
    releases { id title type date artistTemplate image { src } }
    artists { id title image { src } }
    playlists { id title image { src palette } description isPublic }
  }
}
```

### paginatedCollection — коллекция с пагинацией (cursor-based)

```graphql
query getPaginatedCollection($limit: Int = 30, $after: String = null) {
  paginatedCollection {
    tracks(pagination: {first: $limit, after: $after}) {
      items {
        id title lyrics hasFlac duration explicit availability
        artistTemplate childParam mark zchan
        artists { id title image { src palette } mark }
        release { id title image { src palette } }
        __typename
      }
      page { endCursor }
    }
    podcasts(pagination: {first: 500}) {
      items { id title description image { src } }
    }
    episodes(pagination: {first: 500}) {
      items {
        id title description duration image { src }
        podcast { id title image { src } }
      }
    }
  }
}
```

### collectionCount — количество треков

```graphql
query getCollectionCount {
  collectionCount { tracks }
}
```

### Мутации коллекции

```graphql
# Добавить в коллекцию (лайк)
mutation addCollectionItem($id: ID, $type: CollectionItemType) {
  collection { addItem(id: $id, type: $type) }
}

# Добавить (V1 — возвращает теги)
mutation addCollectionItemV1($id: ID, $type: CollectionItemType) {
  collection {
    addItemV1(id: $id, type: $type) {
      collectionSubtype
      itemTags { sourceTagId nameRu nameEng sourceGroupIds }
    }
  }
}

# Удалить из коллекции
mutation removeCollectionItem($id: ID, $type: CollectionItemType) {
  collection { removeItem(id: $id, type: $type) }
}

# Добавить несколько сразу
mutation addCollectionItems($items: [CollectionItemInput!]!) {
  collection { addItems(items: $items) }
}
```

**CollectionItemType** значения (из APK):
- `track`
- `release` (альбом)
- `artist`
- `playlist`
- `podcast`
- `episode`
- `book` (аудиокнига)
- `chapter` (глава аудиокниги)
- `bookAuthor`

---

## GraphQL Операции — Аудиокниги

### getBooks — данные аудиокниг

```graphql
query getBooks($ids: [ID!]!) {
  getBooks(ids: $ids) {
    id title serialName description copyright publicationDate
    image { src palette paletteBottom }
    bookAuthors {
      id name rname description image { src palette paletteBottom }
      visible mark collectionItemData { likesCount }
    }
    genres { id }
    availability ageLimit
    chapters { id }
    publisher { id publisherBrand publisherName }
    explicit
    performers { id rname image { src } mark }
    translators { id rname }
    fullDuration
    condition
    childParamV2
    mark
  }
}
```

**Поля Book:**
| Поле | Описание |
|------|----------|
| `id` | ID книги |
| `title` | Название |
| `serialName` | Серия (цикл) |
| `description` | Описание |
| `copyright` | Копирайт |
| `publicationDate` | Дата публикации (Long/unix) |
| `fullDuration` | Суммарная длительность всех глав (сек) |
| `ageLimit` | Возрастное ограничение (0, 6, 12, 16, 18) |
| `condition` | `"free"`, `"subscription"`, etc. |
| `bookAuthors` | Авторы книги |
| `performers` | Чтецы |
| `translators` | Переводчики |
| `publisher` | Издательство |
| `chapters` | Массив `{id}` глав |

### getChapters — главы аудиокниги

```graphql
query getChapters($ids: [ID!]!) {
  getChapters(ids: $ids) {
    id title
    book { ...BookGqlFragment }
    image { src palette paletteBottom }
    position
    bookAuthors { id name }
    availability
    performers { id rname image { src } }
    duration
    condition
    childParamV2
    listenState   # "LISTENED" | "NOT_LISTENED"
  }
}
```

Для получения стрима главы используется `mediaContents(ids: [$chapterId])` → `... on Chapter { stream { mid high } }`.

### getChaptersWithoutBooks — главы без полных данных книги

```graphql
query getChaptersWithoutBooks($ids: [ID!]!) {
  getChapters(ids: $ids) {
    id title image { src palette paletteBottom }
    position duration condition childParamV2 listenState
  }
}
```

### getBookAuthors — авторы книг

```graphql
query getBookAuthors($ids: [ID!]!) {
  getBookAuthors(ids: $ids) {
    id name rname description visible mark
    image { src palette paletteBottom }
    collectionItemData { likesCount }
  }
}
```

### getAuthorsCursorBooks — книги автора с пагинацией

```graphql
query getAuthorsCursorBooks($id: ID!, $limit: Int!, $cursor: String) {
  getBookAuthors(ids: [$id]) {
    getAuthorsCursorBooks(limit: $limit, cursor: $cursor) {
      page_info { hasNextPage hasPreviousPage endCursor startCursor }
      books { ...BookGqlFragment }
    }
  }
}
```

### getAudiobookRelatedAudiobooks — похожие книги

```graphql
query getAudiobookRelatedAudiobooks($id: ID!, $limit: Int!) {
  relatedBooks(book_id: $id, limit: $limit) { ...BookGqlFragment }
}
```

---

## GraphQL Операции — Подкасты

### getPodcasts — данные подкастов

```graphql
query getPodcasts($ids: [ID!]!) {
  getPodcasts(ids: $ids) {
    id title type description availability explicit updatedDate
    image { src palette paletteBottom }
    authors { id name }
    episodes { id }
    collectionItemData { likesCount }
    mark childParam
  }
}
```

### getEpisodes — эпизоды

```graphql
query getEpisodes($ids: [ID!]!) {
  getEpisodes(ids: $ids) {
    id title description availability publicationDate duration trackId
    image { src palette paletteBottom }
    podcast { id title authors { id name } image { src } }
    explicit link number mark childParam
  }
}
```

Для стрима эпизода: `mediaContents(ids: [$episodeTrackId])` → `... on Episode { stream { mid high } }`.

---

## GraphQL Операции — История прослушивания

### listeningRecentV1 — история (главный экран)

```graphql
query listeningRecentV1(
  $isKidContent: Boolean
  $itemType: [RecentItemType!]
  $limit: Int!
  $offset: Int!
) {
  listeningRecentV1(
    isKidContent: $isKidContent
    itemType: $itemType
    limit: $limit
    offset: $offset
  ) {
    lastListeningDttm
    mediaContent {
      __typename
      ... on Artist { id title image { src palette paletteBottom } mark }
      ... on Release { id title date type image { src } }
      ... on Playlist { id title image { src } }
      ... on Book { id title image { src palette paletteBottom } }
      ... on Podcast { id title image { src } }
      ... on Episode { id title image { src } }
    }
  }
}
```

**RecentItemType** значения:
- `TRACK_HISTORY_ITEM`
- `PODCAST_EPISODE_HISTORY_ITEM`
- `AUDIOBOOK_CHAPTER_HISTORY_ITEM`

---

## GraphQL Операции — Волны (Миксы)

### personalWaveContent — персональная волна

```graphql
query getPersonalWave(
  $contentInput: PersonalWaveContentInput
  $first: PositiveInt! = 2
  $options: PersonalWaveOptions
  $waveInput: WaveInput
  $waveSrc: MagicSource
) {
  personalWaveContent(
    contentInput: $contentInput
    first: $first
    options: $options
    waveInput: $waveInput
    waveSrc: $waveSrc
  ) {
    id title lyrics hasFlac duration explicit availability
    artistTemplate childParam mark zchan __typename
    artists { id title image { src palette } mark }
    release { id title image { src palette } }
  }
}
```

**Параметры options:**
| Параметр | Тип | Описание |
|----------|-----|----------|
| `popular` | NormalizedFloat [0.0–1.0] | Популярность (0=неизвестное, 1=из избранного) |
| `mood` | String | `"energy:0.5,fun:0.5"` |
| `vocal` | NormalizedFloat | 0=инструментал, 1=с вокалом |
| `language` | String | `"all"`, `"russian"`, `"foreign"` |
| `genre` | [String] | Массив названий жанров |

**waveSrc:** `"AMAZME"` — персональная волна.

### availableWaves — список доступных волн

```graphql
query availableWaves {
  wave {
    availableWaves {
      id title description
      image { src palette paletteBottom }
      tagAudience
      smallImage { src palette paletteBottom }
      availability
    }
  }
}
```

### dynamicBlock — блоки контента главного экрана

```graphql
query dynamicBlock(
  $contentType: DynamicBlockContentType!
  $itemType: [DynamicBlockItemType!]
  $pages: [Int!]!
) {
  dynamicBlock(contentType: $contentType, itemType: $itemType, pages: $pages) {
    title totalPages
    pages {
      page
      items {
        __typename positionName
        ... on Release { ...ReleaseGqlFragment }
        ... on Playlist { ...PlaylistGqlFragment }
        ... on Artist { ...ArtistGqlFragment }
        ... on Book { ...BookGqlFragment }
        ... on Podcast { ...PodcastGqlFragment }
      }
    }
  }
}
```

---

## GraphQL — Прочие мутации

```graphql
# Добавить трек в "скрытые" (не показывать в волне)
mutation addHiddenItem($id: ID!, $type: CollectionItemType!) {
  hiddenCollection { addItem(id: $id, type: $type) }
}

# Деактивировать push-токен
mutation deactivatePushToken($token: String!) {
  pushData { deactivate(token: { token: $token service: FIREBASE }) }
}

# Настройки приватности коллекции
mutation setPublicCollectionTracksProfileInfo($isPublicCollectionTracksOpen: Boolean!) {
  profile { update(privacySettings: { isPublicCollectionTracks: $isPublicCollectionTracksOpen }) }
}
```

---

## Объекты данных

### Image
```json
{
  "src": "https://cdn.zvuk.com/images/...",
  "palette": "#RRGGBB",
  "paletteBottom": "#RRGGBB"
}
```

**Форматирование URL изображений (CDN параметры):**
```
src?width=<W>&height=<H>
```
Пример: `https://cdn.zvuk.com/images/track/123/cover.jpg?width=500&height=500`

Рекомендуемые размеры: 500×500, 300×300, 150×150.

### Genre
```json
{ "id": "1", "name": "Rock", "shortName": "rock" }
```

### Label
```json
{ "id": "100", "title": "Universal Music" }
```

### CollectionItemData
```json
{ "likesCount": 1234 }
```

### ChildParam (возрастной контент)
| Значение | Описание |
|----------|----------|
| `CHILD` | Детский контент |
| `FAMILY` | Семейный контент |

### ListenState (для глав аудиокниг)
| Значение | Описание |
|----------|----------|
| `LISTENED` | Прослушано |
| `NOT_LISTENED` | Не прослушано |

---

## Доступность (availability / condition)

| Поле | Значение | Описание |
|------|----------|----------|
| `availability` | `0` | Недоступен |
| `availability` | `1` | Доступен |
| `condition` | `"free"` | Бесплатно |
| `condition` | `"subscription"` | Требуется подписка |

---

## Качество аудио

| Уровень | Поле stream | Формат | Требования |
|---------|-------------|--------|------------|
| High | `stream.high` | MP3 320kbps | Подписка |
| Middle | `stream.mid` | MP3 128kbps | Бесплатно / аноним |
| FLAC DRM | `stream.flacdrm` | FLAC + Widevine | Подписка |

> URL потока временный — содержит параметры `expire` и `expireDelta`. Не кешировать.

---

## Воспроизведение

**LMS плагин** использует `getStream` → поля `stream.mid` / `stream.high`:
- `stream.mid` — прямой MP3 URL (~128k), доступен без подписки
- `stream.high` — прямой MP3 URL (320k), требует подписки

**Браузер** использует HLS DRM (не подходит для LMS):
```
https://cdn-hls-slicer.zvuk.com/drm/track/<id>_<n>/init-smq-a1.mp4
```

---

## Магические константы из APK

### Хосты
| Имя | Хост |
|-----|------|
| PRODUCTION | `zvuk.com` |
| PREPROD | `preprod.zvq.me` |
| STAGE_ZVUK | `stage.zvuk.com` |

Также валидны: `zvooq.com`, `sber-zvuk.com` (исторические алиасы).

### x-app-name значения
- Веб: `web-zvuk-service-desktop-app` ← **использовать в плагине**
- Android: `com.zvooq.openplay`

### Сортировка коллекции (MetaSortingType)
- `BY_LAST_MODIFIED` — по дате изменения
- `BY_ALPHABET` / `BY_ALPHABET_ASC` / `BY_ALPHABET_DESC`
- `BY_ARTIST_NAME`
- `BY_NOVELTY`
- `BY_UPDATING`
- `BY_DATE_UPDATED`

### Типы плейлистов (PlaylistTypeInfo)
- `type` + `subType` — служебные поля для дифференциации ручных/генеративных плейлистов

### Типы контента в коллекции (CollectionSortingItemType)
`ARTIST`, `RELEASES`, `PODCASTS`, `PLAYLISTS`, `FAVOURITE_TRACKS`, `PODCAST_EPISODES`, `AUDIOBOOKS`, `AUDIOBOOK_AUTHORS`, `DOWNLOADED_*`, `KIDS_*`

---

## Authentication & Headers Deep Dive

### HTTP Headers (OkHttp Interceptors)

Все REST-запросы от приложения содержат следующие заголовки:

| Заголовок | Источник | Пример |
|-----------|---------|--------|
| `X-App-Version` | Hardcoded | `"4.109.0rs"` |
| `X-App-Build` | Hardcoded | `"510900179"` |
| `X-Device-Id` | `Settings.Secure.getString(context, "android_id")` | 64-bit hex |
| `X-Screen-Width` | Display metrics | Целое число пикселей |
| `X-Screen-Height` | Display metrics | Целое число пикселей |
| `X-Screen-Density` | Display density | "1.0", "1.5", "2.0" и т.д. |
| `Accept-Language` | Locale | `"en-US"`, `"ru-RU"` |
| `X-Client-Time` | System time (ISO 8601) | `"2024-01-15T10:30:00+03:00"` |
| `X-MNC` | SIM info | Comma-separated MCC-MNC коды |
| `X-Service-Provider-Name` | SIM operator | `"MTS"`, `"Beeline"` и т.д. |
| `X-Advertising-ID` | Google Ad ID | UUID (если доступен) |
| `X-Zvuk-Profile-Id` | Kids mode | User ID (только в kids режиме) |
| `User-Agent` | Android UA | `"Mozilla/5.0 (Linux; Android 14; ...) AppleWebKit/537.36"` |
| `Referer` | Base URL | `"https://zvuk.com/"` |
| `X-Timestamp` | Unix time | Seconds since epoch |
| `X-App-Instance` | Per-install UUID | UUID v4 (генерируется один раз) |
| `X-Session-UID` | WAF bypass token | Base64-encoded computed value (см. ниже) |
| `X-Auth-Token` | Bearer token | 32-char hex string |

### WAF Bypass — X-Session-UID Algorithm

Для обхода WAF Servicepipe приложение вычисляет `X-Session-UID` для каждого запроса:

```
Шаг 1: Собрать входные данные
  input = appInstanceId + X-Timestamp + User-Agent

Шаг 2: SHA-256 хеш
  digest = SHA256(input.getBytes("UTF-8"))
  hexStr = digest as uppercase hex (64 chars)

Шаг 3: DEFLATE сжатие (raw, без wrapper)
  compressed = DEFLATE(hexStr, level=-1, raw=true)

Шаг 4: XOR с appInstanceId (только первые N байт)
  for i in compressed:
    if i < len(appInstanceId):
      result[i] = compressed[i] XOR appInstanceId[i]
    else:
      result[i] = compressed[i]

Шаг 5: Base64 encoding (NO_WRAP)
  X-Session-UID = Base64.encodeToString(result, 2)
```

**Важно для LMS**: если ваш HTTP-клиент отправляет запросы с этим заголовком, WAF не будет блокировать их как боты/скреперы.

### Device ID Generation

```perl
# Android ANDROID_ID (уникален для device+app signing key)
X-Device-Id: Settings.Secure.getString(context, "android_id")
```

Это 64-bit hex-строка, уникальная для каждого устройства. LMS может использовать случайный UUID или MAC address как эквивалент.

---

## REST API Endpoints

Помимо GraphQL, Zvuk использует несколько REST API для специальных операций:

### Authentication & Profile

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/api/v2/tiny/profile` | Профиль (v2 API) |
| POST | `/api/tiny/login/otp` | Вход по OTP-коду (телефон) |
| POST | `/api/tiny/login/sber` | Вход через SberID |
| GET | `/api/tiny/login/sber/get_params` | Параметры SberID SSO |
| GET | `/api/tiny/login/sber/complete` | Завершить вход SberID |
| POST | `/api/tiny/logout` | Выход из аккаунта |
| POST | `/api/tiny/refresh` | Обновить auth-токен |
| POST | `/api/tiny/route-authorization-type` | Определить тип авторизации (номер → способ входа) |
| POST | `/api/tiny/get-mcode` | Отправить OTP-код на телефон |

### User Management

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/api/tiny/user_profiles` | Список профилей пользователя |
| POST | `/api/tiny/user_profile` | Создать новый профиль |
| POST | `/api/user/profile` | Обновить профиль (имя, описание, дата рождения и т.д.) |
| DELETE | `/api/v1/user` | Удалить аккаунт |
| POST | `/api/user/avatar/upload` | Загрузить аватар (multipart) |
| DELETE | `/api/user/avatar/remove` | Удалить аватар |
| GET | `/api/v1/personal-statistic/` | Персональная статистика (заголовок: `X-Zvuk-User-Id`) |

### Content & Grid

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/api/tiny/grid` | Сетка контента (с параметрами `name`, `market`) |
| GET | `/api/tiny/grid?url=...` | Сетка по динамическому URL |
| GET | `/api/tiny/suggest` | Поиск / автодополнение (q, type, offset, limit) |
| GET | `/api/tiny/stories` | Сторис (ids, story_block_id) |
| GET | `/sapi/meta` | Метаданные нон-музыкальных списков (non_music_lists, include) |

### Subscriptions

| Метод | Путь | Описание |
|-------|------|---------|
| POST | `/api/tiny/subscribe` | Оформить подписку |
| POST | `/api/tiny/subscribe/standalone` | Подписка standalone (JSON body) |
| POST | `/api/tiny/unsubscribe` | Отменить подписку |
| POST | `/api/tiny/set_agreement` | Принять пользовательское соглашение |

### Music Recognition & Lyrics

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/api/tiny/musixmatch/lyrics` | Текст песни (track_id, translation) |
| POST | `/api/v1/identify` | Распознавание музыки (multipart: ACRCloud) |

### Ads

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/api/ads/next/v2` | Следующий рекламный блок |

### Media Upload

| Метод | Путь | Описание |
|-------|------|---------|
| POST | `/api/upload_image` | Загрузить изображение (multipart) |

### Promo & Payment

| Метод | Путь | Описание |
|-------|------|---------|
| POST | `/api/promocodes/payoff` | Активировать промокод |
| POST | `/api/sber/payment` | Оплата через Sber |
| GET | `/api/featured/info` | Информация о фичерд-кампании (заголовок: X-Campaign-name) |

### Integrations

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/api/v1/integrations/sber/userdata` | Данные пользователя для SberID (передаётся в SDK) |
| GET | `/api/v1/stream/key` | Widevine DRM-ключ для FLAC |

### Analytics & Events

| Метод | Путь | Описание |
|-------|------|---------|
| POST | `/api/tiny/clickstream` | Отправка событий кликстрима |
| POST | `/topics/cs_v4_raw_events` | Кликстрим-события (Kafka) |
| POST | `/topics/cs_v4_raw_service_events` | Служебные события (Kafka) |
| POST | `/topics/heatmap_queue` | Качество стриминга (Kafka) — полный URL передаётся динамически |

### Health & Misc

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/alive` | Healthcheck API |
| GET | `/api/v1/user_segment/` | Сегмент пользователя |
| POST | `/api/v1/user_segment/` | Обновить сегмент пользователя |

### Auth Token Response Format

При успешном входе сервер возвращает JSON с полями:

```json
{
  "token": "069fae1ab47847558000118524a26170",  // 32-char hex, используется как X-Auth-Token
  "userId": 777701291,                           // Numeric user ID
  "isRegistered": true,
  "refresh_token": "refresh_token_string",
  "expires": "2024-01-15T10:30:00+03:00",       // ISO 8601
  "refresh_token_expires": "2024-02-15T10:30:00+03:00"
}
```

### SberID OAuth Flow

1. **Получить параметры SberID**
   ```
   GET https://zvuk.com/api/tiny/login/sber/get_params
   Response: { nonce, state, scope, ... }
   ```

2. **Запустить SberID SDK**
   ```
   Параметры:
   - client_id: из конфигурации
   - redirect_uri: ваш callback URL
   - response_type: "code"
   - state: полученный выше
   - nonce: полученный выше
   - scope: получено выше
   
   Результат: auth_code (как параметр callback)
   ```

3. **Обменять code на token**
   ```
   POST https://zvuk.com/api/tiny/login/sber
   Form-encoded:
     auth_code: <код от SberID>
     redirect_uri: <ваш callback URL>
     state: <полученное значение>
     nonce: <полученное значение>
     scope: <полученное значение>
     login_method: "sberid"
   
   Response: { token, userId, expires, ... }
   ```

### Token Refresh

```
POST https://zvuk.com/api/tiny/refresh
Body (JSON):
{
  "refresh_token": "...",
  "token_type": "ERIB"  // или "ESA" для partner token
}

Response: { token, expires, refresh_token, refresh_token_expires }
```

### Retrofit2 Annotation Mapping (Обфусцированные)

В decompiled коде все аннотации Retrofit2 переименованы. Вот полное соответствие:

| Обфусцированная | Оригинальная |
|---|---|
| `@qvk` | `@POST` |
| `@imb` | `@GET` |
| `@d6b` | `@FormUrlEncoded` |
| `@jwn` | `@Query` |
| `@qga` | `@Field` |
| `@uxc` | `@Header` |
| `@wga` | `@FieldMap` |
| `@r0u` | `@Url` |
| `@gd3` | `@Body` |
| `@dlq` | `@SerializedName` (Gson) |

---

### Okko Player SDK

**Base URL:** `https://player-api.zvuk.playvp.ru/`

| Метод | Путь | Описание |
|-------|------|---------|
| GET | `/player/v1/prepareplayback` | Подготовка воспроизведения |
| GET | `/player/v1/playlistinfo` | Информация о плейлисте |
| GET | `/v3/prepareplayback/{client_type}/2000` | Screen API подготовка |
| POST | `/player` | Аналитика плеера |
| POST | `/telemetry/v1/logs/{platform}` | Телеметрия плеера |

### TNS Mediascope

**Base URL:** `https://www.tns-counter.ru/`

```
GET /{path}?tmsec={type}
```

Счётчик просмотров для медиаскопа.

---

## UI Icons & Resources

### COLT Design System Icons (Android VectorDrawable)

Наиболее полезные для LMS плагина (находятся в `/drawable/*.xml`):

| Иконка | Назначение | Размеры |
|--------|-----------|---------|
| `ic_colt_icon_playactions_play_*` | Play | L(32dp), M(24dp), S(16dp) |
| `ic_colt_icon_playactions_pause_*` | Pause | M(24dp), S(16dp) |
| `ic_colt_icon_shuffle_*` | Shuffle | L, M |
| `ic_colt_icon_rewind_prev15s_*` | -15 sec | L |
| `ic_colt_icon_rewind_next30s_*` | +30 sec | L |
| `ic_colt_icon_like_fill_*` | Like (filled) | M |
| `ic_colt_icon_like_stroke_*` | Like (outline) | M, S |
| `ic_colt_icon_dislike_*` | Dislike | M |
| `ic_colt_icon_queue_*` | Queue | S |
| `ic_colt_icon_search_*` | Search | L, M, S |
| `ic_colt_icon_albums_*` | Albums | M |
| `ic_colt_icon_artists_*` | Artists | M |
| `ic_colt_icon_tracks_*` | Tracks | L, M |
| `ic_colt_icon_playlists_*` | Playlists | L, M |
| `ic_colt_icon_podcast_*` | Podcasts | M, XL |
| `ic_colt_icon_books_*` | Audiobooks | M, S |
| `ic_colt_icon_wave_*` | Personal Wave | M, S, XS |
| `ic_colt_icon_download_*` | Download | L, M, S, XL, XS, XXS |
| `ic_colt_icon_history_time_*` | History | M, S, XL |
| `ic_colt_icon_equalizer_*` | Equalizer / Now Playing | L, M |
| `ic_colt_icon_add_to_playlist_*` | Add to Playlist | M, S |

### Zvuk Logo

| Файл | Размер | Назначение |
|------|--------|-----------|
| `ic_colt_icon_zvuk_size_xs.xml` | 16dp | Логотип XS |
| `ic_colt_icon_zvuk_size_m.xml` | 24dp | Логотип M (стандартный) |
| `ic_colt_icon_zvuk_size_xl.xml` | 48dp | Логотип XL |
| `ic_launcher_*.xml` | 108dp | Launcher иконка (adaptive) |

### Android Auto Icons

Белые иконки на тёмном фоне (`/drawable/ic_android_auto_*.xml`):

`next`, `previous`, `shuffle` (enabled/disabled), `repeat` (all/one/disabled), `like` (active/inactive), `albums`, `artists`, `tracks`, `playlists`, `podcasts`, `audiobooks`, `radio`, `home`, `download`, `collection`, `kids`

### Image Placeholders

| Файл | Назначение |
|------|-----------|
| `placeholder_artist_circle.png` | Артист (круг) |
| `placeholder_audiobook.webp` | Аудиокнига |
| `placeholder_podcast_circle.png` | Подкаст (круг) |
| `placeholder_favourite_tracks.webp` | Избранные треки |

### Streaming Quality Levels

Приложение поддерживает несколько уровней качества:

| Quality | Bitrate | DRM | Notes |
|---------|---------|-----|-------|
| `mid` | 128 kbps | None | Доступно анонимным пользователям |
| `high` | 320 kbps | None | Premium only |
| `flacdrm` | Lossless (FLAC) | Widevine | Premium only, требует DRM-ключ из `/api/v1/stream/key` |
| `adaptive_mid` | ~128 kbps | None | Адаптивное качество (min) |
| `adaptive_high` | ~320 kbps | None | Адаптивное качество (max) |
| `adaptive_flac` | Lossless | Widevine | Адаптивное FLAC |

GraphQL запрос возвращает поле `stream` с доступными качествами:

```graphql
{
  track {
    stream(quality: HIGH) {
      mid { url, expires }
      high { url, expires }
      flacdrm { url, expires }
    }
  }
}
```

### CDN Image URLs

**Domain:** `https://cdn-image.zvuk.com`

**Format с placeholder:** 
```
https://cdn-image.zvuk.com/.../path/{size}/filename.jpg
```

**Размеры:** `xsmall` (150px), `small` (300px), `medium` (600px), `large` (900px), `xlarge` (1800px)

**Обработка в LMS:**
```perl
# Заменить {size} на конкретные размеры
$src =~ s/\{size\}/500x500/g;
# Или добавить query параметры если нет размера
if ($src !~ /\?/) {
    $src .= '?width=500&height=500';
}
```

**Поля в API ответе:**
- `image.src` — основной URL (может содержать `{size}`)
- `image.picUrlSmall` — готовый малый размер
- `image.picUrlBig` — готовый большой размер
- `image.srcLight` — светлая версия для тёмных тем
- `image.w`, `image.h` — подсказки размеров

**Static Editorial Images (CDN pattern):**
```
https://zvooq.com/static/avatar/{name}/{hex1}/{hex2}/{name}.png

Примеры:
- https://zvooq.com/static/avatar/radio_icon/458/8a0/radio_icon.png
- https://zvooq.com/static/avatar/nastroeniya_icon/978/85d/nastroeniya_icon.png
- https://zvooq.com/static/avatar/populyarnoe_icon/e16/080/populyarnoe_icon.png
```

Сегменты `{hex1}/{hex2}` — первые 3 и следующие 3 символа хеша изображения.

---

## Примечания

1. **Аноним**: GET /api/tiny/profile без токена возвращает анонимный токен. Даёт доступ только к `stream.mid`.

2. **Cursor-based пагинация**: `paginatedCollection` использует `page.endCursor` → `after` для следующей страницы.

3. **Offset-based пагинация**: `playlistTracks`, `getArtists releases`, `getArtists popularTracks` — используют `offset` + `limit`.

4. **Cursor пагинация поиска**: `search(...)` использует `page.next` как `cursor` для следующей страницы.

5. **Аудиокниги**: главы (`Chapter`) воспроизводятся через `mediaContents(ids: [$chapterId])` → `... on Chapter { stream { mid high } }`.

6. **История**: `listeningRecentV1` возвращает Union-тип — проверяй `__typename` перед использованием полей.

7. **Widevine**: endpoint `api/v1/stream/key` — для DRM расшифровки FLAC. Не реализован в плагине.

8. **Старый домен**: `zvooq.com` — исторический, работает как алиас.

9. **sapi → api/tiny**: На уровне Grid API сapi-пути автоматически преобразуются в api/tiny (функция m13681a в defpackage/csc.java).

10. **Player SDK**: Okko Player используется для некоторых старых мобильных клиентов. LMS не нужна интеграция с Player SDK — используй `stream` URLs напрямую.

11. **GigaMix** (ГигаМикс) — персональный музыкальный ассистент (synthesis плейлисты):
    - **Описание**: Пользователь вводит текстовое описание ("спокойная музыка без слов", "хиты нулевых", и т.д.), нейросеть генерирует плейлист с подходящими треками
    - **UI**: Поле ввода на главной странице с заголовком "Нейросеть подберет треки"
    - **Реализация**: Классы `GigamixGenerationDelegate`, `ApolloMainYourGigamixesRepository`, `GigamixArtistSearchInteractor`
    - **DataSource**: `ApolloGigamixDataSource` → `com.zvuk.feature.gigamix.impl.data.remote`
    - **Interactor**: `GigamixInteractor` (3 метода: m12667a, m12668b, m12669c)

    **GraphQL операция 1: getGenerativePlaylist (инициальная генерация)**
    ```graphql
    query getGenerativePlaylist($queryText: String!, $promptUuid: String) {
      getGenerativePlaylist(queryText: $queryText, promptUuid: $promptUuid) {
        cursor
        playlistName
        tracks {
          __typename
          ...TrackGqlFragment
        }
        genId
      }
    }
    fragment ImageInfoGqlFragment on ImageInfo {
      src palette paletteBottom
    }
    fragment TrackGqlFragment on Track {
      id title artists {
        id title image {
          __typename
          ...ImageInfoGqlFragment
        }
        isWave
      }
      condition duration explicit hasFlac zchan lyrics position
      release {
        id title image {
          __typename
          ...ImageInfoGqlFragment
        }
        date
      }
      searchTitle artistTemplate childParam mark isWave
      streamV2 { preview }
    }
    ```
    
    **Параметры:**
    - `queryText` (String, обязательно) — текстовое описание музыки ("спокойная музыка", "энергичные треки")
    - `promptUuid` (String, опционально) — UUID готового промпта из suggestions
    
    **Возвращаемые поля (GetGenerativePlaylist):**
    - `cursor` (String) — для пагинации следующей страницы
    - `playlistName` (String) — сгенерированное имя плейлиста
    - `tracks` (List[Track]) — массив треков плейлиста
    - `genId` (Int) — ID генерации (для повторного синтеза)

    **GraphQL операция 2: getGenerativePlaylistPage (пагинация треков)**
    ```graphql
    query getGenerativePlaylistPage($limit: Int!, $cursor: Cursor!) {
      getGenerativePlaylistPagination(limit: $limit, cursor: $cursor) {
        cursor
        tracks {
          __typename
          ...TrackGqlFragment
        }
      }
    }
    fragment ImageInfoGqlFragment on ImageInfo {
      src palette paletteBottom
    }
    fragment TrackGqlFragment on Track {
      id title artists {
        id title image {
          __typename
          ...ImageInfoGqlFragment
        }
        isWave
      }
      condition duration explicit hasFlac zchan lyrics position
      release {
        id title image {
          __typename
          ...ImageInfoGqlFragment
        }
        date
      }
      searchTitle artistTemplate childParam mark isWave
      streamV2 { preview }
    }
    ```
    
    **Параметры:**
    - `limit` (Int, обязательно) — количество треков на странице
    - `cursor` (Cursor, обязательно) — cursor из предыдущего ответа
    
    **Возвращаемые поля (GetGenerativePlaylistPagination):**
    - `cursor` (String) — для следующей страницы
    - `tracks` (List[Track]) — следующий batch треков

    **GraphQL операция 3: remakeGenerativePlaylist (повторная генерация)**
    ```graphql
    query remakeGenerativePlaylist($queryText: String!) {
      remakeGenerativePlaylist(queryText: $queryText) {
        cursor
        playlistName
        tracks {
          __typename
          ...TrackGqlFragment
        }
        genId
      }
    }
    fragment ImageInfoGqlFragment on ImageInfo {
      src palette paletteBottom
    }
    fragment TrackGqlFragment on Track {
      id title artists {
        id title image {
          __typename
          ...ImageInfoGqlFragment
        }
        isWave
      }
      condition duration explicit hasFlac zchan lyrics position
      release {
        id title image {
          __typename
          ...ImageInfoGqlFragment
        }
        date
      }
      searchTitle artistTemplate childParam mark isWave
      streamV2 { preview }
    }
    ```
    
    **Параметры:**
    - `queryText` (String, обязательно) — исходное текстовое описание для повторной генерации
    
    **Возвращаемые поля:** идентичны `getGenerativePlaylist`

    **APK Source:**
    - Query classes: `defpackage/txb.java` (getGenerativePlaylist), `defpackage/ixb.java` (getGenerativePlaylistPage), `defpackage/tqo.java` (remakeGenerativePlaylist)
    - Lambda executors: `defpackage/v11.java`, `defpackage/w11.java`, `defpackage/a21.java`
    - Interactor: `com/zvuk/feature/gigamix/impl/domain/GigamixInteractor.java:86, 156, 225`
    - Models: `com/zvuk/feature/gigamix/api/data/model/GigamixPreview.java`, `GigamixPage.java`

---

## Методология исследования и Reverse Engineering

### Перехват сетевых запросов (Network Interception)

#### Инструменты
- **Charles Proxy** (бесплатно 30 дней; $50 лицензия) — популярен для мобильной разработки
- **Burp Suite Community** (бесплатно, открытый код)
- **mitmproxy** (открытый код, CLI-based)
- **Wireshark** (открытый код, низкоуровневый)

#### Настройка для Android

**Шаг 1: Установить корневой сертификат**
```bash
# На устройстве Android:
1. Скачать сертификат с proxy (Settings > Wi-Fi > Modify > Advanced > Install certificate)
2. Переместить в /system/etc/security/cacerts/ (требует root доступ)
   adb root
   adb push certificate.pem /system/etc/security/cacerts/
   adb reboot
```

**Шаг 2: Настроить Wi-Fi proxy**
```
Settings > Wi-Fi > (Long press на сети) > Modify > Advanced
Proxy: Manual
Proxy hostname: <IP вашего ноутбука>
Proxy port: 8888 (Charles по умолчанию)
```

**Шаг 3: Запустить Charles/Burp**
```bash
# Charles Proxy (macOS/Linux/Windows)
charles  # GUI запустится с интерфейсом

# Burp Suite
java -jar burpsuite_community.jar  # GUI запустится

# mitmproxy (CLI)
mitmproxy --listen-host 0.0.0.0 --listen-port 8888
```

**Шаг 4: Перехватить GigaMix запрос**
1. Откройте Zvuk приложение
2. Перейдите на главную (Live main)
3. Найдите поле ввода "Нейросеть подберет треки"
4. Введите текст: "спокойная музыка"
5. В Charles/Burp увидите запрос к `zvuk.com/api/v1/graphql`
6. Скопируйте полный body (POST JSON)

**Пример перехватываемого запроса:**
```
POST https://zvuk.com/api/v1/graphql HTTP/1.1
Host: zvuk.com
Content-Type: application/json
X-Auth-Token: <token>
X-Device-Id: <device_id>
X-App-Name: com.zvooq.openplay

{
  "operationName": "getGenerativePlaylistPreview",
  "variables": {
    "prompt": "спокойная музыка"
  },
  "query": "query getGenerativePlaylistPreview($prompt: String!) { ... }"
}
```

### Анализ деcompiled APK

#### Инструменты
- **JADX** (open-source, GUI) — лучше всего для быстрого поиска
- **Android Studio** (встроенный decompiler)
- **CFR** (командная строка)

#### Поиск GraphQL операций

**Паттерн 1: Поиск по названию операции**
```bash
grep -r "operationName" /path/to/decompiled/apk --include="*.java" | grep "getGenerativePlaylistPreview"
# Или ищите просто строку операции:
grep -r "getGenerativePlaylistPreview\|getGenerativePlaylistPage" /path/to/java/files --include="*.java"
```

**Паттерн 2: Поиск GraphQL query/mutation строк**
```bash
# Все GraphQL операции содержат "query " или "mutation " в return statements
grep -r "return.*\"query\|return.*\"mutation" /path/to/apk/decompiled --include="*.java" | head -50
# Это покажет все операции

# Или целевой поиск:
grep -r "GigaMix\|gigamix\|Gigamix" /path/to/apk/decompiled --include="*.java" -l
# Найдёт все файлы, связанные с GigaMix
```

**Паттерн 3: Поиск Apollo DataSource классов**
```bash
grep -r "implements.*DataSource\|extends.*Repository" /path/to/apk/decompiled --include="*.java" | grep -i "gigamix\|generative"
# Найдёт классы, отправляющие GraphQL запросы

# Для конкретной операции:
grep -r "getGenerativePlaylistPreview\|ApolloGigamixDataSource" /path/to/apk/decompiled --include="*.java" -A 5 -B 5
```

#### Обратный инжиниринг API потока

**Пример: GigaMix (как мы это сделали)**

1. Найдите ViewModel/Interactor класс
   ```bash
   find /path -name "*GigamixInteractor*" -o -name "*GigamixViewModel*"
   ```

2. Посмотрите метод, вызывающий API
   ```bash
   grep -n "m12667a\|getGenerativePlaylistPreview" /path/to/GigamixInteractor.java
   ```

3. Следите за цепочкой вызовов:
   - Interactor → Repository → DataSource (Remote)
   - DataSource отправляет GraphQL

4. Найдите DataSource класс:
   ```bash
   grep -r "ApolloGigamixDataSource" /path/to/apk --include="*.java"
   cat /path/to/ApolloGigamixDataSource.java
   ```

5. В DataSource ищите:
   - Имя операции (например, `"getGenerativePlaylistPreview"`)
   - Переменные (например, `prompt: String`)
   - Возвращаемый тип (например, `GigamixPreview`)

### Маппинг обфусцированного кода

**Частые обфусцированные классы в Zvuk APK:**

| Обфусцированное имя | Вероятное назначение |
|---|---|
| `iod` | Interface для Remote Data Source |
| `jod` | Repository interface |
| `bod` | Interactor/UseCase interface |
| `v11` | Anonymous function/lambda |
| `ApolloGigamixDataSource` | (не обфусцировано) GraphQL DataSource |
| `GigamixRepository` | (не обфусцировано) Repository pattern |
| `GigamixInteractor` | (не обфусцировано) Business logic |

**Как читать обфусцированный код:**

```java
// До обфускации (условный код):
public class GigamixInteractor {
  private GigamixRepository repo;
  
  public GigamixPreview generatePlaylist(String prompt) {
    return repo.getGenerativePlaylistPreview(prompt);
  }
}

// После обфускации (реальный код из APK):
public final class GigamixInteractor implements bod {
  public final jod f30317a;  // repository (обфусцирован как jod)
  
  public final java.io.Serializable m12667a(String r6, ...) {
    // r6 = prompt
    jod r8 = f30317a;
    // вызов getGenerativePlaylistPreview
  }
}
```

### REST API vs GraphQL: Как определить

**Признаки GraphQL:**
- URL заканчивается на `/graphql` (например, `/api/v1/graphql`)
- Body содержит поля: `operationName`, `variables`, `query`
- Content-Type: `application/json`
- Одна операция = один POST запрос

**Признаки REST:**
- Разные URL для разных операций (например, `/api/tiny/profile`, `/api/tiny/grid`)
- GET/POST/PUT/DELETE методы
- Path-based параметры или query params
- Обычно Content-Type: `application/x-www-form-urlencoded` или `application/json`

**Для Zvuk:**
- GraphQL операции → `POST https://zvuk.com/api/v1/graphql`
- REST endpoints → `GET/POST https://zvuk.com/api/tiny/*`, `GET/POST https://zvuk.com/api/v2/*`

### Полезные grep команды для исследования

```bash
# 1. Найти все GraphQL операции
grep -r "return.*\"query\|return.*\"mutation" /path --include="*.java" | wc -l

# 2. Найти конкретный эндпойнт
grep -r "getStream\|getBooks\|getGenerativePlaylist" /path --include="*.java" -l

# 3. Найти все URL пути
grep -r "\"api/\|\"sapi/\|\"topics/" /path --include="*.java" -o | sort -u

# 4. Найти классы, которые отправляют HTTP запросы
grep -r "implements.*DataSource\|extends.*Api" /path --include="*.java" -l

# 5. Найти обработчики ответов
grep -r "GigamixPreview\|SynthesisPlaylist\|GigamixPreview" /path --include="*.java" -l

# 6. Найти вызовы GraphQL операций
grep -r "operationName\|getGenerativePlaylistPreview" /path --include="*.java" -B 3 -A 3
```

### Документирование находок

**Шаблон для новой API операции:**

```markdown
### Operation Name: getGenerativePlaylistPreview

**GraphQL query/mutation:**
```graphql
query getGenerativePlaylistPreview($prompt: String!) {
  generativePlaylistPreview(prompt: $prompt) {
    tracks { ... }
  }
}
```

**Variables:**
- `prompt` (String, required) — текстовое описание музыки

**Response:**
- `GigamixPreview` объект с полями:
  - `tracks: List<Track>` — массив треков

**Найдено в APK:**
- Файл: `com/zvuk/feature/gigamix/impl/domain/GigamixInteractor.java:86`
- DataSource: `ApolloGigamixDataSource`
- Operation name string: `"getGenerativePlaylistPreview"`

**Способ верификации:**
- Network interception: Charles Proxy, Burp Suite
- Статус: ✅ Подтверждено перехватом / ❓ Только из кода
```
