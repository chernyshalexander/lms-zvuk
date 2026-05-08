# Zvuk.com API — Документация

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

Токен текущего пользователя: см. файл `a.chernysh.token`

### Получение профиля

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

> Из профиля получаем `userId` — числовой ID пользователя для запросов коллекции.

---

## GraphQL Endpoint

```
POST https://zvuk.com/api/v1/graphql
```

### Обязательные заголовки (из анализа браузерных запросов)

```http
content-type: application/json
accept: application/graphql-response+json, application/json
x-auth-token: <token>
x-app-name: web-zvuk-service-desktop-app
x-device-id: <uuid>              # статичный UUID устройства
origin: https://zvuk.com
referer: https://zvuk.com/
user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ...
```

> **x-app-name** и **x-device-id** критичны для прохождения WAF.

**Тело запроса:**
```json
{
  "operationName": "<OperationName>",
  "variables": { ... },
  "query": "<GraphQL query string>"
}
```

---

## Операции

### 1. getStream — получение ссылок на потоки треков

**Назначение:** Получить URL для воспроизведения трека/эпизода/главы.

**Переменные:**
- `ids: [ID!]!` — массив ID треков

**Запрос:**
```graphql
query getStream($ids: [ID!]!) {
  mediaContents(ids: $ids) {
    __typename
    ... on Track {
      stream {
        expire
        expireDelta
        flacdrm
        high
        mid
      }
    }
    ... on Episode {
      stream {
        expire
        expireDelta
        high
        mid
      }
    }
    ... on Chapter {
      stream {
        expire
        expireDelta
        high
        mid
      }
    }
  }
}
```

**Поля stream:**
| Поле | Тип | Описание |
|------|-----|----------|
| `expire` | string | Время истечения URL |
| `expireDelta` | int | Секунд до истечения |
| `flacdrm` | string? | URL FLAC с DRM (требует подписки) |
| `high` | string? | URL MP3 высокого качества (требует подписки) |
| `mid` | string | URL MP3 среднего качества |

**Логика выбора качества:**
- Качество `High` → `stream.high` (если нет подписки — ошибка)
- Качество `Middle` → `stream.mid`
- Авто → `stream.high ?? stream.mid`

---

### 2. getFullTrack — полные данные трека

**Переменные:**
- `ids: [ID!]!` — массив ID треков
- `withReleases: Boolean = false` — включить данные альбома
- `withArtists: Boolean = false` — включить данные артистов

**Запрос:**
```graphql
query getFullTrack($ids: [ID!]!, $withReleases: Boolean = false, $withArtists: Boolean = false) {
  getTracks(ids: $ids) {
    id
    title
    searchTitle
    position
    duration
    availability
    artistTemplate
    condition
    explicit
    lyrics
    zchan
    hasFlac
    genres { id name shortName }
    collectionItemData { itemStatus }
    artists @include(if: $withArtists) {
      id title searchTitle description hasPage
      image { src palette paletteBottom }
      secondImage { src palette paletteBottom }
    }
    release @include(if: $withReleases) {
      id title searchTitle type date
      image { src palette paletteBottom }
      genres { id name shortName }
      label { id title }
      availability
      artistTemplate
    }
  }
}
```

**Поля Track:**
| Поле | Тип | Описание |
|------|-----|----------|
| `id` | string | Уникальный ID трека |
| `title` | string | Название |
| `searchTitle` | string | Название для поиска |
| `position` | int | Позиция в альбоме |
| `duration` | int | Длительность в секундах |
| `availability` | int | 0=недоступен, 1=доступен |
| `artistTemplate` | string | Форматированная строка исполнителей |
| `explicit` | bool | Наличие ненормативной лексики |
| `lyrics` | bool/null | Есть ли текст |
| `zchan` | string? | Канал (для подкастов) |
| `hasFlac` | bool | Доступен ли FLAC |

---

### 3. getTracks — краткие данные треков

**Переменные:**
- `ids: [ID!]!` — массив ID треков

Возвращает треки с полями `artists` и `release` в краткой форме (без `genres`).

---

### 4. getReleases — альбомы/релизы

**Переменные:**
- `ids: [ID!]!` — массив ID альбомов
- `withTracks: Boolean = false` — включить треки
- `withArtists: Boolean = false` — включить артистов

**Поля Release (Album):**
| Поле | Тип | Описание |
|------|-----|----------|
| `id` | string | ID |
| `title` | string | Название |
| `type` | string | Тип (album, single, ep) |
| `date` | string | Дата релиза |
| `image` | Image | Обложка |
| `genres` | Genre[] | Жанры |
| `label` | Label | Лейбл |
| `availability` | int | Доступность |
| `artistTemplate` | string | Исполнители |
| `artists` | Artist[]? | Артисты (если withArtists) |
| `tracks` | Track[]? | Треки (если withTracks), включая `stream` |

**Важно:** При `withTracks=true` объект каждого трека содержит поле `stream` с URL для воспроизведения.

---

### 5. getPlaylists — плейлисты

**Переменные:**
- `ids: [ID!]!` — массив ID плейлистов

**Поля Playlist:**
| Поле | Тип | Описание |
|------|-----|----------|
| `id` | string | ID |
| `title` | string | Название |
| `userId` | string | ID владельца |
| `description` | string | Описание |
| `image` | Image | Обложка |
| `updated` | string | Дата обновления |
| `duration` | int | Суммарная длительность |
| `branded` | bool | Брендовый плейлист |
| `shared` | bool | Общий доступ |
| `isPublic` | bool | Публичный |
| `isDeleted` | bool | Удалён |
| `chart` | ChartItem[]? | Чарт (trackId + positionChange) |
| `tracks` | Track[] | Треки плейлиста |

---

### 6. getSearch (quickSearch) — быстрый поиск

**Переменные:**
- `query: String` — поисковый запрос
- `limit: Int` — лимит результатов (по умолч. 10)
- `searchSessionId: String` — ID сессии поиска

**Ответ:**
```json
{
  "data": {
    "quickSearch": {
      "searchSessionId": "...",
      "content": [
        { "__typename": "Track", "id": "...", "title": "...", "artistTemplate": "...", ... },
        { "__typename": "Artist", "id": "...", "title": "...", "image": {...} },
        { "__typename": "Release", "id": "...", "title": "...", "date": "...", ... },
        { "__typename": "Playlist", "id": "...", "title": "...", "isPublic": true, ... }
      ]
    }
  }
}
```

---

### 7. getSearchAll — расширенный поиск с пагинацией

**Переменные:**
- `query: String`
- `limit: Int = 2`
- Курсоры для каждой категории: `trackCursor`, `artistsCursor`, `releasesCursor`, etc.
- Флаги включения: `tracks`, `artists`, `releases`, `playlists`, `profiles`, `books`, `bookAuthors`, `episodes`, `podcasts`, `categories`

**Категории результатов:**
- `tracks` — музыкальные треки
- `artists` — исполнители
- `releases` — альбомы
- `playlists` — плейлисты
- `profiles` — профили пользователей
- `books` — аудиокниги
- `bookAuthors` — авторы книг
- `episodes` — эпизоды подкастов
- `podcasts` — подкасты
- `categories` — жанровые категории

**Пагинация:** каждая категория содержит объект `page`:
```json
{
  "page": {
    "total": 150,
    "prev": null,
    "next": "cursor_string",
    "cursor": "cursor_string"
  }
}
```

---

## Операции коллекции пользователя (из браузерных запросов)

### 8. getPaginatedCollection — треки "Моя музыка"

**Переменные:**
- `limit: Int = 30` — количество треков на страницу
- `after: String = null` — курсор для пагинации (cursor-based)

**Запрос:**
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
      page {
        endCursor
      }
    }
  }
}
```

**Пагинация**: использует `page.endCursor` как `after` для следующей страницы.

---

### 9. getCollectionCount — количество треков в коллекции

```graphql
query getCollectionCount {
  collectionCount {
    tracks
  }
}
```

---

### 10. getPlaylistTracks — треки плейлиста (offset-based)

**Переменные:**
- `id: ID!` — ID плейлиста
- `limit: Int = 30`
- `offset: Int = 0`

```graphql
query getPlaylistTracks($id: ID!, $limit: Int = 30, $offset: Int = 0) {
  playlistTracks(id: $id, limit: $limit, offset: $offset) {
    id title lyrics hasFlac duration explicit availability
    artistTemplate childParam mark zchan
    artists { id title image { src palette } mark }
    release { id title image { src palette } }
    __typename
  }
}
```

---

### 11. getPersonalWave — персональная волна (миксы)

**Переменные:**
- `waveSrc: MagicSource` — источник (например, `"AMAZME"`)
- `first: PositiveInt = 2` — количество треков
- `waveType: String` — тип волны (например, `"FAVTRACKS"`)

```graphql
query getPersonalWave($contentInput: PersonalWaveContentInput, $first: PositiveInt! = 2,
                      $options: PersonalWaveOptions, $waveInput: WaveInput, $waveSrc: MagicSource) {
  personalWaveContent(contentInput: $contentInput, first: $first,
                      options: $options, waveInput: $waveInput, waveSrc: $waveSrc) {
    # возвращает треки в формате PlayerTrackData
    id title lyrics hasFlac duration explicit availability artistTemplate
    artists { id title image { src palette } }
    release { id title image { src palette } }
  }
}
```

---

## Воспроизведение (важно!)

### Браузер vs LMS плагин

**Браузер** использует HLS DRM:
```
https://cdn-hls-slicer.zvuk.com/drm/track/<id>_<n>/init-smq-a1.mp4
```
Это MP4-фрагменты HLS с DRM — **не подходит для LMS**.

**LMS плагин** должен использовать `getStream` → поля `stream.mid` / `stream.high`:
- `stream.mid` — прямой MP3 URL (~192k), доступен без подписки
- `stream.high` — прямой MP3 URL (320k), требует подписки
- `stream.flacdrm` — FLAC с DRM (природа DRM требует уточнения)

> **Рекомендация для MVP**: использовать только `stream.mid` / `stream.high` (прямые MP3 URL). FLAC DRM оставить для будущего исследования.

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

**Форматирование URL изображений:**
```
src?width=<W>&height=<H>
```
Пример: `https://cdn.zvuk.com/images/track/123/cover.jpg?width=500&height=500`

### Genre
```json
{ "id": "1", "name": "Rock", "shortName": "rock" }
```

### Label
```json
{ "id": "100", "title": "Universal Music" }
```

---

## Доступность (availability)

| Значение | Описание |
|----------|----------|
| `0` | Недоступен |
| `1` | Доступен (бесплатно/с подпиской) |

---

## Качество аудио

| Уровень | Поле stream | Формат | Требования |
|---------|-------------|--------|------------|
| High | `stream.high` | MP3 320k | Подписка |
| Middle | `stream.mid` | MP3 128-192k | Бесплатно |
| FLAC DRM | `stream.flacdrm` | FLAC | Подписка |

**Важно:** URL потока временный — содержит параметры `expire` и `expireDelta`.

---

## REST API (дополнительные эндпоинты)

### Профиль пользователя
```
GET https://zvuk.com/api/tiny/profile
Headers: X-Auth-Token: <token>
```

### Коллекция (избранное)
Предположительно доступны через REST или GraphQL:
- Избранные треки пользователя
- Избранные альбомы
- Плейлисты пользователя

> Требуется дополнительное исследование через браузер или перехват запросов веб-приложения.

---

## Примечания

1. **quickSearch vs search**: `quickSearch` даёт смешанные результаты (треки+артисты+альбомы), идеален для автодополнения. `getSearchAll` (операция `search`) даёт точный поиск по категориям с пагинацией.

2. **URL потока**: Необходимо периодически обновлять — URL имеет TTL (`expireDelta` секунд).

3. **FLAC с DRM**: Поле `flacdrm` содержит URL FLAC, возможно с DRM-защитой. Требует дополнительного исследования формата.

4. **Типы контента**: API поддерживает треки (`Track`), эпизоды подкастов (`Episode`) и главы аудиокниг (`Chapter`) через единый интерфейс `mediaContents`.
