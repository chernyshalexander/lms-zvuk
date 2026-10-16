# Журнал выполнения задач модернизации плагина LMS Zvuk

**Ветка:** `experiment`  
**Дата старта:** 16.10.2026  
**Мастер-план:** `docs/SENIOR_PERL_GUIDE_AND_PLAN.md`  

---

## Статус выполнения по фазам

| Фаза | Описание | Статус | Коммиты |
|---|---|---|---|
| **Фаза 0.1** | Пакетный коммит: мелкие багфиксы, утечка памяти в Retry, гигиена и мёртвый код | ✅ Завершено | `5624759` |
| **Фаза 0.2** | Встраивание `_http_get` в конвейер `Throttle`/`Retry` | ✅ Завершено | [commit] |
| **Фаза 0.3** | Сохранение обратной связи Волны (`ProtocolHandler.pm`) | 📋 Запланировано | - |
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
