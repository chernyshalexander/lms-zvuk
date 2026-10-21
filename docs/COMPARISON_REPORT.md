# Сравнительный анализ: lms-zvuk (Lyrion/LMS плагин) vs ma-provider-zvuk-music (Music Assistant провайдер)

**Дата:** 2026-07-06
**Назначение:** техническое задание-основа для стороннего middle-разработчика, который будет дорабатывать LMS-плагин Zvuk, заимствуя решения из провайдера Music Assistant.

---

## 1. Обзор проектов

| Параметр | lms-zvuk | ma-provider-zvuk-music |
|---|---|---|
| Платформа | Lyrion Music Server (Squeezebox), Perl 5 | Music Assistant, Python 3 (async) |
| Объём кода | ~4 550 строк Perl (8 модулей) | ~1 850 строк Python (4 модуля) + внешняя библиотека `zvuk-music` |
| Работа с API Звука | Собственные GraphQL-запросы прямо в коде плагина (`https://zvuk.com/api/v1/graphql`) + tiny API для профиля | Через pip-библиотеку **`zvuk-music[async]==0.6.1`** — вся GraphQL/REST-логика вынесена из провайдера |
| Тесты | Только исследовательские скрипты в `test/` (проверка GraphQL-операций); юнит-тестов в репозитории нет | ~120 pytest-тестов (parsers, api_client, browse, library, lyrics, stream), CI, ruff, mypy |
| Документация | `docs/` (архитектура, onboarding, чек-листы ручного тестирования) | `docs/` + сайт документации (Astro Starlight), CHANGELOG, feature-spec |
| Версия/статус | 0.1.6, активная разработка (ветка `experiment`) | beta, опубликован (manifest.json, multi_instance) |

### 1.1 Структура lms-zvuk

```
lms-zvuk/
├── Plugin.pm            (2169 строк) — root-меню OPML, все browse/search-хендлеры,
│                          Wave Settings UI (Jive-списки + wizard-код), GigaMix-меню,
│                          web-хендлеры (OAuth, wave settings AJAX)
├── API.pm               (160)  — константы (URL, TTL, качество), токены аккаунтов,
│                          централизованный кеш, cacheTrackMetadata, getImageUrl
├── API/Async.pm         (1163) — все GraphQL-операции через _graphql()
│                          (кеш → троттлинг → retry → HTTP)
├── ProtocolHandler.pm   (445)  — псевдопротокол zvuk://, getNextTrack, выбор качества,
│                          explodePlaylist (wave/album/playlist/artist),
│                          автодогрузка Wave и GigaMix («дозагурка»)
├── Throttle.pm          (108)  — token bucket, 5 req/s
├── Retry.pm             (214)  — до 5 попыток, экспоненциальный backoff + jitter
├── Settings.pm          (167)  — web-настройки: аккаунты (токены), качество
├── WaveSettings.pm      (131)  — персистентные настройки Волны per-account, список жанров
├── HTML/EN/plugins/zvuk — шаблоны настроек, слайдеры Волны, иконки
└── install.xml, strings.txt (RU/EN-локализация)
```

### 1.2 Структура ma-provider-zvuk-music

```
ma-provider-zvuk-music/
├── provider/__init__.py   (103) — SUPPORTED_FEATURES, config entries (token, quality)
├── provider/provider.py   (786) — реализация MusicProvider: search, get_*,
│                            library-синхронизация, recommendations, browse,
│                            лайки, управление плейлистами, лирика, stream details
├── provider/api_client.py (559) — обёртка над zvuk_music.ClientAsync:
│                            троттлинг, декоратор handle_zvuk_errors
├── provider/parsers.py    (363) — маппинг моделей Zvuk → модели MA
│                            (artist/album/track/playlist + богатые метаданные)
└── provider/constants.py  (33)  — конфиг-ключи, лимиты, SYNTHESIS_PLAYLIST_IDS
```

---

## 2. Сравнение реализованных функций

### 2.1 Сводная таблица

| Функция | lms-zvuk | ma-provider | Комментарий |
|---|---|---|---|
| Поиск (треки/артисты/альбомы/плейлисты) | ✅ с курсорной пагинацией «Next page» | ✅ (лимит на тип, без UI-пагинации) | Паритет; у LMS пагинация даже лучше |
| Альбом → треки | ✅ | ✅ | Паритет |
| Артист → топ-треки / альбомы | ✅ | ✅ | Паритет |
| Плейлист → треки | ✅ (500 за раз, без пагинации) | ✅ (страницы по 50: SimpleTrack ID → батч getTracks) | У MA честная пагинация |
| Моя коллекция (лайкнутые треки/альбомы/артисты) | ✅ (чтение) | ✅ (чтение, синхронизация в библиотеку MA) | |
| Подкасты и эпизоды | ✅ частично (эпизоды **не воспроизводятся** — `type => 'text'`) | ❌ | Уникально для LMS, но недоделано |
| Личная Волна (personal wave radio) | ✅ + настройки (popular/energy/fun/vocal/language/жанры) + бесконечная догрузка + фидбек isSkipped | ❌ | **Ключевое преимущество LMS** |
| GigaMix (AI-плейлист по текстовому промпту) | ✅ + remake + пагинация + автодогрузка | ❌ | **Ключевое преимущество LMS** |
| Рекомендации (dynamicBlock «Для вас») | ✅ (артисты/альбомы/плейлисты) | ❌ (другой механизм) | Разные источники |
| «Плейлисты для вас» (synthesis, ID 3,4,6,11–15) | ⚠️ **заглушка** `getSynthesisPlaylists` → `not_implemented` (`API/Async.pm:1039`) | ✅ через lightweight `getShortPlaylist` | **Заимствовать** |
| «Подборки» (editorial-плейлисты по жанрам) | ❌ | ✅ `get_editorial_playlist_ids` (grid content API) + `get_playlists` | **Заимствовать** |
| Иерархия рекомендаций (папки for_you / editorial) | ❌ (плоское root-меню) | ✅ RecommendationFolder + browse() | **Заимствовать структуру меню** |
| Похожие треки | ❌ | ✅ эвристика через `release.related` | **Заимствовать** (для контекстного меню / DSTM) |
| Лайк/анлайк (трек, альбом, артист, плейлист) | ❌ | ✅ полный набор | **Заимствовать** |
| Создание/редактирование плейлистов | ❌ | ✅ create / add tracks / remove (через полную перезапись `update_playlist`) | Заимствовать (ниже приоритет) |
| Тексты песен (lyrics, LRC-синхронизация) | ❌ | ✅ `get_lyrics`: LRC (`subtitle`) или plain text | **Заимствовать** |
| Батч-запросы (get_tracks/releases/artists/playlists по списку ID) | ⚠️ частично (getTracks/getStream принимают массив, но коллекция грузится целиком) | ✅ системно, батчи по 50 (`_iter_batched`) | Заимствовать паттерн |
| Мультиаккаунт | ✅ (несколько токенов, привязка per-player) | ⚠️ через multi_instance (несколько экземпляров провайдера) | Преимущество LMS |
| Захват токена | ✅ полуавтоматический OAuth-flow через браузер + анонимный токен (128 kbps) | ❌ ручная вставка X-Auth-Token | Преимущество LMS |
| Качество звука | ✅ mid/high/flac + fallback flacdrm→high→mid | ✅ high/lossless + fallback flac→high→mid | Паритет; источники URL разные (см. 2.2) |
| Троттлинг | ✅ 5 req/s (token bucket) | ✅ 5 req/s (Throttler MA) | Паритет |
| Retry с backoff | ✅ собственный Retry.pm (5 попыток, jitter, классификация ошибок по HTTP-коду) | ⚠️ ретраи на стороне ядра MA (`ResourceTemporarilyUnavailable` c backoff_time) | Паритет по сути |
| Кеширование | ✅ ключ userId+operation+MD5(vars), TTL по типу операции (24ч/1ч/5м/0) | ✅ `@use_cache` с TTL 3ч–30 дней | У MA TTL агрессивнее (поиск 14 дней) |
| Богатые метаданные (жанры, год, лейбл, explicit, биография артиста, fanart) | ⚠️ минимум (title/artist/album/duration/cover) | ✅ полный маппинг в parsers.py | **Заимствовать поля** |
| Безопасность токена при загрузке картинок | — (URL картинок отдаются как есть) | ✅ allowlist хостов, токен только на zvuk.com/cdn.zvuk.com | Учесть |
| Типизированная обработка ошибок API | ⚠️ хеши `{error => ...}` вручную в каждом хендлере | ✅ единый декоратор `handle_zvuk_errors` (LoginFailed / RateLimit / BotDetected / NotFound) | **Заимствовать паттерн** |

### 2.2 Различие в получении stream URL (важно)

- **lms-zvuk** (`API/Async.pm:435`, getStream): GraphQL `mediaContents { ... on Track { stream { high mid flac flacdrm } } }`. Плюс: одним запросом duration + все качества. Минус: поле `flacdrm` может требовать DRM.
- **ma-provider** (`api_client.py:317`): REST **`/api/tiny/track/stream?quality=flac|high|mid`** → `{"result":{"stream":"https://..."}}` — прямые НЕ-DRM URL (тот же endpoint использует zvuk-dl-rs). Поле `has_flac` из метаданных признано ненадёжным — FLAC всегда пробуется первым, при неудаче фоллбек на high → mid.

**Рекомендация:** добавить в LMS tiny-endpoint как fallback, когда GraphQL `stream.flac` пуст, а `flacdrm` непроигрываем; и перенять принцип «не доверять has_flac».

---

## 3. Сильные и слабые стороны

### 3.1 lms-zvuk — сильные стороны

1. **Уникальные фичи, которых нет в MA-провайдере:** Личная Волна с полным набором настроек и бесконечной очередью, GigaMix (генерация/remake/автодогрузка), рекомендации dynamicBlock, подкасты, мультиаккаунт per-player, браузерный захват токена, анонимный доступ.
2. **Продуманный конвейер запросов** (`API/Async.pm:_graphql`): кеш → троттлинг → retry — единая точка для всех операций, cache-hit минует троттлинг.
3. **Проактивное кеширование метаданных** (`API.pm:cacheTrackMetadata`) — обложка/длительность доступны мгновенно при старте воспроизведения; `parseRemoteHeader` даёт точный прогресс-бар.
4. **Внимание к тонкостям Zvuk API:** JSON-booleans через `\1/\0`, float-типизация для `NormalizedFloat`, заголовки для обхода WAF (`x-app-name`, User-Agent, origin/referer), `artistTemplate` с плейсхолдерами `{0} & {1}`.
5. Обратная связь для Волны: `isSkipped`/`playDuration` при догрузке — рекомендации обучаются.

### 3.2 lms-zvuk — слабые стороны

1. **Монолитный Plugin.pm (2169 строк)**: меню, поиск, Wave UI (включая ~300 строк мёртвого wizard-кода, строки 1300–1617, помеченного «NOT CURRENTLY USED»), GigaMix, OAuth-хендлеры — всё в одном файле. Затрудняет сопровождение.
2. **Заглушки/недоделки:**
   - `getSynthesisPlaylists` возвращает `not_implemented` (`API/Async.pm:1039`) — при том, что решение уже найдено (см. §4.1);
   - эпизоды подкастов рендерятся как `type => 'text'` (`Plugin.pm:_renderEpisode`, строка ~1010–1022) — их нельзя воспроизвести, хотя ProtocolHandler в принципе мог бы обрабатывать `zvuk://episode:<id>` по аналогии с `zvuk://wave`;
   - `handleRecommendations` делает **4 одинаковых GraphQL-вызова** (`Plugin.pm:544, 607, 637, 667`) — категории + по одному на каждый подсписок; первый уходит в сеть, остальные три обычно попадают в кеш (ключ = md5 от идентичных переменных, TTL 1ч), но при холодном кеше или его вытеснении — 4 полноценных запроса вместо одного;
   - **у категорий рекомендаций нет пагинации**: `handleRecommendationArtists/Albums/Playlists` (`Plugin.pm:603–691`) всегда запрашивают `pages: [1]` и не добавляют ссылку «Next page» — в отличие от `_searchGeneric`, у которого курсорная пагинация есть. Если `dynamicBlock` возвращает больше элементов, чем помещается на страницу 1, пользователь их не увидит.
3. **Нет операций записи:** лайки, плейлисты — только чтение.
4. **Нет лирики, похожих треков, editorial-подборок.**
5. **Бедные метаданные:** жанры/год/лейбл/explicit не пробрасываются в UI.
6. **Два независимых бага корректности в мультиаккаунт-логике** (подробно — см. §3.2.1 ниже): переключение аккаунта не подхватывается активным воспроизведением/настройками Волны, а Web-UI слайдеры Волны сохраняются не туда, куда читаются при реальном проигрывании.
7. **Нет юнит-тестов в репозитории** (есть только методика мокинга в `docs/TESTING_SLIM_MOCKING.md`).
8. **Нет интеграции с Online Music Library (Importer)** — коллекция не попадает в «Мою музыку» LMS, только browse через приложение.
9. Существующая внутренняя документация (`docs/project_status.md`) устарела относительно текущего кода (упоминает только Mid/High, не знает про Wave/GigaMix/мультиаккаунт) — не полагаться на неё, ориентироваться на код.

### 3.2.1 Два подтверждённых бага корректности в мультиаккаунт-режиме

Эти два дефекта не были очевидны при поверхностном чтении и заслуживают отдельного разбора — они касаются флагманской фичи плагина (мультиаккаунт) и могут давать пользователю впечатление, что настройки/переключение аккаунта «не работают», без явной ошибки в логах.

**Баг A — переключение аккаунта не долетает до воспроизведения и настроек Волны.**

- `_switchAccount` (`Plugin.pm:242–270`) обновляет только персистентный `prefs->client($client)->set('userId', ...)`.
- Но и в `Plugin.pm:_getAPIHandler` (строки 1194–1198), и в отдельной копии `ProtocolHandler.pm:_getAPIHandler` (строки 420–429) логика одна и та же:
  ```perl
  return $client->pluginData('zvuk_api') || _initAPIHandler($client);
  ```
  То есть если `pluginData('zvuk_api')` уже когда-либо был установлен (а он выставляется при первом же обращении — старте Волны, открытии настроек Волны и т.д.), то **все последующие вызовы будут возвращать этот закешированный объект API**, привязанный к userId на момент первого обращения. `_switchAccount` этот `pluginData` не сбрасывает.
- Затронутые пути: `getStream`/`getPersonalWave`/`_explodeWave`/`_loadMoreWaveTracks` в ProtocolHandler.pm (т.е. **сам стриминг и Персональная Волна**), а также Wave Settings sliders/genres в Plugin.pm.
- Путь, который багу не подвержен: основное root-меню, поиск, browse, GigaMix — они используют другой механизм, `_get_api_client()` (`Plugin.pm:127–133`), который каждый раз заново вычисляет userId из prefs и не кеширует его в `pluginData`.
- **Наблюдаемый эффект:** пользователь с двумя аккаунтами переключается через «Select Account» → меню/поиск/GigaMix сразу отражают новый аккаунт, но если до переключения уже запускалась Волна или открывались её настройки на этом плеере — Волна и её настройки продолжат работать от **старого** аккаунта до переподключения клиента к серверу (сброс `pluginData`).
- **Фикс:** в `_switchAccount` дополнительно делать `$client->pluginData('zvuk_api', undef)` (и в идеале — унифицировать оба `_getAPIHandler` в общую функцию, вызываемую из обоих модулей, чтобы фикс не пришлось дублировать).

**Баг B — Web UI слайдеры Волны сохраняются не в тот аккаунт, из которого потом читаются.**

- `handleWaveSettingsWebUI` (`Plugin.pm:1771–1804`, конкретно строка 1777) и `handleSaveWaveSettingsWeb` (`Plugin.pm:1806–1849`, конкретно строка ~1830, с явным комментарием `# Get current account ID (default for web UI)`) **жёстко используют `account_id = 'default'`** при чтении/записи `WaveSettings::loadSettings/saveSettings`.
- А путь, которым эти настройки реально читаются при проигрывании Волны — `ProtocolHandler.pm:_explodeWave`/`_loadMoreWaveTracks` (строки 291–295, 342–344) и Jive-путь в `Plugin.pm:_getSettingValue/_updateSetting` (строки 1104–1127) — используют **настоящий `accountId()`** (обычно это Zvuk `userId`, не строка `"default"`; `default` — лишь запасное значение при отсутствии клиента/API).
- **Наблюдаемый эффект:** пользователь открывает настройки плагина в Web UI (единственный способ настроить Волну для Material/Default Skin — см. `handleWaveSettingsRouter`), двигает слайдеры «Энергичность»/«Настроение» и т.д., видит «Сохранено», но при следующем запуске Волны эти изменения **не применяются**, потому что читаются из ключа `wave_settings_<реальный userId>`, а сохранены были в `wave_settings_default`. Единственный случай, когда баг не проявляется — если у пользователя ровно один аккаунт и `accountId()` почему-то возвращает буквально `'default'` (не типичный случай — обычно это numeric Zvuk ID).
- **Фикс:** прокидывать реальный `userId` текущего игрока/сессии в `handleWaveSettingsWebUI`/`handleSaveWaveSettingsWeb` (клиент доступен через `$response->request` → connected player, либо через cookie/сессию текущего Web UI пользователя), либо — если для Web UI архитектурно нет привязки к конкретному плееру/аккаунту — явно документировать это ограничение в UI («настройки применяются к аккаунту по умолчанию»).

Оба бага стоит завести как P1-задачи **до** любых новых фич из §4 — они не требуют новых GraphQL-операций, только починку роутинга account_id/pluginData, и напрямую влияют на доверие пользователей к уже существующей флагманской фиче (мультиаккаунт + персонализация Волны).

### 3.3 ma-provider — сильные стороны

1. **Разделение на слои:** тонкий провайдер ↔ обёртка api_client ↔ отдельная переиспользуемая библиотека `zvuk-music`. Провайдер не знает про GraphQL вообще.
2. **Полный CRUD пользовательского контента:** лайки всех типов, создание/правка плейлистов.
3. **Контент-дискавери:** synthesis + editorial плейлисты, структурированные Recommendations/Browse.
4. **Лирика с LRC-синхронизацией.**
5. **Единая типизированная обработка ошибок** (`handle_zvuk_errors`): маппинг UnauthorizedError→LoginFailed, 429→backoff 60с, BotDetectedError→ProviderUnavailable, NotFound→настраиваемое значение по умолчанию.
6. **Богатый маппинг метаданных** (parsers.py): AlbumType (single/EP/compilation), год+release_date, жанры, лейбл, explicit, биография артиста, fanart (second_image c ремапом subtype), credits.
7. **Инженерная зрелость:** тесты, типизация, линтеры, CI, документация, CHANGELOG.
8. **Безопасность:** allowlist хостов для авторизованной загрузки картинок (защита от утечки токена).

### 3.4 ma-provider — слабые стороны

1. Нет Волны, GigaMix, подкастов, рекомендаций dynamicBlock — то есть всей «умной» части Звука.
2. «Похожие треки» — эвристика (по 2 трека из related-релизов), не настоящий similar-API.
3. Удаление трека из плейлиста — полная перезапись списка (ограничение API, но дорого на больших плейлистах: fetch до 10 000 треков).
4. Ручной ввод токена, без OAuth-флоу.
5. Зависимость от внешней библиотеки: изменения API Звука требуют релиза zvuk-music.

---

## 4. Что заимствовать в LMS-плагин: план работ

Приоритеты: P1 — максимум пользы/готовые решения, P2 — заметная ценность, P3 — nice-to-have.

> **Где смотреть эталонные запросы:** локально уже есть исходники самой библиотеки `zvuk-music` — `/home/chernysh/Projects/zvuk-music/` (это то, что ma-provider подключает как `zvuk-music[async]==0.6.1`). Тела GraphQL-запросов и мутаций лежат отдельными файлами `.graphql` в `zvuk_music/graphql/queries/` и `zvuk_music/graphql/mutations/`, а то, какой файл к какому REST/GraphQL-вызову относится и какие ключи есть в enum-типах — в `zvuk_music/client_async.py` и `zvuk_music/enums.py`. Ниже во всех пунктах даны точные тела запросов, извлечённые оттуда (не гипотезы из тестовых скриптов `test/*.pl`, которые в репозитории lms-zvuk остались неподтверждёнными черновиками).

### P0 — Исправить перед началом новых фич (баги, не заимствования)

Это не заимствования из ma-provider, а собственные дефекты lms-zvuk, найденные в ходе анализа (см. §3.2.1). Их стоит закрыть первыми, потому что новые P1-фичи (лайки, editorial-подборки) будут добавлять новые точки чтения `accountId`/`pluginData` и наследовать те же грабли, если не починить источник.

- **P0.1** Сброс `pluginData('zvuk_api')` в `_switchAccount` (`Plugin.pm:242–270`) + унификация `_getAPIHandler`/`_initAPIHandler` в общий модуль вместо двух копий (Plugin.pm:1194–1207, ProtocolHandler.pm:420–443). Оценка: 0.5 дня.
- **P0.2** Прокидывание реального `accountId` в Web UI Wave Settings вместо жёсткого `'default'` (`Plugin.pm:1777`, `Plugin.pm:~1830`). Оценка: 0.5–1 день (зависит от того, как в LMS Web UI принято определять «текущего» клиента/плеера для AJAX-запроса без явного `player_id` в пейлоаде — это стоит уточнить по `docs/architecture.md` или у автора).

### P1.1 «Плейлисты для вас» (synthesis playlists) — доделать заглушку

- **Что:** заменить `getSynthesisPlaylists` в `API/Async.pm:1039`.
- **⚠️ Важная поправка к предыдущей версии этого отчёта и к `test/test_synthesis_playlists.pl`:** оба ранее предполагали, что нужный запрос называется `getShortPlaylist(ids: ...)` как отдельное GraphQL-поле, либо `mediaContents { ... on Playlist }`. Проверка по исходникам `zvuk-music` показала, что это не так.
- **Точный проверенный запрос** (`zvuk_music/graphql/queries/getShortPlaylist.graphql`, используется в `client_async.py:get_short_playlist`):
  ```graphql
  query getShortPlaylist($ids: [ID!]!) {
    getPlaylists(ids: $ids) {
      id
      title
      isPublic
      description
      duration
      image { src }
    }
  }
  ```
  Ключевой нюанс: `operationName` в теле запроса — `getShortPlaylist`, но само GraphQL-поле, которое реально выбирается — **`getPlaylists`** (то же поле, что и для обычных плейлистов, просто с укороченным набором полей — без `tracks`). ID фиксированные, стабильные per-account: 3, 4, 6, 11, 12, 13, 14, 15 (см. `ma-provider/provider/constants.py:SYNTHESIS_PLAYLIST_IDS`).
- Треки для каждого из этих плейлистов — существующим `getPlaylistTracks(id)` (уже реализован в `API/Async.pm:570`).
- **Точки правки:** `API/Async.pm` (добавить `getShortPlaylists($self, $cb, $ids)` по образцу существующего `getTracks`, тело запроса — см. выше), `Plugin.pm:handlePersonalizedPlaylists` уже готов и обрабатывает и ошибку, и пустой список — менять не нужно.
- **Оценка:** 0.5 дня (запрос уже полностью верифицирован, копировать почти буквально).

### P1.2 «Подборки» (editorial-плейлисты)

- **Что:** новый пункт меню «Подборки» с редакционными плейлистами по жанрам.
- **⚠️ Поправка:** это **не GraphQL-операция**, а вызов REST-эндпоинта Tiny API (того же семейства, что уже используется в LMS-плагине для `PROFILE_URL`). Двухшаговый алгоритм из `zvuk_music/client_async.py:781–822`:
  1. **`GET https://zvuk.com/api/tiny/grid/content?name=editorial_playlist&ranker_enabled=true`** (заголовки — те же `x-auth-token`, что и для GraphQL) → ответ вида `{"result": {"page": {"data": [...]}}}` (обёртку `result` снимает внутренний хелпер библиотеки — на стороне LMS её тоже нужно будет снять вручную, аналогично `getProfile`). Каждый элемент `data[]` имеет поля `id`, `type` — нужны только те, где `type == "playlist"`.
  2. Собранные ID → существующий/новый `getShortPlaylists` из P1.1 (или полный `getPlaylists`, если нужны доп. поля вроде `duration`) для получения метаданных обложки/названия.
- **Точки правки:** новый метод в `API/Async.pm`, например `getGridContent($self, $cb, $name)` — HTTP GET (не POST на `GRAPHQL_URL`!) на `TINY_API_URL/grid/content`, поэтому его нельзя завести через `_graphql()` как есть — нужен отдельный тонкий враппер по образцу существующего `getProfile` (`API/Async.pm:314–340`), в идеале тоже прогнанный через `$throttler`/`$retry_mgr`, которые сейчас жёстко зашиты внутрь `_graphql()` и не переиспользуются для не-GraphQL запросов — это стоит вынести в общий хелпер, если появится второй REST-путь (см. также P2.1, лирика — тоже REST).
- **Точки правки:** `Plugin.pm` (+1 хендлер по образцу `handlePersonalizedPlaylists`), `strings.txt` (+токен `PLUGIN_ZVUK_EDITORIAL_PLAYLISTS` RU/EN — сейчас в `strings.txt` такого токена нет, проверено).
- **Оценка:** 1 день (endpoint и параметры уже верифицированы; время уйдёт на вынесение переиспользуемого REST-хелпера).

### P2.5 Новая находка: «Blend»-плейлист между двумя аккаунтами (Synthesis Playlist Build)

Это открытие, не отражённое ни в ma-provider, ни в предыдущей версии этого отчёта — обнаружено только при чтении исходников `zvuk-music`, и ни один из двух проектов его не реализует.

- **Что это:** у Zvuk есть отдельная, самостоятельная GraphQL-фича «синтез-плейлист» (**не путать** с «Плейлисты для вас» из P1.1 — та же терминология в API, но другая сущность): плейлист, построенный на пересечении музыкальных вкусов **двух профилей** — аналог Spotify Blend.
  - `zvuk_music/graphql/mutations/synthesisPlaylistBuild.graphql`:
    ```graphql
    query synthesisPlaylistBuild($firstAuthorId: ID!, $secondAuthorId: ID!) {
      synthesisPlaylistBuild(authorIds: [$firstAuthorId, $secondAuthorId]) {
        id
        tracks { id title duration explicit artists { id title image { src } } release { id title date type image { src } explicit artists { id title image { src } } } }
        authors { id name image { src } matches { score } }
      }
    }
    ```
    (в самой библиотеке этот файл лежит в каталоге `mutations/`, хотя по факту это `query`, а не `mutation`, — особенность самой Zvuk-схемы, не опечатка в LMS-плагине, если решите портировать один в один).
  - `zvuk_music/graphql/queries/synthesisPlaylist.graphql` — получить уже созданный blend-плейлист повторно по `ids`, с теми же полями `authors { matches { score } }`.
- **Почему это интересно именно для LMS-плагина:** плагин и так уникален поддержкой **мультиаккаунта на одном плеере** (`selectAccount`/`_switchAccount`) — то есть у него уже есть готовый UI-паттерн для выбора «второго» аккаунта из уже сохранённых токенов. Это единственная точка сравнения, где lms-zvuk структурно ближе к реализации этой фичи, чем ma-provider (у которого каждый аккаунт — отдельный экземпляр провайдера, между которыми Music Assistant не даёт устраивать кросс-запросы).
- **Как встроить:** пункт меню «Совместный плейлист» → список сконфигурированных аккаунтов (переиспользовать `selectAccount`-like список) → на выбор второго аккаунта вызвать `synthesisPlaylistBuild(authorIds: [<currentAuthorId>, <secondAuthorId>])`, где `authorId`, вероятно, соответствует `profile.id` (нужно уточнить эмпирически — оба ID могут быть числовыми userId или отдельным полем `author.id`, для чего пригодится существующий `getProfile`).
- **Риски/неизвестные:** не проверено на реальном аккаунте (нет доступа к живому API из этой сессии) — нужен ручной тест перед тем, как закладывать в спринт; `authors.matches.score`, возможно, требует, чтобы второй профиль дал согласие/был взаимно подписан — это стоит выяснить в первую очередь через `test/`-скрипт по аналогии с уже существующими.
- **Оценка:** 2–3 дня (включая ручную разведку API), можно поставить в P2/P3 backlog — не блокирует остальной план.

### P1.3 Реструктуризация меню «Рекомендации» (иерархия как в MA)

- **Что:** объединить «Personalized Playlists», «Recommendations» и новые «Подборки» под одним корневым пунктом с подпапками — зеркало структуры RecommendationFolder из MA:
  ```
  Zvuk
  ├─ Поиск
  ├─ Моя Волна
  ├─ GigaMix
  ├─ Рекомендации
  │   ├─ Плейлисты для вас   (synthesis)
  │   ├─ Подборки            (editorial)
  │   └─ Для вас: артисты / альбомы / плейлисты (dynamicBlock)
  └─ Моя музыка (…)
  ```
- **Как:** в OPML это просто `type => 'outline'` с вложенными items (как уже сделано для «Поиск» и «Моя музыка» в `Plugin.pm:_buildRootMenu`).
- **Попутно:** устранить 4-кратный вызов `getMusicRecommendations` — категорийное меню может передавать уже полученные списки через `passthrough` (данные и так кешируются, но лишние круги по throttle-очереди не нужны).
- **Оценка:** 0.5–1 день.

### P1.4 Лайки (добавить/убрать из коллекции)

- **Что:** мутации like/unlike для track, release, artist, playlist (+ podcast, episode, profile) + пункты в контекстном меню трека/альбома («Добавить в коллекцию Zvuk»).
- **⚠️ Поправка к ma-provider:** в `api_client.py` (`like_track`/`like_release`/`like_artist`/`like_playlist`, строки 403–505) заведено 8 отдельных Python-методов — но это обёртка самой библиотеки `zvuk-music` для удобства типизации. На уровне реального GraphQL API **это одна и та же пара мутаций для всех типов**, параметризованная перечислением:
  ```graphql
  mutation addItemToCollection($id: ID, $type: CollectionItemType) {
    collection { addItem(id: $id, type: $type) }
  }
  mutation removeItemFromCollection($id: ID, $type: CollectionItemType) {
    collection { removeItem(id: $id, type: $type) }
  }
  ```
  (`zvuk_music/graphql/mutations/addItemToCollection.graphql`, `removeItemFromCollection.graphql`). Допустимые значения `$type` (`zvuk_music/enums.py:CollectionItemType`): `track`, `release`, `artist`, `podcast`, `episode`, `playlist`, `profile`. Это значит, что в `API/Async.pm` достаточно **одной пары параметризованных функций** (`likeItem($self, $cb, $id, $type)` / `unlikeItem(...)`), а не восьми — заметно проще, чем предполагала структура ma-provider.
- **LMS-механика:** зарегистрировать track/album/artist info handler (`Slim::Menu::TrackInfo->registerInfoProvider` и аналоги для Album/Artist) и/или `itemActions.info` (паттерн описан в референсных плагинах TIDAL/Qobuz — см. skill «lyrion-music-service-plugin», секция InfoMenu). После мутации — инвалидировать кеш операций `userTracks`/`userCollection*` (сейчас TTL 5 минут: пользователь не увидит лайк сразу).
- **Точки правки:** `API/Async.pm` (+2 параметризованные функции), новый `InfoMenu.pm`, `Plugin.pm:initPlugin` (регистрация), `strings.txt`.
- **Оценка:** 2–3 дня (меньше, чем в предыдущей оценке — за счёт того, что мутация одна на все типы).

### P2.1 Тексты песен (lyrics)

- **Что:** показ текста в «Информации о треке».
- **⚠️ Поправка:** это **не GraphQL**, а REST-запрос через Tiny API (`zvuk_music/client_async.py:406–423`):
  ```
  GET https://zvuk.com/api/tiny/lyrics?track_id=<id>
  ```
  Ответ: `{"result": {"lyrics": "...", "type": "subtitle"|...}}` — если `lyrics` пуст/отсутствует, значит текста нет. Тип `subtitle` (см. `zvuk_music/enums.py:LyricsType`) соответствует LRC-синхронизированному формату, иначе — обычный текст. Как и в P1.2, это ещё один повод завести общий REST-хелпер (сейчас в LMS-плагине REST используется только разово в `getProfile`, без централизованного троттлинга/retry — см. замечание в P1.2).
- **LMS-механика:** пункт в InfoMenu (из P1.4) с `type => 'textarea'`; LRC-тайминги для базового вывода вырезать регуляркой `s/\[\d+:\d+\.\d+\]//g`. Ошибки должны молча возвращать пустой результат — лирика не должна ломать остальной InfoMenu.
- **Оценка:** 1 день (после P1.4).

### P2.2 Похожие треки + интеграция с Don't Stop The Music

- **Что:** «Похожие треки» в контекстном меню + провайдер DSTM/LastMix (когда очередь кончается — доигрывать похожим).
- **Как в MA:** `provider.py:get_similar_tracks` — трек → его релиз → `release.related` → по 2 трека из каждого related-релиза до лимита. Поле подтверждено в `zvuk_music/graphql/queries/getReleases.graphql:62`: `related(limit: $relatedLimit) { ... }` — принимает лимит как параметр запроса (по умолчанию 100 в библиотеке). В LMS запрос на альбом сейчас упрощённый (`getAlbumTracks` в `API/Async.pm:462`, без `related`) — нужно добавить туда (или в отдельный запрос) поле `related(limit: N) { id }`.
- **Альтернатива, более мощная:** у LMS уже есть Волна — DSTM-провайдер можно реализовать поверх `getPersonalWave` (MA такого не может). Тогда `release.related` оставить только для InfoMenu.
- **Оценка:** 2–3 дня.

### P2.3 Обогащение метаданных

- **Что:** пробросить в рендеры и кеш метаданных поля, которые MA уже маппит (`parsers.py`): год релиза, жанры, лейбл, explicit-флаг, тип релиза (single/EP/compilation), биографию артиста (`with_description`), fanart (`second_image`, с ремапом `subtype=secondImage → cover_background` — CDN отклоняет исходный subtype!).
- **Все поля подтверждены в реальных запросах библиотеки** (не нужно гадать со схемой):
  - `zvuk_music/graphql/queries/getReleases.graphql`: `genres { id name shortName }` и `label { ... }` (строка 58) — оба поля есть, просто не выбираются в текущих запросах LMS-плагина (`API/Async.pm:getAlbumTracks`, `getArtistAlbums` и др. используют только `id title type date artistTemplate image { src }`).
  - `zvuk_music/graphql/queries/getArtists.graphql`: `description @include(if: $withDescription)`, `secondImage { src }` — оба уже опциональные поля с `@include`-директивой, паттерн одинаковый с тем, что уже используется в самом LMS-плагине (`@include(if: $tracks)` в `search`, `API/Async.pm:368`), так что расширение фрагмента будет идти по уже знакомому шаблону.
  - `zvuk_music/graphql/queries/getFullTrack.graphql`: помимо базовых полей трека есть `hasFlac`, `credits`, `collectionItemData { itemStatus lastModified }` (последнее — точный источник статуса «лайкнут ли трек», нужен для P1.4, чтобы отображать текущее состояние лайка в InfoMenu, а не только менять его).
- **Точки правки:** GraphQL-фрагменты в `API/Async.pm` (+поля), `API.pm:cacheTrackMetadata` (year, genres), `Plugin.pm:_renderAlbum` (год в line2), InfoMenu (биография, лейбл).
- **Оценка:** 1–2 дня.

### P2.4 Единый обработчик ошибок API (паттерн handle_zvuk_errors)

- **Что:** сейчас каждый хендлер в Plugin.pm вручную проверяет `ref $result eq 'HASH' && $result->{error}` — местами это забыто. Ввести в `_graphql` классификацию ошибок и единый хелпер рендера ошибки для UI.
- **Как в MA:** `api_client.py:47–85` — декоратор маппит исключения в 4 категории: `auth` (плохой токен → показать «войдите заново»), `rate_limit` (429 → «повторите позже», backoff 60с), `bot_detected` (WAF — критично для Звука!), `not_found` (вернуть пустой список/`undef`).
- **LMS-реализация:** `_graphql` уже возвращает `{error, code}` — добавить поле `error_type` и функцию `Plugin::_renderApiError($client, $result)` → локализованное сообщение по типу. Отдельно: детект WAF-страницы (HTML вместо JSON → сейчас это `parse_error`, стоит распознавать как `bot_detected`).
- **Оценка:** 1–2 дня.

### P3.1 Управление плейлистами

- **Точные проверенные мутации** (`zvuk_music/graphql/mutations/*.graphql`, `client_async.py:612–710`):
  ```graphql
  # operationName должен быть буквально "createPlayList" (с большой L) — это то,
  # что реально ожидает Zvuk-сервер, а не опечатка библиотеки/LMS-плагина.
  mutation createPlayList($items: [PlaylistItem!]!, $name: String!) {
    playlist { create(items: $items, name: $name) }
  }
  # items: [{ "type": "track", "item_id": "<id>" }, ...] — можно передать [] при создании пустого плейлиста

  mutation addTracksToPlaylist($id: ID!, $items: [PlaylistItem!]!) {
    playlist { addItems(id: $id, items: $items) }
  }

  # operationName "updataPlaylist" (без "e") — тоже дословно так на сервере, не исправлять при переносе
  mutation updataPlaylist($id: ID!, $items: [PlaylistItem!]!, $isPublic: Boolean!, $name: String!) {
    playlist { update(id: $id, items: $items, isPublic: $isPublic, name: $name) }
  }

  mutation deletePlaylist($id: ID!) {
    playlist { delete(id: $id) }
  }

  # более точечные варианты вместо полного update — удобнее для мелких правок:
  mutation renamePlaylist($id: ID!, $name: String!) { playlist { rename(id: $id, name: $name) } }
  mutation setPlaylistToPublic($id: ID!, $isPublic: Boolean!) { playlist { setPublic(id: $id, isPublic: $isPublic) } }
  ```
- Полный `getPlaylists` (не «short») дополнительно содержит `userId`, `isDeleted`, `shared`, `updated` — пригодится, если понадобится определять «мой это плейлист или нет» (как в `parsers.py:parse_playlist` через сравнение `user_id == provider.client.user_id`) — сейчас в LMS такого разделения нет, все плейлисты в «Моих плейлистах» показываются одинаково.
- **Важно про удаление треков:** отдельной мутации «удалить N треков по ID» нет — только `update(id, items, isPublic, name)` с **полным новым списком items**. Ma-provider из-за этого вынужден вычитывать до 10 000 треков плейлиста, чтобы отфильтровать удаляемые и переотправить остаток (`constants.py:PLAYLIST_TRACK_FETCH_LIMIT`) — при переносе в LMS иметь это ограничение в виду и не тянуть весь плейлист бездумно для больших плейлистов.
- В LMS UX ограничен (нет диалога ввода имени в старых интерфейсах; в Material/Default можно через `type => 'search'` как поле ввода). Минимальный сценарий: «Сохранить GigaMix как плейлист» (`createPlayList` с `items` = уже сгенерированные треки) — это самое естественное применение и киллер-фича, и она не требует read-modify-write всего плейлиста, в отличие от удаления треков.
- **Оценка:** 3–5 дней.

### P3.2 Importer / Online Music Library

- **Что:** синхронизация коллекции (артисты/альбомы/треки/плейлисты) в «Мою музыку» LMS — эквивалент library-синхронизации MA (`get_library_*`).
- **Как:** стандартный паттерн LMS: `Importer.pm` + `API/Sync.pm` (синхронный HTTP для контекста сканера!), `Slim::Music::Import->addImporter`, `needsUpdate`. Заимствовать у MA принцип батчей по 50 ID (`provider.py:_iter_batched`) — не тянуть всю коллекцию одним запросом.
- **Оценка:** 5–8 дней (самая крупная задача; требует знания scanner-контекста LMS).

### P3.3 Fallback stream-endpoint + надёжность FLAC

- **Точный подтверждённый вызов** (`zvuk_music/client_async.py:379–402`):
  ```
  GET https://zvuk.com/api/tiny/track/stream?id=<id>&quality=mid|high|flac
  → { "result": { "stream": "https://..." } }
  ```
  (не GraphQL). Добавить как запасной источник URL, когда основной GraphQL-запрос `getStream` не даёт нужного качества (см. §2.2), и перенять правило «has_flac ненадёжен — всегда пробовать `flac` первым при lossless-настройке, даже если `hasFlac=false`».
- **Дополнительно проверено:** сам GraphQL-запрос `getStream` (`zvuk_music/graphql/queries/getStream.graphql`) в актуальной версии библиотеки запрашивает у `stream` только поля `expire expireDelta flacdrm high mid` — **поля `flac` там нет вообще**, только `flacdrm` (DRM-обёрнутый). Это расходится с существующим запросом в `API/Async.pm:438–453`, который просит `stream { high mid flac flacdrm }`. Если продакшен-схема Zvuk действительно не содержит поле `flac` в этом типе (что и объясняет, почему нужен tiny-эндпоинт как основной источник lossless, а не просто «fallback»), то часть кода в `ProtocolHandler.pm:107–117`, проверяющая `$stream->{flac}`, скорее всего никогда не срабатывает и весь FLAC-путь фактически идёт либо через `flacdrm` (что требует расшифровки — см. `docs/roadmap.md`, Stage 4, DRM пока не поддержан), либо не работает вовсе. **Это стоит перепроверить эмпирически на живом аккаунте** (не выполнимо в рамках этого анализа без доступа к токену) — если подтвердится, `/api/tiny/track/stream?quality=flac` становится не «доп. fallback», а **основным и единственным способом получить настоящий lossless без DRM**, и приоритет этой задачи стоит поднять.
- **Оценка:** 1 день на сам fallback; +0.5 дня на верификацию гипотезы про мёртвый `stream.flac` на реальном аккаунте.

### P3.4 Гигиена кода (рекомендуется сделать до P1.4+; P0.1 уже покрывает пункт 2 ниже)

1. Вынести из Plugin.pm: Wave-UI → `WaveUI.pm`, GigaMix → `GigaMix.pm`, web/OAuth-хендлеры → `WebHandlers.pm`; удалить мёртвый wizard-код (строки ~1300–1617) или вынести в отдельный модуль.
2. ~~Оставить один механизм получения API-клиента~~ — см. **P0.1**, это не просто стиль, а источник реального бага переключения аккаунта.
3. Починить эпизоды подкастов: `_renderEpisode` должен отдавать `type => 'audio'` c `url => 'zvuk://episode:<id>'`, а ProtocolHandler — понимать этот вид ID (сейчас regex только `zvuk://(\d+)`).
4. Добавить пагинацию (Next page) в категории `handleRecommendationArtists/Albums/Playlists`, аналогично `_searchGeneric` (см. §3.2, пункт 2).
5. Завести юнит-тесты по методике `docs/TESTING_SLIM_MOCKING.md`, начиная с чистых модулей (Throttle, Retry, WaveSettings, `_getArtistName`). Ориентир покрытия — как в MA: parsers/рендеры + api-обёртка.
6. **Обновить/удалить `test/test_synthesis_playlists.pl` и `test/test_editorial_playlists.pl`** — оба скрипта содержат неподтверждённые (и, как выяснилось в §4, неверные) гипотезы об именах GraphQL-полей (`getShortPlaylist`/`getPlaylistsShort` как отдельные поля, вместо реального `getPlaylists`; GraphQL для editorial вместо реального REST `/api/tiny/grid/content`). Оставлять их как есть — значит вводить в заблуждение следующего разработчика, который откроет `test/GRAPHQL_TESTING_README.md` в поисках подсказки.

---

## 5. Что НЕ стоит заимствовать

- **Внешняя клиентская библиотека.** Для Perl/LMS нет экосистемного смысла выносить GraphQL-слой в CPAN-пакет; текущий `API/Async.pm` — правильный уровень абстракции. Достаточно поддерживать `docs/zvuk_api.md` как «контракт».
- **Синхронный fetch картинок с токеном (`resolve_image`).** В LMS картинки проксируются иначе; но **правило allowlist-хостов** учесть, если когда-либо будете добавлять авторизованные заголовки к запросам изображений.
- **Удаление треков перезаписью 10k-списка** — переносить только вместе с P3.1 и с ограничением размера.

---

## 6. Рекомендуемая последовательность (roadmap для исполнителя)

| Этап | Задачи | Суммарная оценка |
|---|---|---|
| 0 | **P0.1 + P0.2** (баги переключения аккаунта и Web UI Wave Settings) — делать первыми, до остального | ~1–1.5 дня |
| 1 | P3.4 (рефакторинг + фикс эпизодов + пагинация рекомендаций) → P1.1 (synthesis) → P1.3 (меню) | ~1 неделя |
| 2 | P1.2 (подборки) → P2.4 (ошибки/WAF) | ~1 неделя |
| 3 | P1.4 (лайки + InfoMenu) → P2.1 (лирика) → P2.2 (похожие/DSTM) | ~2 недели |
| 4 | P2.3 (метаданные) → P3.3 (stream fallback + верификация FLAC-гипотезы) → тесты | ~1 неделя |
| 5 (опц.) | P3.1 (плейлисты, «Сохранить GigaMix») → P3.2 (Importer/OMLI) → P2.5 (Blend-плейлист, разведка) | ~2–3 недели |

> **Примечание к этапу 4:** если ручная проверка гипотезы про отсутствующее поле `stream.flac` (см. P3.3) подтвердится на живом аккаунте, имеет смысл поднять `/api/tiny/track/stream` выше по приоритету (в этап 1–2) — это может быть текущий путь получения lossless-звука, а не просто резервный.

## 7. Справочные материалы для разработчика

- **`/home/chernysh/Projects/zvuk-music/`** (локальный чекаут библиотеки `zvuk-music`, той же версии, что подключает `ma-provider-zvuk-music` как `zvuk-music[async]==0.6.1`) — **основной источник всех точных тел GraphQL/REST-запросов**, использованных в этом отчёте:
  - `zvuk_music/graphql/queries/*.graphql`, `zvuk_music/graphql/mutations/*.graphql` — тела запросов один-в-один;
  - `zvuk_music/client_async.py` — какой файл к какому REST/GraphQL вызову относится, обработка ответа, URL-ы (`TINY_API_URL`);
  - `zvuk_music/enums.py` — точные строковые значения enum'ов (`CollectionItemType`, `StreamQuality`, `LyricsType`, `ReleaseType` и др.), которые обязательно понадобятся при формировании variables.
  - Перед реализацией любого пункта из §4 — сверяться с этими файлами напрямую, а не с пересказом в `provider.py`/`api_client.py` из ma-provider (та обёртка иногда переименовывает операции — см. путаницу `getShortPlaylist` в P1.1).
- `docs/zvuk_api.md`, `docs/architecture.md`, `docs/developer_guide.md`, `docs/DEVELOPER_ONBOARDING.md` — внутренняя документация lms-zvuk (учесть, что `docs/project_status.md` частично устарела — см. §3.2, пункт 9).
- `docs/TESTING_SLIM_MOCKING.md` — как тестировать Perl-модули без запущенного LMS.
- `test/GRAPHQL_TESTING_README.md` + скрипты — методика ручного исследования через curl/Perl (учтите WAF: запросы вне контекста плагина часто блокируются, нужны заголовки из `API.pm`: `x-app-name`, User-Agent, origin/referer); сами гипотезы в скриптах требуют обновления (см. P3.4.6).
- Референсные LMS-плагины стриминговых сервисов: TIDAL (`michaelherger/lms-plugin-tidal`), Qobuz, Deezer — паттерны InfoMenu, Importer, LastMix.
- LMS DEVELOPERS.md: https://github.com/LMS-Community/slimserver/blob/HEAD/DEVELOPERS.md — конвейер стриминга и кеш обложек.

## 8. Итоговый вывод

Проекты дополняют друг друга почти без пересечения слабых мест: **lms-zvuk силён в «умных» фичах Звука** (Волна, GigaMix, рекомендации, мультиаккаунт, OAuth-флоу) и в устойчивости запросов (throttle/retry/cache), а **ma-provider — в полноте CRUD-операций, контент-дискавери, метаданных и инженерной культуре** (тесты, слои, обработка ошибок). Наибольшую отдачу при минимальном риске дают P1-задачи: доделка synthesis-плейлистов (решение уже известно), editorial-подборки и лайки — все три имеют готовые эталоны в ma-provider/zvuk-music и не затрагивают конвейер воспроизведения.

Отдельно важно: в ходе анализа найдены **два независимых, конкретных бага корректности** в уже существующей флагманской фиче мультиаккаунта (§3.2.1, P0.1/P0.2) — переключение аккаунта не долетает до активного воспроизведения Волны из-за незачищаемого `pluginData('zvuk_api')`, а Web UI слайдеры Волны сохраняются под хардкодным ключом `'default'`, который не совпадает с ключом, используемым при реальном проигрывании. Оба воспроизводимы по коду (не требуют доступа к живому серверу для подтверждения) и не связаны с заимствованиями из ma-provider — рекомендуется чинить их первыми, до P1-фич, чтобы не тиражировать тот же паттерн (несинхронизированный `accountId`) в новых модулях (лайки, InfoMenu).

**Обновление после сверки с исходниками `zvuk-music`** (локально в `/home/chernysh/Projects/zvuk-music/`): почти все GraphQL/REST-«гипотезы» из первой версии этого отчёта и из тестовых скриптов `test/*.pl` в lms-zvuk оказались неточны и теперь заменены на точные, проверенные тела запросов — в частности, «Плейлисты для вас» реально получаются через поле `getPlaylists`, а не `getShortPlaylist`/`mediaContents`; «Подборки» — это REST-вызов Tiny API, а не GraphQL; лайки — одна универсальная пара мутаций на все типы контента, а не восемь отдельных; лирика — тоже REST. Дополнительно найдена не задействованная ни в одном из двух проектов фича «синтез-плейлист между двумя профилями» (§4, P2.5) — потенциальный уникальный козырь именно для мультиаккаунт-архитектуры lms-zvuk. Отдельно возникло подозрение (требует ручной проверки на живом аккаунте, см. P3.3), что поле `stream.flac` в существующем GraphQL-запросе `API/Async.pm:getStream` может не существовать в реальной схеме — если так, единственный путь к настоящему lossless без DRM — это tiny-эндпоинт `/api/tiny/track/stream?quality=flac`, а не «резервный» вариант, как было заявлено ранее.
