# Журнал выполнения задач модернизации плагина LMS Zvuk

**Ветка:** `experiment`  
**Дата старта:** 16.10.2026  
**Мастер-план:** `docs/SENIOR_PERL_GUIDE_AND_PLAN.md`  

---

## Статус выполнения по фазам

| Фаза | Описание | Статус | Коммиты |
|---|---|---|---|
| **Фаза 0.1** | Пакетный коммит: мелкие багфиксы, утечка памяти в Retry, гигиена и мёртвый код | ✅ Завершено | `5624759` |
| **Фаза 0.2** | Встраивание `_http_get` в конвейер `Throttle`/`Retry` | ✅ Завершено | `cb7eff9` |
| **Фаза 0.3** | Сохранение обратной связи Волны (`ProtocolHandler.pm`) | 🔍 Готово к проверке | - |
| **Фаза 0.4** | Асинхронный резолвинг `userId` в `WebHandlers.pm` | 📋 Запланировано | - |
| **Фаза 0.5** | Автоматический refresh токена при HTTP 401 (`/api/tiny/refresh`) | 📋 Запланировано | - |
| **Фаза 0.6** | Нативный вход по номеру телефона (SMS OTP) | 📋 Запланировано | - |
| **Фаза 1.1** | Потоковое радио по треку/артисту/альбому (`recommenderRadio`) | 📋 Запланировано | - |
| **Фаза 1.2** | Интеграция с плагином LMS «Don't Stop The Music» (DSTM) | 📋 Запланировано | - |
| **Фаза 1.3** | Синхронизированные тексты песен (Musixmatch) | 📋 Запланировано | - |
| **Фаза 1.4** | Эфирные цифровые радиостанции (`getRadioStations`) | 📋 Запланировано | - |
| **Фаза 2.1** | Модуль API «Атласа вкуса» (`API/Atlas.pm`) | 📋 Запланировано | - |
| **Фаза 2.2** | Потоковое воспроизведение волны острова (`zvuk://atlas:<id>`) | 📋 Запланировано | - |
| **Фаза 2.3** | Нативное гибридное меню Атласа в LMS (`AtlasUI.pm`) | 📋 Запланировано | - |
| **Фаза 2.4** | Интерактивный 2D-виджет карты вкуса (`atlasStandalone.html`) | 📋 Запланировано | - |
| **Фаза 3.1** | Корневой раздел «История прослушиваний» (`listeningRecentV1`) | 📋 Запланировано | - |
| **Фаза 3.2** | Корневой раздел «Подкасты и аудиокниги» с прогрессом глав | 📋 Запланировано | - |

---

## Детальный журнал операций

### [Фаза 0.1] Пакетный коммит: мелкие багфиксы, утечка памяти в Retry, гигиена и мёртвый код
* **Статус:** ✅ Завершено и закоммичено.
* **Ручная проверка пользователем:**
  - Корректность кодировки сообщений статуса получения анонимного токена проверена пользователем в веб-интерфейсе LMS: подтверждено, надписи отображаются корректно.
  - Проверка остальных фиксов фазы отложена пользователем на более поздний этап интеграционного тестирования.
* **Выполненные изменения:**
  1. `API.pm`: В `cacheTrackMetadata` исправлен преждевременный выход из подпрограммы: заменен `map { return $cached if $cached; ... }` на цикл `for my $track (@$tracks)` с накоплением `@result`. Теперь наличие первого закешированного трека не прерывает кеширование остальных треков в пакете.
  2. `HTML/EN/plugins/zvuk/settings/basic.html`: Удален ошибочный вызов Node.js/CommonJS `require('Plugins::Zvuk::API::Async')` из браузерной функции `getAnonymousToken()`, приводивший к `ReferenceError` в консоли браузера.
  3. `ProtocolHandler.pm`:
     - Удалена неиспользуемая константа `CAN_FLAC_SEEK`.
     - Добавлена проверка `$prefs->get('gigamix_autoplay')` перед автоматической подгрузкой следующего пакета треков GigaMix при приближении к концу очереди.
  4. `Retry.pm`: В подпрограмме `execute` разорвана циклическая ссылка (closure reference cycle) на саму себя через лексическую переменную `$run_operation`: добавлено явное обнуление `undef $run_operation;` перед вызовом завершающего колбэка при успехе, фатальной ошибке и исчерпании лимита попыток. Это предотвращает утечку памяти Perl-процесса LMS при долговременной работе.
  5. `WaveUI.pm` и `API/Async.pm`: Интенсивные отладочные логи (`=== ZVUK DEBUG _getWaveMenuItems ===`, `handleWaveSettingsRouter`, `getPersonalWave variables`) переведены с уровня `$log->warn` на уровень `$log->debug` с обязательной проверкой `$log->is_debug`. Лог LMS больше не засоряется предупреждениями при штатной навигации.
  6. Мёртвый код и маршрутизация:
     - Удален устаревший модуль `WaveWizardUI.pm` (замененный современным `WaveUI.pm`).
     - В `Plugin.pm` зарегистрирован недостающий raw-маршрут `plugins/zvuk/getWaveSettings` -> `\&Plugins::Zvuk::WebHandlers::handleGetWaveSettingsWeb`.
     - Удалены неиспользуемые мертвые хелперы `_renderArtistItem`, `_renderReleaseItem`, `_renderPlaylistItem` в `Plugin.pm`.
     - Из `t/reproduce_p0_multiaccount_bugs.pl` удален неиспользуемый `require Plugins::Zvuk::WaveWizardUI;`.
  7. Гигиена секретов и тесты:
     - В `test/test_editorial_real.pl` и `test/test_editorial_real.sh` жестко зашитый токен заменен на чтение из переменной окружения `$ENV{ZVUK_TOKEN}`.
     - Добавлен новый модульный регрессионный тест `t/test_cache_batch.pl`, проверяющий корректное пакетирование треков при кешировании метаданных без досрочного прерывания.
     - В `t/slim_mocks.pl` добавлен метод `clear` и пакетная видимость `our %CACHE` для независимости сценариев тестов.
  8. Кодировка и локализация интерфейса:
     - В `HTML/EN/plugins/zvuk/settings/basic.html` заменены жестко зашитые кириллические строки статуса анонимного токена на штатные макросы локализации Template Toolkit: `[% "PLUGIN_ZVUK_ANONYMOUS_LOADING" | string %]`, `[% "PLUGIN_ZVUK_ANONYMOUS_SUCCESS" | string %]` и `[% "PLUGIN_ZVUK_ANONYMOUS_ERROR" | string %]`, зарегистрированные в словаре `zvukStrings`. Устранено появление «кракозябр» / искаженных символов UTF-8 при нажатии кнопки.
     - В `WebHandlers.pm` (`handleOAuthCallback`) добавлено явное кодирование HTML в UTF-8 октеты (`encode_utf8`) перед расчетом `content_length` во избежание несовпадения длины символов и байтов.
* **Результаты тестов:**
  - 11/11 наборов тестов успешно выполнены (121 assertion ok):
    - `t/test_album_context_menu.pl` (25/25 ok)
    - `t/test_cache_batch.pl` (11/11 ok)
    - `t/test_editorial_playlists.pl` (ok)
    - `t/test_episode_playback.pl` (ok)
    - `t/test_graphql_error_classification.pl` (ok)
    - `t/test_multi_page_recommendations.pl` (ok)
    - `t/test_recommendations_menu.pl` (ok)
    - `t/test_synthesis_playlists.pl` (ok)
    - `t/test_timer_absolute_time.pl` (ok)
    - `t/test_vfd_genres_knob.pl` (ok)
    - `t/reproduce_p0_multiaccount_bugs.pl` (ok)

### [Фаза 0.2] Встраивание `_http_get` в конвейер `Throttle`/`Retry`
* **Статус:** ✅ Завершено и закоммичено.
* **Ручная проверка пользователем:** Успешно проверена на работающем LMS сервере, всё ОК.
* **Выполненные изменения:**
  1. `API/Async.pm` (`_http_get`):
     - Встроен общий троттлинг `$throttler->acquire` (5 req/sec), объединенный с очередью GraphQL. Теперь REST-запросы (включая будущий Атлас, подборки Grid API и проверку профиля) больше не вызывают HTTP 418 rate-limit бан со стороны WAF Servicepipe.
     - Встроен автоматический ретрай `$retry_mgr->execute` (экспоненциальный бэкофф, 5 попыток) на транзиентные сбои (HTTP 502/503/504, сетевые таймауты).
     - Добавлена классификация ошибок: HTTP 400/401/403/404 не ретраятся впустую и сразу отдаются в колбэк.
     - Добавлена поддержка опционального кеширования ответов REST по TTL (`$opts->{ttl}`) в централизованный `Plugins::Zvuk::API->cache`.
     - Добавлена детерминированная сортировка параметров query (`sort keys %$params`) для консистентных ключей кеша.
     - Добавлена передача кастомных заголовков через `$opts->{headers}` (необходимо для `Cookie: auth=<token>; in_webkit=true` в Атласе).
  2. `API/Async.pm` (`getProfile`):
     - Метод класса `getProfile` переведен на вызов `_http_get` с передачей `{ headers => { 'x-auth-token' => $token } }`. Теперь валидация токена пользователя при входе также защищена очередью троттлинга и повторами при кратковременных сбоях сети.
  3. `t/test_http_get.pl`:
     - Создан новый комплексный тестовый сьют, проверяющий:
       - корректное формирование URL и сортировку параметров,
       - передачу токена и User-Agent,
       - работу кеширования при наличии `ttl`,
       - восстановление после транзиентного сбоя HTTP 503 через ретрай,
       - мгновенную обработку ошибки HTTP 400 без лишних повторов,
       - делегирование метода `getProfile` в общий конвейер `_http_get`.
* **Результаты тестов:**
  - 12/12 тестовых сьютов успешно пройдены без ошибок:
    - `t/test_http_get.pl` (6 сценариев, 18 проверок - все ok)
    - `t/test_cache_batch.pl` (ok)
    - `t/test_album_context_menu.pl` (ok)
    - `t/test_editorial_playlists.pl` (ok)
    - `t/test_episode_playback.pl` (ok)
    - `t/test_graphql_error_classification.pl` (ok)
    - `t/test_multi_page_recommendations.pl` (ok)
    - `t/test_recommendations_menu.pl` (ok)
    - `t/test_synthesis_playlists.pl` (ok)
    - `t/test_timer_absolute_time.pl` (ok)
    - `t/test_vfd_genres_knob.pl` (ok)
    - `t/reproduce_p0_multiaccount_bugs.pl` (ok)

### [Фаза 0.3] Сохранение контекста и обратной связи Волны (`ProtocolHandler.pm`)
* **Статус:** 🟢 Выполнено и подтверждено пользователем (коммит `b464d0c`).
* **Коммит:** `b464d0c` (`feat(wave): implement wave feedback loop and last track tracking (Phase 0.3)`)
* **Выполненные изменения:**
  1. `ProtocolHandler.pm`:
     - В `getNextTrack` при старте воспроизведения трека Волны (`zvuk_wave_active`) сохраняется состояние текущего трека в `$client->pluginData(zvuk_wave_last_track => { id => $id, started => time(), duration => $duration })`.
     - В `_loadMoreWaveTracks` вычисленный объект `$content_input` (`trackId`, `trackDuration`, `playDuration`, `isSkipped`) теперь реально передается аргументом в `$api->getPersonalWave(..., $wave_settings, $content_input)`.
     - При запуске новой Волны (`_explodeWave`) состояние `zvuk_wave_last_track` явно сбрасывается в `undef`.
  2. `API/Async.pm` (`getPersonalWave`):
     - Сигнатура расширена до `($self, $cb, $wave_settings, $content_input)`.
     - Если `$content_input` передан, переменная `$vars->{contentInput}` включается в GraphQL-запрос к Звуку. Алгоритм рекомендаций Звука теперь получает информацию о дослушивании/скипе предыдущего трека.
  3. `Plugin.pm` (`_onStop`):
     - При остановке воспроизведения (`stop`) или очистке плейлиста (`playlist clear`) состояние `zvuk_wave_last_track` сбрасывается в `undef`.
  4. `t/test_wave_feedback.pl`:
     - Создан новый тестовый сьют (5 сценариев, 15 проверок), верифицирующий:
       - отсутствие `contentInput` при первичном запросе волны,
       - передачу `contentInput` со всеми полями (`trackId`, `trackDuration`, `playDuration`, `isSkipped`),
       - запись `zvuk_wave_last_track` в `getNextTrack`,
       - корректный расчет флага пропуска `isSkipped` (true при прослушивании менее 50% длительности трека),
       - очистку состояния при остановке воспроизведения в `_onStop`.
* **Результаты тестов:**
  - 13/13 тестовых сьютов успешно пройдены без ошибок:
    - `t/test_wave_feedback.pl` (ok)
    - `t/test_http_get.pl` (ok)
    - `t/test_cache_batch.pl` (ok)
    - `t/test_album_context_menu.pl` (ok)
    - `t/test_editorial_playlists.pl` (ok)
    - `t/test_episode_playback.pl` (ok)
    - `t/test_graphql_error_classification.pl` (ok)
    - `t/test_multi_page_recommendations.pl` (ok)
    - `t/test_recommendations_menu.pl` (ok)
    - `t/test_synthesis_playlists.pl` (ok)
    - `t/test_timer_absolute_time.pl` (ok)
    - `t/test_vfd_genres_knob.pl` (ok)
    - `t/reproduce_p0_multiaccount_bugs.pl` (ok)

### [Фаза 0.4] Асинхронный резолвинг `userId` и имени аккаунта (`WebHandlers.pm`, `API.pm`, `Settings.pm`)
* **Статус:** 🟢 Выполнено и подтверждено пользователем (коммит `4472b5d`).
* **Коммит:** `4472b5d` (`fix(oauth): resolve real userId and account name asynchronously on token save (Phase 0.4)`)
* **Выполненные изменения:**
  1. `API.pm`:
     - Добавлен централизованный метод `extractAccountName($profile, $userId)` для консистентного извлечения отображаемого имени пользователя (приоритет: ФИО из `external_profile` ➔ простое поле `name` ➔ `username` ➔ `Account <id>`).
  2. `Settings.pm`:
     - Вызов ручного сохранения аккаунта переведен на единый метод `Plugins::Zvuk::API->extractAccountName`.
  3. `WebHandlers.pm` (`handleSaveOAuthToken`):
     - Устранено синхронное сохранение временного фейкового `tempUserId = substr($token, 0, 16)`.
     - Реализован асинхронный вызов `Plugins::Zvuk::API::Async->getProfile` с токеном.
     - После успешного ответа Звука аккаунт сохраняется с **настоящим числовым `userId`** и человекочитаемым именем (например, «Александр Черныш»).
     - Выполняется автоматическая очистка устаревших временных записей `tempUserId` из настроек при обновлении или входе.
     - Если к устаревшему `tempUserId` были привязаны плееры LMS (`client->userId`) или он был выбран по умолчанию (`defaultUserId`), они автоматически мигрируются на реальный `userId`.
     - JSON-ответ клиенту кодируется с `JSON::XS->new->utf8(1)->canonical(1)`, что предотвращает искажения кодировки и гарантирует корректный заголовок `Content-Length`.
     - При невалидном токене или сбое профиля возвращается понятная ошибка HTTP 400 без засорения настроек плагина.
  4. `t/slim_mocks.pl`:
     - Добавлен метод `clients` в мок `Slim::Player::Client` для корректного тестирования миграции плееров.
  5. `t/test_oauth_user_id.pl`:
     - Создан новый тестовый сьют (24 проверки), полностью верифицирующий:
       - логику извлечения имени во всех 4 вариантах профиля,
       - отклонение невалидных токенов (HTTP 400),
       - асинхронный резолвинг реального `userId` и имени при успешной авторизации,
       - корректное сохранение в преференсы `accounts` под реальным ID,
       - удаление легаси-записи `tempUserId` и миграцию подключенных плееров,
       - корректную обработку сетевых ошибок и HTTP 401 без сохранения мусора.
* **Результаты тестов:**
  - 14/14 тестовых сьютов успешно пройдены без ошибок:
    - `t/test_oauth_user_id.pl` (24 проверки - ok)
    - `t/test_wave_feedback.pl` (18 проверок - ok)
    - `t/test_http_get.pl` (19 проверок - ok)
    - `t/test_cache_batch.pl` (11 проверок - ok)
    - `t/test_album_context_menu.pl` (25 проверок - ok)
    - `t/test_editorial_playlists.pl` (6 проверок - ok)
    - `t/test_episode_playback.pl` (7 проверок - ok)
    - `t/test_graphql_error_classification.pl` (6 проверок - ok)
    - `t/test_multi_page_recommendations.pl` (17 проверок - ok)
    - `t/test_recommendations_menu.pl` (11 проверок - ok)
    - `t/test_synthesis_playlists.pl` (6 проверок - ok)
    - `t/test_timer_absolute_time.pl` (11 проверок - ok)
    - `t/test_vfd_genres_knob.pl` (14 проверок - ok)
    - `t/reproduce_p0_multiaccount_bugs.pl` (ok)

### [Фаза 0.5] Автоматический Refresh токена при HTTP 401 (`API/Async.pm`, `API.pm`, `Settings.pm`, `basic.html`, `strings.txt`)
* **Статус:** 🟢 Реализовано, протестировано (15/15 наборов тестов успешно пройдены, включая новый сьют `t/test_token_refresh.pl` из 29 проверок). Ожидает подтверждения ручной проверки перед коммитом.
* **Выполненные изменения:**
  1. `API.pm`:
     - Добавлена константа `REFRESH_URL => 'https://zvuk.com/api/tiny/refresh'`.
  2. `API/Async.pm`:
     - Реализован метод `refreshToken($self, $cb, $explicitToken)`:
       - Выполняет HTTP POST к `https://zvuk.com/api/tiny/refresh` с заголовками `x-auth-token`, `x-c-p: Q`, `user-agent`, `content-type: application/json`.
       - Реализована дедупликация и коалесцирование конкурентных запросов на обновление (`%refreshInFlight`): если несколько параллельных запросов получают 401 одновременно, на сервер Звука отправляется ровно один POST refresh, а все ожидающие колбэки оповещаются полученным токеном.
       - При успешном обновлении сохраняет новый токен в `accounts->{$userId}->{token}` и сбрасывает флаг `stale => 0`.
       - При постоянной ошибке (HTTP 401/403 на самом refresh) помечает аккаунт флагом `stale => 1` («Требуется повторный вход»).
     - В метод `_graphql` встроен прозрачный интерцептор 401:
       - Перехватывает как HTTP 401 от транспортного уровня, так и ошибки `UNAUTHENTICATED`/`UNAUTHORIZED` в теле ответа GraphQL при коде 200.
       - Проверяет флаг `!$opts->{refreshed}` (защита от зацикливания).
       - Вызывает `refreshToken`, при успехе автоматически повторяет исходный GraphQL запрос с новым токеном.
     - В метод `_http_get` встроен аналогичный прозрачный интерцептор 401 с автоматическим обновлением заголовка `x-auth-token` и повтором REST-запроса.
  3. `Settings.pm` и `HTML/EN/plugins/zvuk/settings/basic.html`:
     - В список аккаунтов веб-интерфейса настроек добавлена передача флага `stale`.
     - При `stale == 1` рядом с именем аккаунта выводится предупреждение: `([% "PLUGIN_ZVUK_AUTH_EXPIRED" | string %])`.
  4. `strings.txt`:
     - Добавлен ключ локализации `PLUGIN_ZVUK_AUTH_EXPIRED` (EN/RU: «Срок авторизации истёк. Требуется повторный вход в настройках плагина.»).
  5. `t/slim_mocks.pl`:
     - Расширен мок `Slim::Networking::SimpleAsyncHTTP` поддержкой `@PENDING_CALLS` и флага `defer => 1` для детерминированного тестирования асинхронной конкурентности.
  6. `t/test_token_refresh.pl`:
     - Создан новый тестовый сьют (6 сценариев, 29 проверок), верифицирующий:
       - прямой вызов `refreshToken` с успешной ротацией токена и проверкой заголовков (`X-C-P: Q`),
       - коалесцирование 3 одновременных вызовов в ровно 1 HTTP POST,
       - корректную установку флага `stale => 1` при сбое refresh,
       - автоматический перехват 401 в `_graphql` с ретраем и возвратом данных,
       - автоматический перехват GraphQL-ошибок `UNAUTHENTICATED` при HTTP 200,
       - автоматический перехват 401 в REST GET (`_http_get`) с ретраем и возвратом данных.
* **Результаты тестов:**
  - 15/15 тестовых сьютов успешно пройдены без ошибок:
    - `t/test_token_refresh.pl` (29 проверок - ok)
    - `t/test_oauth_user_id.pl` (24 проверки - ok)
    - `t/test_wave_feedback.pl` (18 проверок - ok)
    - `t/test_http_get.pl` (19 проверок - ok)
    - `t/test_cache_batch.pl` (11 проверок - ok)
    - `t/test_album_context_menu.pl` (25 проверок - ok)
    - `t/test_editorial_playlists.pl` (6 проверок - ok)
    - `t/test_episode_playback.pl` (7 проверок - ok)
    - `t/test_graphql_error_classification.pl` (6 проверок - ok)
    - `t/test_multi_page_recommendations.pl` (17 проверок - ok)
    - `t/test_recommendations_menu.pl` (11 проверок - ok)
    - `t/test_synthesis_playlists.pl` (6 проверок - ok)
    - `t/test_timer_absolute_time.pl` (11 проверок - ok)
    - `t/test_vfd_genres_knob.pl` (14 проверок - ok)
    - `t/reproduce_p0_multiaccount_bugs.pl` (ok)
