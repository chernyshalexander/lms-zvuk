# GigaMix GraphQL API Examples

Документация для тестирования GigaMix AI ассистента (основано на анализе APK v4.109.0rs).

## Endpoint

```
POST https://zvuk.com/api/v1/graphql
```

## Headers (обязательные)

```
x-auth-token: <user_token>
x-app-name: web-zvuk-service-desktop-app
x-device-id: <device_id>
Content-Type: application/json
```

---

## Example 1: Генерация плейлиста (getGenerativePlaylist)

**Request:**

```bash
curl -X POST https://zvuk.com/api/v1/graphql \
  -H "x-auth-token: YOUR_TOKEN" \
  -H "x-app-name: web-zvuk-service-desktop-app" \
  -H "Content-Type: application/json" \
  -d '{
    "operationName": "getGenerativePlaylist",
    "variables": {
      "queryText": "спокойная музыка без слов",
      "promptUuid": null
    },
    "query": "query getGenerativePlaylist($queryText: String!, $promptUuid: String) { getGenerativePlaylist(queryText: $queryText, promptUuid: $promptUuid) { cursor playlistName tracks { __typename id title artists { id title image { __typename src palette paletteBottom } isWave } condition duration explicit hasFlac zchan lyrics position release { id title image { __typename src palette paletteBottom } date } searchTitle artistTemplate childParam mark isWave streamV2 { preview } } genId } }"
  }'
```

**Response:**

```json
{
  "data": {
    "getGenerativePlaylist": {
      "cursor": "eyJvZmZzZXQiOiAyMH0=",
      "playlistName": "Спокойная вечерняя атмосфера",
      "tracks": [
        {
          "__typename": "Track",
          "id": "1234567",
          "title": "Ambient Song 1",
          "artists": [
            {
              "id": "artist123",
              "title": "Artist Name",
              "image": {
                "__typename": "ImageInfo",
                "src": "https://cdn-image.zvuk.com/.../path/{size}/image.jpg",
                "palette": "#FF5733",
                "paletteBottom": "#33FF57"
              },
              "isWave": false
            }
          ],
          "condition": "active",
          "duration": 245,
          "explicit": false,
          "hasFlac": true,
          "zchan": "zhero",
          "lyrics": true,
          "position": 1,
          "release": {
            "id": "release456",
            "title": "Album Name",
            "image": {
              "__typename": "ImageInfo",
              "src": "https://cdn-image.zvuk.com/.../path/{size}/album.jpg",
              "palette": "#112233",
              "paletteBottom": "#445566"
            },
            "date": "2024-01-15"
          },
          "searchTitle": "Ambient Song 1",
          "artistTemplate": "",
          "childParam": "none",
          "mark": "old",
          "isWave": false,
          "streamV2": {
            "preview": "https://stream.zvuk.com/track/1234567/preview.mp3?token=..."
          }
        }
        // ... еще треки
      ],
      "genId": 42
    }
  }
}
```

---

## Example 2: Пагинация (getGenerativePlaylistPage)

**Request:**

```bash
curl -X POST https://zvuk.com/api/v1/graphql \
  -H "x-auth-token: YOUR_TOKEN" \
  -H "x-app-name: web-zvuk-service-desktop-app" \
  -H "Content-Type: application/json" \
  -d '{
    "operationName": "getGenerativePlaylistPage",
    "variables": {
      "limit": 20,
      "cursor": "eyJvZmZzZXQiOiAyMH0="
    },
    "query": "query getGenerativePlaylistPage($limit: Int!, $cursor: Cursor!) { getGenerativePlaylistPagination(limit: $limit, cursor: $cursor) { cursor tracks { __typename id title artists { id title image { __typename src palette paletteBottom } isWave } condition duration explicit hasFlac zchan lyrics position release { id title image { __typename src palette paletteBottom } date } searchTitle artistTemplate childParam mark isWave streamV2 { preview } } } }"
  }'
```

**Response:**

```json
{
  "data": {
    "getGenerativePlaylistPagination": {
      "cursor": "eyJvZmZzZXQiOiA0MH0=",
      "tracks": [
        // ... следующие 20 треков
      ]
    }
  }
}
```

---

## Example 3: Повторная генерация (remakeGenerativePlaylist)

**Request:**

```bash
curl -X POST https://zvuk.com/api/v1/graphql \
  -H "x-auth-token: YOUR_TOKEN" \
  -H "x-app-name: web-zvuk-service-desktop-app" \
  -H "Content-Type: application/json" \
  -d '{
    "operationName": "remakeGenerativePlaylist",
    "variables": {
      "queryText": "спокойная музыка без слов"
    },
    "query": "query remakeGenerativePlaylist($queryText: String!) { remakeGenerativePlaylist(queryText: $queryText) { cursor playlistName tracks { __typename id title artists { id title image { __typename src palette paletteBottom } isWave } condition duration explicit hasFlac zchan lyrics position release { id title image { __typename src palette paletteBottom } date } searchTitle artistTemplate childParam mark isWave streamV2 { preview } } genId } }"
  }'
```

---

## Field Descriptions

### Track Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Track ID (для getStream запроса) |
| `title` | String | Название трека |
| `artists` | Artist[] | Массив артистов |
| `duration` | Int | Длина в секундах |
| `release` | Release | Альбом/релиз |
| `explicit` | Boolean | Содержит ненормативную лексику |
| `hasFlac` | Boolean | Доступна FLAC версия |
| `condition` | String | Статус ("active", "explicit", и т.д.) |
| `streamV2.preview` | String | URL preview версии (128kbps) |

### Response Fields

| Field | Type | Description |
|-------|------|-------------|
| `cursor` | String | Base64-encoded pagination cursor (или null если нет больше) |
| `playlistName` | String | Сгенерированное имя плейлиста |
| `tracks` | Track[] | Массив треков плейлиста |
| `genId` | Int | ID генерации (для remakeGenerativePlaylist) |

---

## Popular Prompts

Примеры текстов, которые работают хорошо:

- "спокойная музыка без слов"
- "энергичные треки для тренировки"
- "хиты нулевых"
- "русский рок"
- "электронная танцевальная музыка"
- "инструментальная классическая музыка"
- "поп-музыка последних лет"
- "рэп и хип-хоп"
- "поднимающее настроение"

---

## Notes for Implementation

1. **Preview URL:** `streamV2.preview` содержит готовый MP3 preview (не требует getStream запроса)
2. **Full Stream:** для полной версии трека → используй стандартный `getStream(trackId: $id, quality: HIGH)` запрос
3. **Cursor Pagination:** cursor не требует декодирования — передай как-есть в следующий запрос
4. **Error Handling:** ошибки обычно приходят в `errors[]` array в JSON ответе
5. **Rate Limiting:** нет известных限制, но рекомендуется не более 1 запроса в сек

---

## Source Code References (APK v4.109.0rs)

**Query Classes:**
- `defpackage/txb.java` — getGenerativePlaylist operation
- `defpackage/ixb.java` — getGenerativePlaylistPage operation
- `defpackage/tqo.java` — remakeGenerativePlaylist operation

**Executors:**
- `defpackage/v11.java` — lambda for getGenerativePlaylist
- `defpackage/w11.java` — lambda for getGenerativePlaylistPage
- `defpackage/a21.java` — lambda for remakeGenerativePlaylist

**Models:**
- `com/zvuk/feature/gigamix/api/data/model/GigamixPreview.java` — response model
- `com/zvuk/feature/gigamix/impl/data/remote/ApolloGigamixDataSource.java` — GraphQL client

---

**Last Updated:** 2026-06-15 (Analysis of APK v4.109.0rs)
