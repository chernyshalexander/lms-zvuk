# Руководство по доработкам lms-zvuk (октябрь 2026)

Полный рабочий документ для senior Perl-разработчика. Составлен на основе:

* **Код плагина**: ветка `experiment`, v0.4.0 (все ссылки `файл:строка` — из текущего кода).
* **Web-исследование API**: `/mnt/hgfs/VM_share/Research/zvuk-api-docs/` (19.09.2026, живые пробы + 34 фикстуры в `evidence/json/`).
* **APK-исследование**: `/mnt/hgfs/VM_share/Research/zvuk-api-docs-v2/` (23.09.2026, Звук 4.116.0rs, jadx; 196 GraphQL-операций с телами в `evidence/gql/`, интерсепторы в `evidence/apk-notes/`).
* **Atlas-исследование**: `/mnt/hgfs/VM_share/Research/atlas-research/` (25.09.2026, живой сервис) + `/mnt/hgfs/VM_share/Research/zvuk_apk_atlas_research/` (06.10.2026, Звук 4.117.0rs, apktool; кросс-чек в `reports/atlas_cross_check_vs_atlas_research.md`).

Дополняет (не заменяет) `future_tasks.md`, `COMPARISON_REPORT.md`, `RESEARCH_REPORT_2026-07.md`.

---

## 1. Итоговая оценка (TL;DR)

Плагин архитектурно здоров: конвейер `cache → throttle → retry` в `API/Async.pm`, корректная LMS-асинхронщина, регрессионные тесты с моками, недавний рефакторинг P3.4. Исследования дают три крупных блока **новых знаний, отсутствующих в коде и текущих docs/**:

1. **Обновление токена существует** — `POST /api/tiny/refresh` (найдено в APK; интерсептор `f62` автоматически делает refresh+retry при 401). Сейчас плагин не обрабатывает протухание токена вообще, а токен живёт **7 дней** и ротируется при каждом веб-логине в любом браузере.
2. **Atlas** (`atlas.zvuk.com`, запущен 22.09.2026) — персональная карта вкуса с чистым REST API. Токен плагина работает как `Cookie: auth=<token>`. Интеграция ~200–300 строк Perl.
3. **196 GraphQL-операций из APK** с готовыми телами запросов — радиостанции, recommenderRadio, похожие треки, тексты (Musixmatch), аудиокниги, cursor-пагинация коллекции, умный поиск, `getMeta`-батч.

Плюс **8 проверенных багов/долгов в текущем коде** (раздел 2).

---

## 2. Обязательные исправления (проверено по коду)

| # | Проблема | Где | Исправление |
|---|----------|-----|-------------|
| 1 | `return $cached` внутри блока `map` — при первом же попадании в кэш функция прекращает обработку всего батча, остальные треки не кэшируются | `API.pm:128-131` | Заменить на ветвление `$cached ? $cached : do {...}` или переписать на `for` |
| 2 | `require('Plugins::Zvuk::API::Async')` — Perl-вызов в браузерном JS. Бросает `ReferenceError` до `fetch`; кнопка анонимного входа в классических настройках сломана | `basic.html:350` | Удалить строку — серверный роут `/plugins/zvuk/getAnonymousToken` уже зарегистрирован (`Plugin.pm:64-107`) |
| 3 | Адаптивная обратная связь Волны инертна: `zvuk_wave_last_track` читается (`ProtocolHandler.pm:334`), но **нигде не записывается** — `contentInput` (trackId/playDuration/isSkipped) всегда undef | `ProtocolHandler.pm:329-348` | Записывать `{id, started, duration}` в `getNextTrack` при проигрывании wave-треков; чистить по `stop` (обработчики событий уже есть в `Plugin.pm:117-138`) |
| 4 | OAuth-сохранённые аккаунты получают фейковый `userId = substr(token,0,16)` и имя `Account <hex>` навсегда — реальный профиль не резолвится | `WebHandlers.pm:283-294` | После сохранения асинхронно вызвать `getProfile` и переложить аккаунт под настоящий числовой id (образец валидации — `Settings.pm:45-102`) |
| 5 | Настройка «GigaMix autoplay» — no-op: сохраняется, но нигде не читается | `Settings.pm:26`, `Plugin.pm:48` | Учитывать преф в блоке авто-продления `ProtocolHandler.pm:79-90` (или убрать настройку) |
| 6 | Мёртвый код: `WaveWizardUI.pm` (343 строки, "NOT CURRENTLY USED"), `_renderArtistItem/_renderReleaseItem/_renderPlaylistItem` (`Plugin.pm:813-838`), `handlePersonalWave`, `handleSynthesisPlaylists` (недостижим), `handleGetWaveSettingsWeb` (`WebHandlers.pm:207-238`) — реализован, но **не зарегистрирован** как роут; `CAN_FLAC_SEEK` (`ProtocolHandler.pm:19`) | разные | Удалить или зарегистрировать. **Не удалять** `likeTrack/unlikeTrack/likeArtist/...` из `API/Async.pm:1417-1479` — они нужны для п. 5.1 |
| 7 | DEBUG-логи на уровне WARN в проде | `WaveUI.pm:286-294, 324-332`, `API/Async.pm:146-148` | Перевести на `$log->debug` / обернуть в `is_debug` |
| 8 | Гигиена секретов: живой токен захардкожен в `test/test_editorial_real.pl|.sh`, лежит в `test/token.txt` (локально, не в git) | `test/` | Вынести в переменную окружения; в репозиторий — только шаблоны |

---

## 3. Приоритет 1: жизненный цикл токена (`/api/tiny/refresh`)

### Новые факты (atlas-research + APK)

* `token` из `GET /api/tiny/profile` **байт-в-байт равен cookie `auth`** веб-сессии. Подтверждено трижды: живое сравнение (`capture/profile_token_vs_auth_cookie.json`, `IDENTICAL: true`), smali `BannerWebViewViewModel` (`setCookie(".zvuk.com", "auth=" + token)`), веб-исследование.
* Измеренные времена жизни: `auth` cookie и `access_token` — **7 дней**; `AT` JWT — ровно 7 дней; `RT`/`refresh_token` — 90 дней; `spid`/`spsc` — ~13 месяцев.
* **Каждый refresh/логин ротирует `auth`/`AT`** на новое значение; токен, сохранённый в префсах плагина, устаревает ≤7 дней либо раньше — от любого веб-логина в любом браузере.
* APK при 401 автоматически: `POST https://zvuk.com/api/tiny/refresh` (заголовки `X-Auth-Token: <текущий>`, `X-C-P: Q`) → новая пара кредов → повтор запроса. Ответ той же формы, что `/api/tiny/profile`.
* **Ловушка:** `id.zvuk.com/api/v2/token/refresh` из веб-бандла — *другой* эндпоинт; без живого браузерного контекста минтует **анонимную** сессию (Atlas отвечает 401, zvuk.com не распознаёт аккаунт — `capture/auth_chain_final.json`). Не использовать.

### Реализация (алгоритм из zvuk-api-docs-v2/07-catalogs-algorithms.md §6)

1. В `_graphql` (`API/Async.pm:102-302`) и REST-хелперах: при 401 → один вызов `refresh` → обновить `accounts->{userId}->{token}` в префсах → **один** повтор исходного запроса → при повторном 401 пометить аккаунт `stale`.
2. Stale-аккаунт: в меню — локализованное «Требуется повторный вход Звука»; при попытке воспроизведения — понятная ошибка вместо сырого «GraphQL error».
3. `Retry.pm` уже корректно не ретраит 401 — refresh вызывать **выше** уровня Retry (в `_graphql`), чтобы не зациклиться.
4. Дешёвая проверка свежести: `GET /api/tiny/profile` с `X-Auth-Token` (200 = жив; 401/418 = ротирован) — при старте LMS и перед входом в Atlas.

---

## 4. Приоритет 2: интеграция Atlas («Атлас вашего вкуса»)

### Что это

Сервис `atlas.zvuk.com` — персональная 2D-карта вкуса («Атлас вашего вкуса»): 79 «островов» = уникальные пары (настроение × жанр) из 36 настроений и 53 жанров, ~283 связи. Перегенерируется ~раз в час (`generated_at`). Жанровой иерархии **нет** — `trees` это компоненты связности графа (Union-Find: [77, 2]).

### API (REST, база `https://atlas.zvuk.com`, `cache-control: no-store`)

| Метод | Назначение |
|---|---|
| `GET /api/v1/map` | Полная карта: `islands[]{id(uuid), tree_id, title, mood, genre, valence(-1..1), energy(-1..1), intensity, track_count, share(0..1), covers[4-5 TrackBrief], connections{left,right}}`; `TrackBrief = {track_id, title, artist, artist_id, artists[], cover_url}` |
| `GET /api/v1/map/islands/{id}` | До **50** треков острова |
| `GET /api/v1/map/islands/{id}/wave?limit=20` | Очередь воспроизведения; трек с полем `origin: "own" \| "discovery"` и флагом `saved`. Механизм пагинации не выяснен |
| `PUT /api/v1/map/islands/{id}/wave` | Регистрация запуска потока (пустое тело, `content-type: application/json`); ответ `{island_alive, core_size, adopted_size, ...}` |
| `GET /api/v1/track/{id}/stream` | Подписанный CDN URL (SigV4, 24 ч) — **не нужен**, см. ниже |

Несуществующие пути (проверено, 404): `/api/v1/genres`, `/api/v1/taste-profile`, `/api/v1/profile`, `/api/v1/me`, `/api/v1/tree(s)`, `/api/v1/map/tree|taste-tree|genres`.

### Авторизация — только cookie

* Минимальный рабочий креденшл: `Cookie: auth=<токен плагина>` → 200 на `/api/v1/map`.
* Заголовок `X-Auth-Token` и ещё 13 схем (query-параметры, Bearer, spid-подстановки и т.д.) отклоняются — 401.
* APK ставит тройку `auth=<token>`, `sauth=<token>`, `in_webkit=true` на домен `.zvuk.com`; достаточно одного `auth`. Роль `in_webkit` не выяснена.
* 401 → «нужен свежий веб-логин», прятать меню, **не ретраить**.
* 404/5xx → спрятать пункт меню + запись в лог (деградация без поломки).

### Проект интеграции (report_atlas_lms_recommendation.md, сверено с кодом)

* `API/Atlas.pm` — тонкий cookie-клиент: `_http_get` с браузерным UA/Referer, троттлинг через существующий `Throttle.pm`, кэш `zvuk_atlas_map` TTL ~1 ч с ключом по `generated_at` (тихо обновлять при дрейфе `track_count`/`share`).
* Меню: двухуровневое **Жанр (53) → Острова** — основной режим; плоский список 79 островов по `track_count desc` — альтернативный; пункт «Мне повезёт» (случайный остров). Пункт корня — после «Моя Волна» в `_buildRootMenu` (`Plugin.pm:178-262`).
* Остров = виртуальный wave-плейлист: рендер по образцу плейлистов (обложка `covers[0].cover_url`, сабтитул «N треков · M%», title «{Mood} {Genre}»).
* Воспроизведение — **существующим путём** `zvuk://<track_id>` через `getNextTrack`/`getStream`: сохраняется выбор качества flac/high/mid. Atlas-эндпоинт стрима не нужен.
* `PUT wave` — опционально (GET уже возвращает очередь).
* **Не** сливать 13 жанров `WaveSettings` с 53 жанрами Atlas — разные словари, не сопоставимы.
* Fallback при недоступности Atlas: жанровая волна через существующий `personalWaveContent` + `contentInput.genres`.
* Оценка: ~200–300 строк Perl (`API/Atlas.pm` + `AtlasUI.pm` по образцу `WaveUI.pm` + пункт меню + строки локализации + настройка «плоско/по жанрам» и лимит волны 10–40).
* Фикстуры для тестов парсера: `atlas-research/capture/api_v1_map_full.json` (137 КБ, реальный ответ), `api_v1_map_islands_coldrock.json`.

---

## 5. Приоритет 3: расширение функций из GraphQL-каталога APK

Каталог из 196 операций с точными телами: `/mnt/hgfs/VM_share/Research/zvuk-api-docs-v2/evidence/gql/_index.tsv` + `query_*.graphql` / `mutation_*.graphql`. Живые ответы веб-API: `zvuk-api-docs/evidence/json/` (34 файла). Отбор по ценности для LMS:

### 5.1. Быстрые победы (0.5–2 дня каждая)

* **Лайки треков/исполнителей/плейлистов** — методы `likeTrack/unlikeTrack/...` уже написаны (`API/Async.pm:1417-1479`), подключить к контекстным меню по образцу альбомного меню `Browse/InfoMenu.pm` (там же `hidden_collection` — «скрыть из Волны»).
* **Тексты песен** — `GET /api/tiny/musixmatch/lyrics?track_id=&translation=false` (провайдер Musixmatch; веб-вариант `/api/tiny/lyrics?track_id=`); показ в SongInfo (COMPARISON_REPORT P2.1).
* **Похожие треки** — `getTrackRelatedTracks` / `getRelatedTracks` (`relatedTracksArray(track_ids, limit)`) → интеграция с DontStopTheMusic (future_tasks #4).
* **Радиостанции** — `getRadioStations(broadcastType, first, skip, randomOrder)`; сущность в веб-клиенте отсутствует, только в APK. Плюс `getRadioMetaData`/`getRadioStreamMetaData` для метаданных эфира.
* **История** — `listeningRecentV1(itemType[], limit, offset)` («Недавнее»).

### 5.2. Средние задачи (2–5 дней)

* **recommenderRadio** — по `RESEARCH_REPORT_2026-07.md` это «highest-ROI» следующая фича; проверенное тело запроса уже в этом документе.
* **Новинки/тренды** — `getRecommendedReleases(recType: NEW)`, `getMainTrendPlaylists`. ⚠️ `dynamicBlockV2*` не проверять вслепую: обычный `dynamicBlock` стабильно даёт HTTP 400 с IP LMS-сервера (WAF; `test/test_music_recommendations.sh`). Предпочтительны `tiny/grid/content` (путь уже применён для «Подборок») и REST `grid?name=&market=`; карта имён гридов → веб-URL в `evidence/apk-notes/sharing_grid_screens.json` (~18 жанровых + new_2021_grid, zvuk-editorial_waves и др.).
* **Плейлисты CRUD** — `playlist { createV1(items, name, source) }`, `updateV1(id, isPublic, name, items)`, `addItemsV1(id, items)`, `removeItems`, `deletePlaylist`, `image { setCover(cover, owner) }` (P3.1; проверенные тела мутаций в COMPARISON_REPORT).
* **Аудиокниги** — `getBooks`, `getChapters`, `getBookAuthors`, рекапы, `setAudiobookChapterPlayStatePlayed` (future_tasks #5); главы стримятся через тот же `mediaContents` (typename `Chapter`).
* **Cursor-пагинация коллекции** — `paginatedCollection { tracks(pagination:{first, after}) { items{id collectionLastModified} page{hasNextPage, endCursor} } }`; сейчас коллекция берётся одним запросом с лимитом 500.
* **Пакетный `getMeta`** — 31 переменная с `@include` — вся «Моя музыка» одним вызовом вместо цепочек.
* **Умный поиск** — `blendedSearch` (BestMatch, `scoreVerticals`, курсорная пагинация) + `searchAutocomplete`; канонические фрагменты Track/Artist/Release/... в `evidence/gql/query_blendedSearch.graphql`.
* **Kids-профили** — заголовки `X-Zvuk-Profile-Id`/`X-Zvuk-Profile-Type`, `getKidsWaveContent`.

### 5.3. Стратегия совместимости имён

Веб и APK расходятся: `addItemToCollection` (веб; использует плагин) ↔ `addCollectionItem` (APK), `getSearch` ↔ `searchAutocomplete`, `search` ↔ `blendedSearch`, `getStream` ↔ `getTrack{Mid,High,Flac}Stream`, `userCollection` ↔ `paginatedCollection*`, `createPlayList`/`updataPlaylist` ↔ `createPlaylist(createV1)`/`updatePlaylist(updateV1)`. Правило: **существующие операции не переименовывать** (веб-набор проверен живьём), новые брать из APK-набора (свежее и полнее). Все GraphQL держать в одном модуле (уже так) + smoke-пробы V1–V9 из `zvuk-api-docs/07-replication.md` перед каждым релизом.

### 5.4. Телеметрия (опционально; future_tasks #6)

Без `POST /api/tiny/clickstream` (события `play_start`/`play_stop`/`tap_next`/`tuner_set`; Kafka-REST `topics/cs_v4_raw_events`, `Content-Type: application/vnd.kafka.json.v2+json`) рекомендации и история аккаунта не обновляются — воспроизведение это не ломает. Вместе с фиксом №3 (раздел 2) оживит адаптацию Волны. Обратная совместимость payload — в `RESEARCH_REPORT_2026-07.md`.

---

## 6. Стриминг

Текущая схема (прогрессивный HTTPS через `getStream`, `canDirectStream=0`, формат mp3/flc) корректна. Уточнения из исследований:

* Парсить **оба** поля: `stream.flac` (APK-схема) и `stream.flacdrm` (веб-наблюдение 19.09.2026) — плагин уже делает; при отсутствии поля — REST-фолбэк `GET /api/tiny/track/stream?id=&quality=flac|high|mid` (живой, только веб; COMPARISON_REPORT P3.3).
* `streamV2 { preview }` прямо в `getTracks`/`collectionTracks`/`blendedSearch` — быстрый путь превью без отдельного stream-запроса (для анонимного режима).
* Адаптивный HLS (`masterPlaylist{sq|hq}` через `encodeType:"fp"`, `streamV3{hls}`) — LMS нативно не играет, не внедрять; задокументировано на будущее.
* URL валиден 24 ч (`expire_delta: 86400`); текущая выборка «на каждый трек» в `getNextTrack` — правильная, не кэшировать.
* Анонимный токен: только `mid` + фрагменты-превью (~360 КБ, HEAD 200 audio/mpeg); честная деградация уже описана в `strings.txt`.
* Подпись CDN-URL — серверная, алгоритм не найден нигде (и не нужен).

---

## 7. Надёжность и эксплуатация

1. **HTTP 418 (анти-бот)** — главный подтверждённый риск: после ~40–50 программных запросов за 30 минут с одного IP **все** эндпоинты (даже `GET /api/tiny/profile`) отвечают 418; браузер с того же IP продолжает работать. Снимается через неустановленное окно (минуты–десятки минут). Сейчас `Retry.pm:136` ретраит только 429/502/503/504 — 418 падает как фатальная ошибка без диагностики. Сделать: выделенная обработка 418 → «штрафной режим» троттлинга (например, 1 запрос / 5 с на 15 мин) + локализованное сообщение пользователю.
2. **Троттлинг**: `Throttle.pm` допускает 5 req/s, исследования рекомендуют ≥1 с между вызовами. Сделать скорость настраиваемым префом (консервативный дефолт 1 rps; текущие 5 — опцией).
3. **REST-хелперы вне конвейера**: `_http_get` (`API/Async.pm:316-361`) и с ним `getProfile`, editorial grid, image proxy, anonymous token — без throttle/retry/кэша (долг P1.2). Обернуть.
4. **Единая классификация ошибок** (долг P2.4): auth (401) / rate (418/429) / WAF (HTML-ответ, 400 от dynamicBlock с IP датацентра) / schema drift (`GRAPHQL_VALIDATION_FAILED`, `Unknown argument`) → единый объект ошибки для меню и логов.
5. **Заголовки, обязательные всегда**: браузерный UA (иначе 307 на анти-бот-челлендж), `Origin/Referer: https://zvuk.com`, `X-Auth-Token`. Опционально: `X-C-P: J|O|Q` (приоритет запроса: каталог/стрим/авторизация — enum из APK), Apollo-заголовки (`X-APOLLO-OPERATION-NAME`) не требуются.
6. **Аварийный паспорт WAF**: алгоритм `X-Session-UID` (SHA-256 → верхний hex → raw-DEFLATE → XOR с appInstance → Base64) полностью описан в `RESEARCH_REPORT_2026-07.md` — не нужен на текущем web-desktop пути (`x-app-name: web-zvuk-service-desktop-app`), держать как запасной вариант.

---

## 8. Тесты

Существующий каркас (`t/slim_mocks.pl` + скриптовые тесты) расширить:

* парсер Atlas на фикстурах из `atlas-research/capture/`;
* флоу refresh-при-401 (мок: 401 → refresh → 200; проверить обновление префса и единственный повтор);
* штрафной режим 418 в Throttle/Retry;
* регрессия `cacheTrackMetadata` (батч с частично закэкешенными треками кэширует все);
* подключение like/unlike к контекстным меню (по образцу `t/test_album_context_menu.pl`);
* парсеры схем на фикстурах `zvuk-api-docs/evidence/json/`;
* недостающие области: Throttle edge-кейсы, WaveSettings дефолты, GigaMix-хендлеры, image proxy, OAuth-хендлеры.

---

## 9. Дорожная карта (ориентировочные трудозатраты)

| Фаза | Состав | Оценка |
|---|---|---|
| 0. Багфиксы и гигиена | все пункты раздела 2 | 1–2 дня |
| 1. Auth-цикл | `/api/tiny/refresh`, stale-аккаунты, UX повторного входа | 1–2 дня |
| 2. Atlas MVP | `API/Atlas.pm`, меню, воспроизведение, настройки, тесты | 3–5 дней |
| 3. Быстрые фичи | лайки, тексты, похожие треки+DSTM, радиостанции, недавнее | 3–6 дней суммарно |
| 4. Средние фичи | recommenderRadio, плейлист CRUD, аудиокниги, пагинация коллекции, новинки через grid, getMeta, blendedSearch | 1.5–3 недели |
| 5. Инфраструктура | 418+троттлинг, REST-конвейер, классификация ошибок, smoke-тесты релиза | 3–5 дней |
| 6. Дальняя перспектива | importer/синхронизация библиотеки, SMS-OTP вход (`route-authorization-type` → `get-mcode` → `login/otp`), SberID PKCE, Blend двух аккаунтов (`synthesisPlaylistBuild`), Widevine-исследование, телеметрия | по желанию |

**Фаза 1 строго до Фазы 2**: Atlas-сессия живёт ровно столько же, сколько токен, — без refresh-механики Atlas будет постоянно «протухать».

---

## 10. Справочник источников

| Что | Где |
|---|---|
| Тела всех 196 GraphQL-операций (индекс + файлы) | `/mnt/hgfs/VM_share/Research/zvuk-api-docs-v2/evidence/gql/` (`_index.tsv`) |
| Интерсепторы/сервисы APK (refresh `f62`/`gdy`, заголовки `a5y`, `X-C-P` enum `huq`, сервисы `d4y`/`idy`/...) | `/mnt/hgfs/VM_share/Research/zvuk-api-docs-v2/evidence/apk-notes/` |
| Живые ответы web-API (профиль, стрим, поиск, 401/418, коллекция) | `/mnt/hgfs/VM_share/Research/zvuk-api-docs/evidence/json/` |
| Отчёты Atlas (API, иерархия, рекомендации, риски, верификация) | `/mnt/hgfs/VM_share/Research/atlas-research/report_atlas_*.md`, `VERIFICATION.md`, `login_flow_atlas.md` |
| Фикстуры Atlas (полная карта 137 КБ, остров, cookie-пробы) | `/mnt/hgfs/VM_share/Research/atlas-research/capture/` |
| APK 4.117 + кросс-чек Atlas (cookie `auth`/`sauth`/`in_webkit`) | `/mnt/hgfs/VM_share/Research/zvuk_apk_atlas_research/reports/` |
| Внутренние доки плагина | `docs/future_tasks.md`, `docs/COMPARISON_REPORT.md`, `docs/RESEARCH_REPORT_2026-07.md` (X-Session-UID, recommenderRadio), `docs/THROTTLING_RETRY.md`, `docs/TESTING_SLIM_MOCKING.md` |

### Ключевые константы

* GraphQL: `POST https://zvuk.com/api/v1/graphql`, тело `{operationName, variables, query}`.
* Профиль: `GET https://zvuk.com/api/tiny/profile` (без токена — анонимный профиль).
* Refresh: `POST https://zvuk.com/api/tiny/refresh` (`X-Auth-Token`, `X-C-P: Q`). **Не** `id.zvuk.com/api/v2/token/refresh`.
* Atlas: `https://atlas.zvuk.com/api/v1/...`, авторизация `Cookie: auth=<токен>`.
* Обложки: `https://cdn-image.zvuk.com/pic?hash=&id=&size=&type=`; `/static/...` — только через image proxy.
* Стрим: GraphQL `mediaContents` → `stream.{mid,high,flac,flacdrm}`; фолбэк REST `/api/tiny/track/stream?id=&quality=`.
