# Исследовательский отчёт по приложению Zvuk → план улучшения LMS-плагина

> Дата: 2026-07-06
> Источник: JADX-декомпиляция APK `com.zvooq.openplay` v4.109.0rs + код плагина `/home/chernysh/Projects/lms-zvuk/`
> Аудитория: разработчик уровня middle, который будет дорабатывать плагин
> Статус фактов: всё, что помечено ✅ VERIFIED, перепроверено по исходникам APK в этой сессии (указаны файлы). Помеченное ⚠️ — получено перехватом браузера / не подтверждено в APK.

---

## 0. Как читать этот отчёт

Существующий документ `docs/zvuk_api.md` (1704 строки) — подробный справочник по API. Он в целом **точен**, но смешивает три источника достоверности:
1. факты из APK,
2. факты из перехвата веб-запросов,
3. несколько неточностей/устаревших имён.

Этот отчёт **не дублирует** `zvuk_api.md`. Он делает три вещи:
- **Верификация** — что из документации реально подтверждается кодом APK (раздел 2).
- **Gap-анализ** — что умеет приложение, что реализовано в плагине, что задокументировано-но-не-сделано (раздел 5).
- **План работ** — приоритизированные улучшения с готовыми GraphQL-запросами и ссылками на код (раздел 6).

---

## 1. Резюме (TL;DR)

- **WAF-алгоритм `X-Session-UID` реален и полностью воспроизводим.** Он подтверждён в `defpackage/clv.java`. Описание в `zvuk_api.md` (SHA-256 → uppercase hex → raw DEFLATE → XOR с App-Instance → Base64 NO_WRAP) совпадает с кодом байт-в-байт. **Но** плагин его сейчас **не** использует и работает — потому что ходит по «веб-десктоп» пути (`x-app-name: web-zvuk-service-desktop-app`), где WAF его не требует. Держите алгоритм как аварийный fallback (раздел 3).
- **Полный набор заголовков Android-приложения подтверждён** в `defpackage/blv.java` (X-App-Version, X-App-Build, X-Screen-*, X-MNC и т.д.). Для веб-пути плагина они не нужны — не тратьте время на их эмуляцию.
- **Магические константы подтверждены:** версия `4.109.0rs`, build `510900179`, enum качества `MID/HIGH/FLAC/ADAPTIVE_*`, типы стрима `TRACK/AUDIOBOOK_CHAPTER/PODCAST_EPISODE/RADIO`, список хостов.
- **Найдена готовая невнедрённая фича:** `recommenderRadio` — «запустить радио по треку/артисту/альбому». Полный запрос извлечён из APK (раздел 6.1). Это самый дешёвый по трудозатратам и заметный по эффекту апгрейд.
- **`quickSearch` в APK отсутствует** — в `zvuk_api.md` он описан, но это устаревшее/веб-имя. Плагин корректно использует `search`, ничего чинить не нужно, но из будущих планов `quickSearch` уберите.

---

## 2. Верификация существующей документации по APK

| Утверждение в `zvuk_api.md` | Вердикт | Доказательство (файл APK) |
|---|---|---|
| Алгоритм `X-Session-UID` (DEFLATE+XOR+Base64) | ✅ VERIFIED, точен | `defpackage/clv.java:47-99`, конкатенация `defpackage/qp6.java:89` |
| Заголовки `X-App-Version=4.109.0rs`, `X-App-Build=510900179` | ✅ VERIFIED | `defpackage/blv.java:93,96` |
| Заголовки `X-Screen-Width/Height/Density`, `X-MNC`, `X-Service-Provider-Name`, `X-Advertising-ID`, `X-Client-Time`, `X-Zvuk-Profile-Id` | ✅ VERIFIED (все ставятся в одном интерсепторе) | `defpackage/blv.java:66-138` |
| Качество: `mid/high/flac/flacdrm/adaptive_*` | ✅ VERIFIED (enum клиента) | `com/zvuk/playerstreams/models/StreamQuality.java:13-19` |
| Типы контента для стрима | ✅ VERIFIED | `com/zvuk/playerstreams/models/StreamType.java:15-18` |
| Хосты prod/preprod/stage/алиасы | ✅ VERIFIED | литералы в `com/zvuk/network/*` (см. раздел 4) |
| GraphQL `personalWaveContent`, `listeningRecentV1`, `dynamicBlock`, `getGenerativePlaylist`, `availableWaves`, `paginatedCollection`, `playlistTracks`, `getBooks`, `getChapters`, `relatedBooks`, `recommenderRadio` | ✅ VERIFIED (присутствуют как литералы операций в APK) | grep по `defpackage/*.java` |
| GraphQL `quickSearch` | ❌ НЕ найден в APK | 0 совпадений; вероятно веб-only/устаревшее |
| Поле `stream.flacdrm` в ответе `getStream` | ⚠️ Только перехват | литерала `flacdrm` в APK нет — запрос собран по браузеру, не по APK |
| Заголовок `x-app-name: web-zvuk-service-desktop-app` | ⚠️ Веб-значение | в Android-коде отсутствует (Android шлёт другой идентификатор); значение корректно для веб-пути, менять не нужно |

**Вывод для разработчика:** документации `zvuk_api.md` можно доверять по заголовкам, константам и большинству GraphQL-операций. Осторожно с `quickSearch` (не существует) и с точными именами полей `stream` (они из перехвата, не из APK — при 400-й ошибке проверяйте реальным перехватом).

---

## 3. WAF и заголовки — что важно для плагина

### 3.1. Текущее состояние плагина

`API/Async.pm:285-296` отправляет минимальный набор:
```
x-auth-token, x-app-name (web-zvuk-service-desktop-app), x-device-id,
origin, referer, user-agent, content-type, accept
```
Этого **достаточно** для веб-GraphQL-эндпоинта. `X-Session-UID` не считается и не отправляется — и это ОК, пока WAF не ужесточат.

### 3.2. Алгоритм `X-Session-UID` (аварийный fallback) ✅ VERIFIED

Источник: `defpackage/clv.java`. Интерсептор ставит ровно 5 заголовков: `User-Agent`, `Referer`, `X-Timestamp`, `X-App-Instance`, `X-Session-UID`.

Точный алгоритм (для реализации на Perl при необходимости):
```
appInstance = <статичный per-install UUID>       # у плагина это device_id
ts          = floor(time())                        # секунды, строкой
ua          = <строка User-Agent>

input   = appInstance . ts . ua                    # ← порядок именно такой (qp6.m30935g)
digest  = SHA256(input, utf8)                      # сырые байты
hexUpper = uppercase_hex(digest)                   # 64 символа "%02X"
packed  = raw_deflate(hexUpper.bytes, level=default, nowrap=true)  # zlib raw, без zlib-обёртки
# XOR первых N байт с байтами appInstance:
for i in 0..len(packed)-1:
    out[i] = (i < len(appInstance)) ? packed[i] ^ appInstance.bytes[i] : packed[i]
X-Session-UID = base64(out, NO_WRAP)               # без переносов строк
```
Ключевые тонкости, где легко ошибиться:
- HEX должен быть **в верхнем регистре** (`%02X`), и деflate применяется к **hex-строке**, а не к сырому digest.
- DEFLATE — **raw** (`nowrap=true`, в Java `new Deflater(-1, true)`). В Perl: `Compress::Raw::Zlib` с `-WindowBits => -MAX_WBITS`.
- XOR только по первым `len(appInstance)` байтам, остальные байты остаются как есть.
- Base64 без переносов (в Java флаг `2` = `NO_WRAP`).
- `X-App-Instance` = тот же идентификатор, что и в XOR (у плагина — `device_id`).

`X-Timestamp` в этом же запросе должен совпадать с тем `ts`, что участвовал в хеше.

### 3.3. Полный набор Android-заголовков (для справки, НЕ реализовывать)

`defpackage/blv.java` — второй интерсептор, ставит: `X-MNC`, `X-Service-Provider-Name`, `X-Screen-Width/Height/Density`, `X-Device-Id`, `X-App-Version=4.109.0rs`, `Accept-Language`, `X-App-Build=510900179`, `X-Client-Time` (ISO-8601 с таймзоной), `X-Advertising-ID`, `X-Zvuk-Profile-Id/Type` (только kids-режим). Всё это специфично для мобильного клиента; веб-путь плагина в них не нуждается.

---

## 4. Магические константы (сводка проверенного)

| Константа | Значение | Источник |
|---|---|---|
| App version | `4.109.0rs` | `blv.java:93`, много мест |
| App build | `510900179` | `blv.java:96`, `SplashActivity.java:1421` |
| GraphQL endpoint | `POST https://zvuk.com/api/v1/graphql` | плагин + доки |
| Prod host | `zvuk.com` | `com/zvuk/network/*` |
| Preprod | `preprod.zvq.me` | там же |
| Stage | `stage1.zvq.me` … `stage6.zvq.me` | там же |
| Алиасы | `zvooq.com`, `sber-zvuk.com` | там же |
| Качество (enum клиента) | `MID, HIGH, FLAC, ADAPTIVE_MID, ADAPTIVE_HIGH, ADAPTIVE_FLAC, ADAPTIVE` | `StreamQuality.java` |
| Типы стрима | `TRACK, AUDIOBOOK_CHAPTER, PODCAST_EPISODE, RADIO` | `StreamType.java` |
| Битрейты (оценка плагина) | flac≈900k, high=320k, mid=128k | `ProtocolHandler.pm:130` |

> Примечание по качеству: в GraphQL-ответе `getStream` плагин запрашивает поля `high/mid/flac/flacdrm`. Enum клиента подтверждает существование самостоятельного **`FLAC`** (не только `flacdrm`), поэтому попытка плагина читать `stream.flac` осмысленна. Но поле `flacdrm` в APK как строка не встречается — имена полей `stream` стоит перепроверять перехватом, а не считать каноном.

---

## 5. Gap-анализ: приложение vs плагин vs документация

| Функция | Есть в приложении | Реализовано в плагине | Задокументировано | Комментарий |
|---|---|---|---|---|
| Поиск (треки/артисты/альбомы/плейлисты) | ✅ | ✅ `search` | ✅ | Готово |
| Коллекция (треки/альбомы/артисты/плейлисты/подкасты/эпизоды) | ✅ | ✅ | ✅ | Готово |
| Топ-треки + альбомы артиста | ✅ | ✅ | ✅ | Готово |
| Плейлист / альбом → треки | ✅ | ✅ | ✅ | Готово |
| Персональная волна + настройки | ✅ | ✅ `getPersonalWave` | ✅ | Готово |
| GigaMix (AI-плейлист по тексту) | ✅ | ✅ 3 операции | ✅ | Готово |
| Рекомендации главного экрана | ✅ `dynamicBlock` | ⚠️ частично (`getMusicRecommendations` есть в Async, но не в UI-меню) | ✅ | Довести до меню |
| **Радио по сущности** `recommenderRadio` | ✅ | ❌ | ⚠️ упомянуто | **Лучший ROI, раздел 6.1** |
| История прослушивания `listeningRecentV1` | ✅ | ❌ | ✅ | Раздел 6.2 |
| Аудиокниги (книги/главы/авторы) | ✅ | ❌ | ✅ | Раздел 6.3 |
| Лайк/добавление в коллекцию (мутации) | ✅ | ❌ | ✅ | Раздел 6.4 |
| Synthesis-плейлисты «для вас» | ✅ | ❌ (`_getCollectionSynthesis` → []) | частично | Требует доп. перехвата |
| FLAC DRM (Widevine) | ✅ | ❌ (и не нужно) | ✅ | Вне области LMS |

Ссылки на состояние плагина: TODO-заглушки — `API/Async.pm:828-834` (synthesis), `API/Async.pm:1039-1053` (`getSynthesisPlaylists`). Рекомендации уже есть в `API/Async.pm:1056` (`getMusicRecommendations`), но не выведены в OPML-меню.

---

## 6. Приоритизированный план улучшений

Приоритет = (польза для пользователя) / (трудозатраты). Все GraphQL ниже подтверждены в APK.

### 6.1. ⭐ Радио по треку/артисту/альбому — `recommenderRadio` (Приоритет 1)

**Почему первым:** одна новая операция + пункт контекстного меню. Даёт «бесконечное радио» из любой сущности — киллер-фича для LMS-плеера. Механику автодогрузки очереди в плагине уже реализована для волны (`ProtocolHandler.pm:_loadMoreWaveTracks`) — её можно переиспользовать почти без изменений.

**Запрос (извлечён из APK ✅ VERIFIED):**
```graphql
query recommenderRadio($id: ID!, $type: RecommenderRadioEntityType!, $limit: NonNegativeInt! = 25, $cursor: NonNegativeInt = 0) {
  recommenderRadio(onEntity: { id: $id, type: $type }, first: $limit, cursor: $cursor) {
    cursor
    tracks { __typename ...TrackGqlFragment }
  }
}
fragment ImageInfoGqlFragment on ImageInfo { src palette paletteBottom }
fragment TrackGqlFragment on Track {
  id title artists { id title image { __typename ...ImageInfoGqlFragment } isWave }
  condition duration explicit hasFlac zchan lyrics position
  release { id title image { __typename ...ImageInfoGqlFragment } date }
  searchTitle artistTemplate childParam mark isWave
  streamV2 { preview }
}
```
- `type` = `RecommenderRadioEntityType` (значения по смыслу: TRACK / ARTIST / RELEASE — подтвердить перехватом при интеграции).
- Пагинация: `cursor` (числовой, `NonNegativeInt`), скармливается обратно в `cursor`.
- Стрим-URL берётся отдельным `getStream(ids:[trackId])`, как и везде в плагине.

**Интеграция:** добавить метод `getRecommenderRadio` в `API/Async.pm` по образцу `getPersonalWave`; в `Plugin.pm` добавить пункт «Радио по треку/артисту» в контекстное меню; переиспользовать `zvuk_wave_active`-механику автодогрузки в `ProtocolHandler.pm`.
Источник в APK: `query recommenderRadio` в `defpackage/` (см. grep в разделе 8).

### 6.2. История прослушивания — `listeningRecentV1` (Приоритет 1)

**Почему:** простой read-only список для нового раздела меню «Недавнее». Запрос уже полностью в `zvuk_api.md`. Union-тип — проверяйте `__typename` (Artist/Release/Playlist/Book/Podcast/Episode). `itemType` из `RecentItemType`: `TRACK_HISTORY_ITEM`, `PODCAST_EPISODE_HISTORY_ITEM`, `AUDIOBOOK_CHAPTER_HISTORY_ITEM`. Offset-пагинация.

### 6.3. Аудиокниги (Приоритет 2)

**Почему:** большой пласт контента, всё API уже документировано (`getBooks`, `getChapters`, `getBookAuthors`, `getAuthorsCursorBooks`, `relatedBooks` — все ✅ присутствуют в APK). Воспроизведение главы: `mediaContents(ids:[chapterId])` → `... on Chapter { stream { mid high } }` — та же схема, что треки. Объём работы средний: новые OPML-ветки + маппинг моделей Book/Chapter.

### 6.4. Лайки и управление коллекцией (Приоритет 2)

**Почему:** превращает плагин из read-only в интерактивный. Мутации `addCollectionItem` / `removeCollectionItem` / `addItemV1` документированы. `CollectionItemType`: `track, release, artist, playlist, podcast, episode, book, chapter, bookAuthor`. Реализуется как действия в контекстном меню LMS. Внимание: после мутации инвалидируйте кэш коллекции (ключи `zvuk_gql:*:userTracks:*` и т.п., TTL сейчас 300с в `API.pm:USER_CONTENT_TTL`).

### 6.5. Довести рекомендации до меню (Приоритет 3)

`getMusicRecommendations` (`dynamicBlock`) уже реализован в `API/Async.pm:1056`, но не выведен в OPML. Малая работа: добавить раздел «Рекомендации/Открытие» в `Plugin.pm`, использовать `contentType`/`itemType`/`pages` (пагинация по страницам).

### 6.6. Synthesis-плейлисты «для вас» (Приоритет 4, требует ресёрча)

`_getCollectionSynthesis` возвращает `[]`. В `getSynthesisPlaylists` есть гипотеза (ID 3,4,6,11–15 + `mediaContents ... on Playlist`), но операция не подтверждена. **Нужен перехват** реального запроса приложения — без него не внедрять.

---

## 7. UI, ресурсы, иконки

Иконочный набор и CDN-форматы подробно описаны в `zvuk_api.md` (раздел «UI Icons & Resources») и подтверждаются наличием COLT-дизайн-системы в APK. Для плагина практически значимо:
- **Готовые иконки уже лежат в репозитории плагина** (`HTML/EN/plugins/zvuk/html/images/`): search, albums, artists, playlists, podcast, radio, favorites, personal, gigamix, settings, logo. Новым разделам (радио/история/аудиокниги) можно переиспользовать `radio.png`, `podcast.png`, а для книг — взять `ic_colt_icon_books_*` из APK-ресурсов.
- **CDN изображений:** плагин формирует URL в `API.pm:getImageUrl` — подставляет `{size}→500x500` и добавляет `?width=500&height=500`. Это работает; при желании ретины можно поднять до 600–900.
- **Пути в LMS чувствительны к регистру** — используется `plugins/Zvuk/...` (см. `project_status.md`).

Отдельный ресёрч UI-ресурсов APK для плагина низкоприоритетен: LMS отдаёт своё меню, а обложки приходят по CDN из API.

---

## 7a. Лента (главный экран) и жанры

### Как организована лента

Лента **сервер-управляемая** — клиент её не хардкодит, а получает состав секций с сервера. Два механизма:

1. **GraphQL `dynamicBlock`** (современный) — `contentType` + `itemType` + `pages`. ✅ VERIFIED:
   - `DynamicBlockContentType` (`.../graphql/type/DynamicBlockContentType.java`): **`Music`, `NoMusic`, `Kids`** — три верхнеуровневых «вкладки» ленты.
   - `DynamicBlockItemType` (`.../graphql/type/DynamicBlockItemType.java`): **`Artist, Release, Playlist, Podcast, Episode, Book, FavoriteTracks, PersonalWave`** — что может быть карточкой в ленте.
   - В плагине это уже реализовано как `getMusicRecommendations` (`API/Async.pm:1056`), но не выведено в меню.
2. **REST `/api/tiny/grid?name=<name>`** (легаси) — имя грида приходит из навигации (`…getName()`, см. `WebViewNativeBridgeFragment.java:139`). Встреченные имена секций: **`main`, `showcase`, `collection`, `discovery`**. Грид возвращает готовый layout секций.

**Вывод:** полноценную «домашнюю ленту» в плагине можно построить через `dynamicBlock` (contentType=`Music`, перебор `pages`) — без хардкода структуры. Сейчас плагин строит собственное статическое OPML-меню, что для LMS нормально; лента — опциональное улучшение (раздел 6.5).

### Жанры: хардкод или API?

**И то, и другое — но для разных целей:**

- **Быстрый выбор жанра/настроения для Волны — ХАРДКОД** (в самом приложении!). `defpackage/hk0.java` содержит зашитый список:
  - Жанры (все `LVL1`): `pop, hip_hop, rock, electronic, chanson, dance_electronic, metal, dance`.
  - ⚠️ Это **отличается** от хардкода в плагине (`WaveSettings.pm:GENRES`): `easy_listening_ambient, electronic, classical, folk_world_country, hip_hop, indie, instrumental_acoustic, metal, pop, rock, soundtrack`. Оба списка — кураторские подмножества, не полный каталог. Уровень жанра задаётся enum `Level` = `LVL1/LVL2/LVL3` (`.../graphql/type/Level.java`).
  - Настроения (mood) в приложении — тоже хардкод, с точным маппингом в строку `energy:X,fun:Y`:
    | Настроение | Строка mood |
    |---|---|
    | Бодрое (energy) | `energy:1.0,fun:0.5` |
    | Бодрое + грустное | `energy:1.0,fun:0.0` |
    | Бодрое + весёлое | `energy:1.0,fun:1.0` |
    | Весёлое | `energy:0.5,fun:1.0` |
    | Спокойное (calm) | `energy:0.0,fun:0.5` |
    | Спокойное + весёлое | `energy:0.0,fun:1.0` |
    | Спокойное + грустное | `energy:0.0,fun:0.0` |
    | Грустное (sad) | `energy:0.5,fun:0.0` |
    | «Любимое» (favorite wave) | `popular:0.0` |

    Плагин сейчас даёт energy/fun ползунками и собирает `energy:%g,fun:%g` (`API/Async.pm:647`) — совместимо; можно добавить эти 8 пресетов как быстрый выбор.

- **Полный каталог жанров — через API.** GraphQL `getOnboardingGenres` ✅ VERIFIED (`defpackage/k1c.java`, `h1c.java`):
  ```graphql
  query getOnboardingGenres {
    recommenderOnboarding { getOnboardingGenres { genre_id image_url title } }
  }
  ```
  Возвращает `{ genre_id, image_url, title }` — это каталог для экрана онбординга «выбери жанры». Плюс каждый трек/релиз несёт инлайн `genres { id name shortName }` (уже в `zvuk_api.md`). Аудиокниги используют отдельную BISAC-таксономию (`.../graphql/type/GenreBisacNameType.java`).

**Рекомендация:** список жанров для настроек Волны можно перестать хардкодить и подтягивать через `getOnboardingGenres` (с кэшем 24ч). Но учтите: `getOnboardingGenres` возвращает `genre_id`, тогда как Волна принимает жанр по строковому `name` + `Level` — соответствие `genre_id → name` надо подтвердить перехватом перед заменой хардкода.

---

## 7b. Разделы главного экрана приложения → покрытие для реализации

Реальный главный экран приложения (сверху вниз): (1) волна «Ваша сила звука» в выбранном стиле, (2) переключатель **Для вас / Жанры / Ситуации**, (3) **Недавнее**, (4) **Новинки**, (5) **Сейчас в тренде**, (6) **Рекомендуем прослушать**, (7) **Нейросеть подберёт (GigaMix)**, (8) **бесконечная лента**.

**Архитектура фида (важно понять перед реализацией):** состав и порядок секций главного экрана задаёт сервер через `/api/tiny/grid?name=main` (или `showcase`). Грид отдаёт блоки и **ID контента**, а детали каждой секции клиент дозапрашивает типизированными GraphQL-операциями (`getMainTrendPlaylists($ids)` и т.п.). Часть операций самодостаточна (не требует ID из грида) — их в плагине можно вызвать напрямую, не воспроизводя грид.

| # | Раздел | Операция | Есть в отчёте? | Самодостаточна (без грида)? | Готовность к реализации |
|---|---|---|---|---|---|
| 1 | Волна в стиле | `personalWaveContent` + опция genre | ✅ (раздел 6/7a) | ✅ | **Готово** (плагин уже умеет) |
| 2 | Для вас / Жанры / Ситуации | `getPersonalWaveOptions` (см. ниже) | ⚠️ добавлено сейчас | ✅ | Нужен 1 capture для маппинга опций→варианты волны |
| 3 | Недавнее (история) | `listeningRecentV1` | ✅ (6.2) | ✅ | **Готово к коду** |
| 4 | Новинки | `getRecommendedReleases(recType: NEW)` | ⚠️ добавлено сейчас | ✅ | **Готово к коду** |
| 5 | Сейчас в тренде | `getMainTrendPlaylists($ids)` | ⚠️ добавлено сейчас | ❌ (нужны ID из грида) | Нужен capture грида `name=main` |
| 6 | Рекомендуем прослушать | `dynamicBlock` (реализовано как `getMusicRecommendations`) | ✅ (6.5) | ✅ | **Готово к коду** |
| 7 | GigaMix (нейросеть) | `getGenerativePlaylist` | ✅ | ✅ | **Готово** (реализовано) |
| 8 | Бесконечная лента | `dynamicBlock(contentType: Music, pages: [...])` | ✅ (7a) | ✅ | **Готово к коду** (пагинация по `pages`) |

**Короткий ответ:** для 6 из 8 разделов данных в отчёте достаточно, чтобы писать код. Два раздела требуют по одному живому перехвату (Charles/mitmproxy):
- **№5 «Сейчас в тренде»** и «Специально для вас» — их плейлист-ID приходят из `/api/tiny/grid?name=main`; надо один раз посмотреть структуру ответа грида (либо заменить на `dynamicBlock`, который отдаёт items напрямую и ID не требует).
- **№2 «Жанры/Ситуации»** — список опций отдаёт `getPersonalWaveOptions`, но как `key/value` из ответа кладутся в `PersonalWaveOptions` запроса волны — надо подтвердить одним перехватом.

### Новые операции (✅ VERIFIED в APK), нужные для главного экрана

**«Новинки» — `getRecommendedReleases`** (самодостаточна, `recType: NEW`; enum `RecReleaseTypeEnum` = `NEW`):
```graphql
query getRecommendedReleases($first: Int!, $skip: Int!, $recType: RecReleaseTypeEnum!) {
  recommendation {
    releases(first: $first, skip: $skip, recType: $recType) {
      id title date type explicit availability artistTemplate
      artists { id title } image { src palette paletteBottom }
      label { id } tracks { id } collectionItemData { likesCount } childParam mark
    }
  }
}
# variables: { "first": 30, "skip": 0, "recType": "NEW" }
```

**«Жанры / Ситуации» пикер волны — `getPersonalWaveOptions`** (динамический каталог опций вместо хардкода):
```graphql
query GetPersonalWaveOptionsType {
  getPersonalWaveOptions {
    id type_title
    option_info { id title options { key value type } }
  }
}
```
`type_title` = название группы («Жанры», «Ситуации», …); `option_info.options[].{key,value,type}` = конкретные варианты. Группировку по вкладкам «Для вас/Жанры/Ситуации» задаёт `WaveCategory` (модель `MainPersonalWaveCategoryShortcutListModel`).

**«Сейчас в тренде» — `getMainTrendPlaylists`** (требует ID из грида `name=main`):
```graphql
query getMainTrendPlaylists($ids: [ID!]!) {
  playlists(ids: $ids) { id title description image { src } tracks { id } ranked ... }
}
```
Аналогично «Специально для вас» — `getMainSpecialForYouPlaylists($ids)`.

**Бесконечная лента — `dynamicBlock`** (как шлёт приложение, ✅ VERIFIED):
```graphql
query dynamicBlock($contentType: DynamicBlockContentType!, $itemType: [DynamicBlockItemType!], $pages: [Int!]!) {
  dynamicBlock(contentType: $contentType, itemType: $itemType, pages: $pages) {
    title totalPages
    pages { page items { __typename positionName
      ... on Release { ...ReleaseGqlFragment }
      ... on Playlist { ...PlaylistGqlFragment }
      ... on Artist { ...ArtistGqlFragment }
      ... on PersonalWave { ...PersonalWaveGqlFragment }
      ... on FavoriteTracks { ...DiscoveryFavoriteTracksGqlFragment }
    } }
  }
}
# variables: { "contentType": "Music", "itemType": ["Release","Playlist","Artist"], "pages": [1] }
```
Для бесконечной прокрутки увеличивать `pages` до `totalPages`.

**Прочие найденные операции волн (на будущее):** `waveContent($input: WaveContentInput!)` (новый формат воспроизведения волны), `CollectionWaveContent`, `getKidsWaveContent`, `getRecommendedArtistsWithWave`, `availableWaves` (список именованных волн с `tagAudience`).

---

## 8. Методология проверки (чтобы повторить/расширить)

Корень APK: `/home/chernysh/Projects/android_zvuk/Zvuk/app/src/main/java`

```bash
R=/home/chernysh/Projects/android_zvuk/Zvuk/app/src/main/java

# Существует ли GraphQL-операция в APK (а не только в браузере)?
grep -rIl '"personalWaveContent"\|recommenderRadio(' "$R"

# Полное определение операции (одна строка-литерал query ...):
grep -rIhn 'query recommenderRadio' "$R"

# Заголовки/WAF-интерсепторы:
#   defpackage/blv.java  — основной набор заголовков
#   defpackage/clv.java  — X-Session-UID (WAF)
#   defpackage/qp6.java:89 — порядок конкатенации входа хеша

# Магические константы:
grep -rIn '4.109.0rs\|510900179' "$R/com"

# Enum качества/типов стрима:
#   com/zvuk/playerstreams/models/StreamQuality.java
#   com/zvuk/playerstreams/models/StreamType.java
```

Общая цепочка для новой операции: найти `*Interactor`/`*DataSource` по имени фичи → внутри `defpackage/*.java` найти строку `return "query <opName> ..."` → скопировать целиком (там уже развёрнуты фрагменты) → подтвердить перехватом Charles/mitmproxy на веб-эндпоинте `api/v1/graphql`.

---

## 9. Ключевые файлы-доказательства (APK)

| Тема | Файл |
|---|---|
| WAF `X-Session-UID` | `defpackage/clv.java` |
| Конкатенация входа хеша (`a+b+c`) | `defpackage/qp6.java:89` |
| Полный набор заголовков | `defpackage/blv.java` |
| Провайдер заголовков (UA, app-instance) | `com/zvooq/openplay/network/AdditionalHeadersDataProvider.java` |
| Enum качества | `com/zvuk/playerstreams/models/StreamQuality.java` |
| Типы стрима | `com/zvuk/playerstreams/models/StreamType.java` |
| `recommenderRadio` query | `defpackage/` (grep `query recommenderRadio`) |

---

## 10. Рекомендованный порядок работ

1. **`recommenderRadio`** (радио по сущности) — максимальный эффект, минимум кода, переиспользует существующую механику волны. *(6.1)*
2. **`listeningRecentV1`** (история) — простой read-only раздел. *(6.2)*
3. **Вывести `getMusicRecommendations` в меню** — код уже есть. *(6.5)*
4. **Лайки/коллекция-мутации** — интерактивность. *(6.4)*
5. **Аудиокниги** — крупный, но полностью документированный блок. *(6.3)*
6. **Synthesis-плейлисты** — только после перехвата реального запроса. *(6.6)*

---

## 11. Пошаговый план реализации разделов главного экрана

Цель — довести плагин до состава главного экрана приложения. Уже реализовано: Волна, «Рекомендуем» (`handleRecommendations`), GigaMix. Ниже — недостающее, в порядке возрастания стоимости. Все сигнатуры согласованы с конвенциями плагина: хендлер `sub handleX { my ($client, $cb, $args, $params) = @_; ... $cb->({ items => \@items }); }`, passthrough через `passthrough => [{ ... }]`, render-хелперы возвращают item-хэш, треки — через `_renderTrack`.

### Задача 1 — «Новинки» (`getRecommendedReleases`, самодостаточна) — ~1ч

**`API/Async.pm`:**
```perl
# Новинки: recommendation.releases(recType: NEW). Пагинация через $skip.
sub getNewReleases {
    my ($self, $cb, $args) = @_;
    $args ||= {};
    my $first = int($args->{first} || 30);
    my $skip  = int($args->{skip}  || 0);

    my $gql = q{
        query getRecommendedReleases($first: Int!, $skip: Int!, $recType: RecReleaseTypeEnum!) {
            recommendation {
                releases(first: $first, skip: $skip, recType: $recType) {
                    id title date type explicit availability artistTemplate
                    artists { id title } image { src } tracks { id }
                }
            }
        }
    };

    $self->_graphql(sub {
        my $data = shift;
        if (!$data || $data->{error}) { $cb->([]); return; }
        $cb->(($data->{recommendation} || {})->{releases} || []);
    }, 'getRecommendedReleases', $gql,
       { first => $first, skip => $skip, recType => 'NEW' },
       { ttl => Plugins::Zvuk::API::DYNAMIC_TTL });
}
```
**`Plugin.pm`:**
```perl
sub handleNewReleases {
    my ($client, $cb, $args, $params) = @_;
    my $api  = _get_api_client($client);
    my $skip = ($params && $params->{skip}) || 0;

    $api->getNewReleases(sub {
        my $releases = shift || [];
        my @rendered = map { _renderAlbum($_) } @$releases;
        if (@$releases >= 30) {   # вероятно есть ещё страница
            push @rendered, {
                name => cstring($client, 'NEXT_PAGE'), type => 'link',
                url  => \&handleNewReleases, passthrough => [{ skip => $skip + 30 }],
            };
        }
        $cb->({ items => \@rendered });
    }, { first => 30, skip => $skip });
}
```
**Меню** (`_buildRootMenu`): `{ name => cstring($client,'PLUGIN_ZVUK_NEW_RELEASES'), type=>'link', url=>\&handleNewReleases, image=>'plugins/zvuk/html/images/albums.png' }`.
**strings.txt:** `PLUGIN_ZVUK_NEW_RELEASES` (RU «Новинки», EN «New Releases»).

### Задача 2 — «Недавнее» / история (`listeningRecentV1`, самодостаточна) — ~1.5ч

**`API/Async.pm`:**
```perl
# История прослушивания. Union-тип: проверять __typename у mediaContent.
sub getRecentlyListened {
    my ($self, $cb, $args) = @_;
    $args ||= {};
    my $limit  = int($args->{limit}  || 50);
    my $offset = int($args->{offset} || 0);

    my $gql = q{
        query listeningRecentV1($itemType: [RecentItemType!], $limit: Int!, $offset: Int!) {
            listeningRecentV1(itemType: $itemType, limit: $limit, offset: $offset) {
                lastListeningDttm
                mediaContent {
                    __typename
                    ... on Artist   { id title image { src } }
                    ... on Release  { id title date type artistTemplate image { src } }
                    ... on Playlist { id title image { src } }
                    ... on Book     { id title image { src } }
                    ... on Podcast  { id title image { src } }
                    ... on Episode  { id title image { src } podcast { id title } }
                }
            }
        }
    };

    $self->_graphql(sub {
        my $data = shift;
        if (!$data || $data->{error}) { $cb->([]); return; }
        $cb->($data->{listeningRecentV1} || []);
    }, 'listeningRecentV1', $gql, { limit => $limit, offset => $offset },
       { ttl => Plugins::Zvuk::API::USER_CONTENT_TTL });
}
```
**`Plugin.pm`** (диспетчер рендера по `__typename` — переиспользует существующие хелперы):
```perl
sub handleRecentlyListened {
    my ($client, $cb, $args, $params) = @_;
    my $api    = _get_api_client($client);
    my $offset = ($params && $params->{offset}) || 0;

    $api->getRecentlyListened(sub {
        my $rows = shift || [];
        my @rendered;
        for my $row (@$rows) {
            my $m = $row->{mediaContent} or next;
            push @rendered, _renderFeedItem($m);   # см. Задачу 4
        }
        if (@$rows >= 50) {
            push @rendered, {
                name => cstring($client,'NEXT_PAGE'), type=>'link',
                url  => \&handleRecentlyListened, passthrough => [{ offset => $offset + 50 }],
            };
        }
        $cb->({ items => \@rendered });
    }, { limit => 50, offset => $offset });
}
```
**Меню:** `{ name => cstring($client,'PLUGIN_ZVUK_RECENTLY_LISTENED'), type=>'link', url=>\&handleRecentlyListened, image=>'plugins/zvuk/html/images/radio.png' }`.
**strings.txt:** `PLUGIN_ZVUK_RECENTLY_LISTENED` («Недавнее» / «Recently played»).

### Задача 3 — «Бесконечная лента» (`dynamicBlock`, самодостаточна) — ~1ч

`getMusicRecommendations` уже реализован и принимает `page`. Нужен только плоский хендлер с пагинацией по `totalPages`.

**`Plugin.pm`:**
```perl
sub handleInfiniteFeed {
    my ($client, $cb, $args, $params) = @_;
    my $api  = _get_api_client($client);
    my $page = ($params && $params->{page}) || 1;

    $api->getMusicRecommendations(sub {
        my $result = shift || {};
        if ($result->{error}) {
            $cb->({ items => [{ name => cstring($client,'PLUGIN_ZVUK_RECOMMENDATIONS_ERROR'), type=>'text' }] });
            return;
        }
        my @rendered = map { _renderFeedItem($_) } @{ $result->{allItems} || [] };
        my $totalPages = $result->{totalPages} || 1;
        if ($page < $totalPages) {
            push @rendered, {
                name => cstring($client,'NEXT_PAGE'), type=>'link',
                url  => \&handleInfiniteFeed, passthrough => [{ page => $page + 1 }],
            };
        }
        $cb->({ items => \@rendered });
    }, { contentType => 'Music', itemTypes => ['Release','Playlist','Artist'], page => $page });
}
```
**Меню:** `{ name => cstring($client,'PLUGIN_ZVUK_FEED'), type=>'link', url=>\&handleInfiniteFeed }`.
**strings.txt:** `PLUGIN_ZVUK_FEED` («Лента» / «Feed»).

### Задача 4 — общий диспетчер рендера ленты `_renderFeedItem` (нужен для задач 2 и 3) — ~0.5ч

**`Plugin.pm`:**
```perl
# Рендер элемента ленты/истории по __typename → существующие хелперы.
sub _renderFeedItem {
    my ($item) = @_;
    my $t = $item->{__typename} || '';
    return _renderArtist($item)   if $t eq 'Artist';
    return _renderAlbum($item)    if $t eq 'Release';
    return _renderPlaylist($item) if $t eq 'Playlist';
    return _renderPodcast($item)  if $t eq 'Podcast';
    return _renderEpisode($item)  if $t eq 'Episode';
    return _renderTrack($item, 1) if $t eq 'Track';
    # Book — заглушка до реализации аудиокниг (раздел 6.3)
    return { name => $item->{title} // '', type => 'text',
             image => Plugins::Zvuk::API->getImageUrl($item) };
}
```

### Задача 5 — «Сейчас в тренде» — ⚠️ требует 1 перехват — ~2ч

`getMainTrendPlaylists($ids)` принимает ID плейлистов, которые приходят из `/api/tiny/grid?name=main`. Два пути:
- **Без перехвата (рекомендую):** не делать отдельный раздел, а показывать плейлисты из «Бесконечной ленты»/`dynamicBlock` (`itemType: ['Playlist']`). Функционально закрывает потребность.
- **Точно как в приложении:** сначала `GET /api/tiny/grid?name=main` (добавить REST-хелпер в `API/Async.pm` по образцу `getProfile`), распарсить ID блока «тренды», затем:
```perl
sub getTrendPlaylists {
    my ($self, $cb, $ids) = @_;   # $ids — из грида
    my $gql = q{
        query getMainTrendPlaylists($ids: [ID!]!) {
            playlists(ids: $ids) {
                id title description image { src } ranked tracks { id }
            }
        }
    };
    $self->_graphql(sub {
        my $data = shift;
        $cb->($data && !$data->{error} ? ($data->{playlists} || []) : []);
    }, 'getMainTrendPlaylists', $gql, { ids => $ids });
}
```
**Блокер:** структура ответа грида `name=main` по APK надёжно не восстановлена — нужен один перехват Charles/mitmproxy. До него делать по варианту «без перехвата».

### Задача 6 — «Жанры / Ситуации» динамически (`getPersonalWaveOptions`) — ⚠️ требует 1 перехват — ~2–3ч

Заменяет хардкод `WaveSettings.pm:GENRES` серверным каталогом.

**`API/Async.pm`:**
```perl
sub getPersonalWaveOptions {
    my ($self, $cb) = @_;
    my $gql = q{
        query GetPersonalWaveOptionsType {
            getPersonalWaveOptions {
                id type_title
                option_info { id title options { key value type } }
            }
        }
    };
    $self->_graphql(sub {
        my $data = shift;
        $cb->($data && !$data->{error} ? ($data->{getPersonalWaveOptions} || []) : []);
    }, 'GetPersonalWaveOptionsType', $gql, {}, { ttl => Plugins::Zvuk::API::DEFAULT_TTL });
}
```
**Блокер:** как `option_info.options[].{key,value}` подставляются в переменную `$options` запроса `personalWaveContent` (в какие поля `PersonalWaveOptions`) — подтвердить одним перехватом сборки волны с выбранным жанром/ситуацией. До этого оставить текущий рабочий подход (energy/fun + genre строкой), но синхронизировать хардкод-список с реальным: добавить `chanson`, `dance`, `dance_electronic` (см. раздел 7b).

### Итоговый порядок и меню

Порядок задач: **1 (Новинки) → 4 (`_renderFeedItem`) → 2 (Недавнее) → 3 (Лента) → 5 (Тренд, после перехвата) → 6 (Жанры/Ситуации, после перехвата)**. Задачи 1–4 не требуют перехватов и дают 3 новых раздела за ~4 часа.

Итоговый `_buildRootMenu` (порядок как на главном экране приложения): Поиск · Волна · **Недавнее** · **Новинки** · Рекомендуем · GigaMix · **Лента** · Моя музыка. Новые пункты вставляются в существующий массив `@items` (`Plugin.pm:149-200`) как обычные `{ name, type=>'link', url=>\&handleX, image }`.

**Нужные ключи strings.txt:** `PLUGIN_ZVUK_NEW_RELEASES`, `PLUGIN_ZVUK_RECENTLY_LISTENED`, `PLUGIN_ZVUK_FEED` (+ при желании `PLUGIN_ZVUK_TRENDING`). Ошибки/пустые состояния переиспользуют существующие `PLUGIN_ZVUK_RECOMMENDATIONS_ERROR/EMPTY`.
</content>
</invoke>
