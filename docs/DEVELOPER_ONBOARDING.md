# LMS Zvuk Plugin — Developer Onboarding & Task Plan

**Адресат:** Middle Perl developer  
**Дата:** 2026-05-07  
**Статус:** Immediate fix required: Search 400 Bad Request  

---

## Вводная: состояние проекта

Плагин для интеграции сервиса Zvuk.com в Lyrion Music Server (LMS).

**Текущее состояние:** Alpha/MVP — архитектура верная, но критический баг в поиске блокирует функциональность.

**Основная проблема:** Все запросы к поиску (`searchTracks`, `searchArtists`, `searchAlbums`, `searchPlaylists`) возвращают **HTTP 400 Bad Request**.

**Сроки:** Fix нужен ASAP, остальное — по плану.

---

## Быстрый старт (15 мин)

1. **Клонируй репо:**
   ```bash
   cd /home/chernysh/Projects/lms-zvuk
   git status  # Clean (все коммичено)
   ```

2. **Понимай архитектуру:** Плагин построен на OPMLBased (меню) + GraphQL API (Zvuk).
   - **Браузинг меню:** `Plugin.pm` → вызывает `API/Async.pm` → POST к `https://zvuk.com/api/v1/graphql`
   - **Потоки музыки:** `ProtocolHandler.pm` → декодирует `zvuk://ID` URLs → вызывает `getStream()` → LMS играет

3. **Текущая ошибка:** В `API/Async.pm` метод `getSearchAll` (строка 417) неправильно кодирует JSON variables.

4. **Источник истины:** Сравни с `/home/chernysh/Projects/zvuk-music/zvuk_music/graphql/queries/search.graphql`

---

## Приоритет 1: Исправить Search (400 Bad Request)

### Краткое резюме

**Файл:** `API/Async.pm`  
**Метод:** `getSearchAll` (строки 417-485)  
**Проблема:**
1. Неправильное имя операции: `getSearchAll` вместо `search`
2. Boolean переменные кодируются как integers: `{tracks: 1}` вместо `{tracks: true}`
3. Boolean флаги hardcoded к 1, игнорируют значения из `$args`

**Причина:** GraphQL API Zvuk строгий к типам. JSON integer `1` не проходит валидацию для типа `Boolean`.

### Шаг 1: Обновить GraphQL query definition (строки 430-441)

**Текущий код (неправильный):**
```perl
my $gql = <<'GRAPHQL';
query getSearchAll(
    $query: String,
    $limit: Int,
    $trackCursor: Cursor,
    $artistsCursor: Cursor,
    $releasesCursor: Cursor,
    $playlistsCursor: Cursor,
    $tracks: Boolean,
    $artists: Boolean,
    $releases: Boolean,
    $playlists: Boolean
) {
    search(query: $query) {
```

**Исправленный код:**
```perl
my $gql = <<'GRAPHQL';
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
```

**Почему:**
- Имя `search` = имя операции в API Zvuk (проверено в `/home/chernysh/Projects/zvuk-music/zvuk_music/graphql/queries/search.graphql`)
- Дефолтные значения (`= true`, `= null`) гарантируют что переменные имеют корректное значение даже если не переданы
- `Int = 20` соответствует default limit в zvuk-music library

### Шаг 2: Обновить operationName в вызове (строка 473)

**Текущий код:**
```perl
$self->_graphql($cb, 'getSearchAll', $gql, {
```

**Исправленный код:**
```perl
$self->_graphql($cb, 'search', $gql, {
```

### Шаг 3: Исправить boolean encoding (строки 480-483)

Это **самая важная** часть. В Perl, `1` кодируется как integer в JSON, не как boolean.

**Текущий код (неправильный):**
```perl
    tracks => 1,
    artists => 1,
    releases => 1,
    playlists => 1,
```

**Исправленный код:**
```perl
    tracks => defined($args->{tracks})    ? ($args->{tracks}    ? \1 : \0) : \1,
    artists => defined($args->{artists})   ? ($args->{artists}   ? \1 : \0) : \1,
    releases => defined($args->{releases})  ? ($args->{releases}  ? \1 : \0) : \1,
    playlists => defined($args->{playlists}) ? ($args->{playlists} ? \1 : \0) : \1,
```

**Объяснение:**
- `JSON::XS` (используется в строке 7 imports) кодирует `\1` → `true`, `\0` → `false`
- `?` : ternary operator: если флаг определён, используй его значение, иначе дефолт `true`
- Результат: `{tracks: true}` (JSON boolean), не `{tracks: 1}` (JSON integer)

### Шаг 4: Проверить query fields (строки 445-468)

Убедись что все items содержат нужные поля. Сравни с `/home/chernysh/Projects/zvuk-music/zvuk_music/graphql/queries/search.graphql`:

**Tracks items должны иметь:**
```graphql
items {
    id title duration availability artistTemplate
    release { id title image { src } }
}
```

Сейчас в твоём коде (строка 446-448) уже верно. ✓

Для остальных категорий (artists, releases, playlists) — **нет изменений нужно**.

### Шаг 5: Проверить что Plugin.pm parsing верный

**Файл:** `Plugin.pm`  
**Методы:** `searchTracks`, `searchArtists`, `searchAlbums`, `searchPlaylists`

Парсинг response уже правильный. Примеры (строки 275, 282, 289-292):

```perl
my $searchData = $data->{search};           # Ожидает data.search.*
my $tracks = $searchData->{tracks};         # data.search.tracks
my $items = $tracks->{items} || [];         # data.search.tracks.items
my $page = $tracks->{page} || {};
my $nextCursor = $page->{next};             # data.search.tracks.page.next для пагинации
```

Это соответствует response структуре из `search.graphql`. **Изменений не нужно.**

---

## Тестирование

После того как исправил код:

### 1. Синтаксис Perl

```bash
perl -c /home/chernysh/Projects/lms-zvuk/API/Async.pm
# Output: syntax OK
```

### 2. Прямой тест GraphQL запроса

```bash
cd /home/chernysh/Projects/lms-zvuk

# Требуется ZVUK_TOKEN (user's actual token)
ZVUK_TOKEN=<your_token> bash test/test_search.sh jazz

# Expected output:
# ✓ Status 200 OK (не 400 Bad Request)
# ✓ JSON response с структурой: {search: {tracks: {page, items}, artists: {...}, ...}}
# ✓ В логах: "GraphQL success: search" (не "getSearchAll")
```

### 3. Тест в LMS Web UI

```bash
# 1. Перезагрузи LMS (чтобы подхватил изменения)
sudo systemctl restart slimserver

# 2. Открой http://localhost:9000
# 3. Перейди в: Zvuk > Search > Tracks
# 4. Введи: "jazz"
# 5. Должно появиться: список треков с названиями и артистами

# 6. Если ошибка — смотри логи:
tail -f ~/.squeezebox/cache/log/server.log | grep -i zvuk
```

---

## Что произойдёт после fix

1. `Plugin.pm:searchTracks()` → вызывает `API/Async.pm:searchTracks()`
2. `searchTracks()` → вызывает `getSearchAll()` с правильными параметрами
3. `getSearchAll()` → кодирует JSON с boolean `true`/`false`
4. `_graphql()` → POST к `https://zvuk.com/api/v1/graphql`
5. Zvuk API → возвращает 200 OK с результатами
6. `Plugin.pm` → парсит `$data->{search}->{tracks}` → рендерит в UI
7. LMS Web UI → показывает треки с пагинацией (NEXT_PAGE button)

---

## Архитектура плагина (для контекста)

### File structure

```
lms-zvuk/
├── Plugin.pm                    # OPMLBased plugin, all browse handlers
│                                # - initPlugin() (line 21)
│                                # - handleFeed() (line 76)
│                                # - searchTracks/Artists/Albums/Playlists (lines 257-456)
│                                # - handleArtist/Album/Playlist (lines 623-726)
│                                # - _renderTrack/_renderArtist/_renderAlbum (rendering)
│
├── ProtocolHandler.pm           # Stream resolution для zvuk:// URIs
│                                # - getNextTrack() → вызывает getStream()
│                                # - getMetadataFor() → кеширует metadata
│                                # - explodePlaylist() → разворачивает playlists
│
├── API.pm                       # Статические утилиты
│                                # - getToken(userId)
│                                # - getImageUrl(item)
│                                # - cacheTrackMetadata(tracks) → кеширует для getMetadataFor()
│
├── API/
│   └── Async.pm                 # GraphQL async requests
│                                # - new() constructor with caching
│                                # - _graphql() base method (lines 38-143)
│                                # - getSearchAll() ← ЗДЕСЬ ОШИБКА
│                                # - searchTracks/Artists/Releases/Playlists() wrappers
│                                # - getTracks/getStream/getPlaylistTracks/getAlbum/etc
│
├── Settings.pm                  # Web UI для добавления аккаунтов
├── install.xml                  # Plugin manifest для LMS
├── strings.txt                  # Локализация (EN/RU strings)
├── HTML/EN/html/basic.html      # Account settings template
│
├── docs/
│   ├── LOGGING.md               # How to enable debug logging
│   ├── DEBUGGING.md             # Common issues & solutions
│   └── DEVELOPMENT_PLAN.md      # Full roadmap (later)
│
└── test/
    ├── test_api.sh              # Direct GraphQL testing
    ├── test_search.sh           # Test search with real token
    └── enable_logging.sh        # Automation for debug logging
```

### Data flow при поиске

```
User в LMS Web UI: "Zvuk > Search > Tracks > jazz"
    ↓
Plugin.pm:searchTracks (line 257)
    └─ calls $api->searchTracks({query => 'jazz', cursor => $cursor})
    ↓
API/Async.pm:searchTracks (line 488) [wrapper]
    └─ calls $self->getSearchAll({query, limit, trackCursor, tracks=>1, artists=>0, ...})
    ↓
API/Async.pm:getSearchAll (line 417) ← HERE IS THE BUG
    └─ builds GraphQL query with variables
    └─ calls $self->_graphql($cb, 'search', $gql, $variables)
    ↓
API/Async.pm:_graphql (line 38)
    ├─ Checks cache (MD5 key based on userId + operation + variables)
    ├─ Builds JSON: {operationName: "search", query: "query search(...) {...}", variables: {...}}
    ├─ POST to https://zvuk.com/api/v1/graphql with auth headers
    ├─ Parses response JSON
    ├─ Checks for errors (API returns {data: {...}} or {errors: [...]})
    ├─ Caches result for 1 hour (DYNAMIC_TTL)
    └─ calls callback: $cb->($data) where $data = {search: {tracks: {...}, ...}}
    ↓
Plugin.pm searchTracks callback (line 266)
    ├─ Parses $data->{search}->{tracks}->{items} → list of track hashes
    ├─ Maps each track через _renderTrack($track) → UI hash
    ├─ Extracts $data->{search}->{tracks}->{page}->{next} for pagination
    ├─ Builds NEXT_PAGE button if cursor exists (lines 298-305)
    └─ calls $cb->({items => \@uiItems})
    ↓
LMS Web UI shows results
    └─ User clicks track → ProtocolHandler resolves zvuk://ID
    └─ ProtocolHandler calls getStream() → gets stream URLs
    └─ LMS plays zvuk://ID with resolved stream URL
```

### Async callback pattern

Весь код в плагине использует async callbacks. Пример из `searchTracks`:

```perl
$api->searchTracks(sub {
    my $data = shift;  # ← данные когда ответ готов
    
    if ($data->{error}) {
        # Handle error
        return;
    }
    
    # Process $data
    $cb->({items => \@items});  # ← return results to LMS
}, {query => $query, cursor => $cursor});  # ← pass args
```

Это асинхронный Perl с `Slim::Networking::SimpleAsyncHTTP`. Callback вызывается когда HTTP response пришёл.

### Ключевые концепции

1. **OPMLBased plugin:** Меню items — OPML (Outline Processor Markup Language). Types: `outline`, `link`, `search`, `audio`.

2. **GraphQL @include/@skip:** Используется чтобы запрашивать только нужные данные:
   ```graphql
   artists(limit: $limit, cursor: $cursor) @include(if: $artists) { ... }
   ```
   Если `$artists = false`, поле исключается из response.

3. **Per-account API client:** Каждый configured account получает свой `API::Async` instance с userId. Cache key включает userId.

4. **Caching strategy:**
   - Key: `zvuk_gql:{userId}:{operationName}:MD5({variables})`
   - TTL зависит от типа данных (см. `API.pm` constants: DEFAULT_TTL, DYNAMIC_TTL, USER_CONTENT_TTL, STREAM_TTL)
   - Поиск кешируется на 1 час, stream URLs не кешируются (они с expiration)

5. **Error handling:** Errors в JSON response идут в `result->{errors}`. API errors идут в callback как `{error => 'api_error', details => [...]}`.

---

## Справочные файлы (для сравнения/понимания)

### Правильная реализация (Python)

1. **GraphQL query for search:**
   `/home/chernysh/Projects/zvuk-music/zvuk_music/graphql/queries/search.graphql`
   - Правильный синтаксис, правильные parameter names
   - Используй как reference для GraphQL structure

2. **Python client search method:**
   `/home/chernysh/Projects/zvuk-music/zvuk_music/client_async.py` lines 198-261
   - Показывает как вызывается `self._request.graphql(gql, "search", variables)`
   - Variable names и structure

3. **HTTP request construction:**
   `/home/chernysh/Projects/zvuk-music/zvuk_music/utils/request_async.py` lines 318-368
   - Как строится JSON body: `{query, operationName, variables}`
   - Как отправляется POST к `https://zvuk.com/api/v1/graphql`

4. **MAS (Music Assistant Server) implementation:**
   `/home/chernysh/Projects/Music-Assistant-Server/music_assistant/providers/zvuk_music/`
   - Полная реализация на Python (для reference как использовать zvuk-music library)

### Дебаг логирование

**Включи логирование:**
```bash
bash /home/chernysh/Projects/lms-zvuk/test/enable_logging.sh
# Или вручную отредактируй ~/.squeezebox/prefs/server.prefs:
echo "log4perl.logger.plugin.zvuk = DEBUG" >> ~/.squeezebox/prefs/server.prefs
sudo systemctl restart slimserver
```

**Следи за логами:**
```bash
tail -f ~/.squeezebox/cache/log/server.log | grep -i zvuk
```

**Что ты должен видеть в логах при поиске:**
```
[plugin.zvuk] GraphQL Request: search (userId: 123456, cache: enabled)
[plugin.zvuk] GraphQL URL: https://zvuk.com/api/v1/graphql
[plugin.zvuk] GraphQL Token: 069fad8d...ac3b4
[plugin.zvuk] GraphQL success: search
[plugin.zvuk] Track search results: 342 total, 50 in this batch
```

Если видишь `GraphQL HTTP request failed for search: 400 Bad Request` — проверь что изменения применены.

---

## Чек-лист для выполнения (5 пунктов)

- [ ] **Понимание:** Прочитал весь этот документ, понял проблему
- [ ] **Правка:** Обновил все 3 шага в `API/Async.pm:getSearchAll`
  - [ ] Шаг 1: Query definition (230 строк)
  - [ ] Шаг 2: operationName (line 473)
  - [ ] Шаг 3: Boolean encoding (lines 480-483)
- [ ] **Syntax check:** `perl -c API/Async.pm` returns "syntax OK"
- [ ] **Тест:** `ZVUK_TOKEN=<token> bash test/test_search.sh jazz` returns 200 OK
- [ ] **LMS тест:** LMS Web UI показывает результаты поиска (не ошибку)

---

## Если что-то не понятно

**Свяжись:**
- Автор плана: Alexander Chernysh (audebertenirdnas711@gmail.com)
- Исходные файлы плана: `/home/chernysh/.claude/plans/shiny-baking-moonbeam.md` (полная roadmap)
- Документация: `/home/chernysh/Projects/lms-zvuk/docs/LOGGING.md` (debug guide)

**Что проверить если stuck:**
1. Логирование включено? `grep plugin.zvuk ~/.squeezebox/prefs/server.prefs`
2. LMS перезагружен? `ps aux | grep slimserver | head -1` (check recent start time)
3. Token правильный? `echo $ZVUK_TOKEN` в test скрипте
4. Файлы не случайно перезаписаны? `git diff API/Async.pm | head -50`

---

## Что дальше (после fix)

Если fix успешен, следующие приоритеты (из полного плана):

1. **P1:** ProtocolHandler fixes (stream resolution)
2. **P1:** FLAC handling (DRM vs clear)
3. **P2:** Artist → Albums menu
4. **P2:** Playlist pagination
5. **P3:** Russian localization

Полный roadmap в `/home/chernysh/.claude/plans/shiny-baking-moonbeam.md`.

---

**Удачи в разработке!** 🚀
