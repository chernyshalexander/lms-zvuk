# Чек-лист ручного тестирования Personal Wave Settings

**Дата:** 2026-05-20  
**Ветка:** experiment  
**Статус код-базы:** 6 commits, готово к тестированию

---

## Предусловия

- ✅ LMS запущен и работает
- ✅ Zvuk плагин установлен
- ✅ Jive устройство подключено (Touch, Squeezeplay, Radio, Boom)
- ✅ Zvuk аккаунт сконфигурирован
- ✅ Логи LMS доступны (для проверки debug сообщений)

---

## Часть 1: Структура меню

### 1.1 Проверить наличие Personal Wave в меню

**Действие:**
1. На Jive устройстве: Plugins → Zvuk
2. Должно быть "Personal Wave"

**Ожидание:**
```
Personal Wave
├ Start Wave
└ Settings
```

**Результат:** ✅ / ❌

**Логирование:** Если "Settings" нет — возможно синтаксическая ошибка в Plugin.pm

---

### 1.2 Открыть меню Settings

**Действие:**
1. Нажать "Settings"
2. Должно открыться подменю

**Ожидание:**
```
Settings
├ Popularity
├ Mood: Energy
├ Mood: Fun
├ Language
├ Vocal
└ Genres
```

**Результат:** ✅ / ❌

**Если элементы отсутствуют:**
- Проверить strings.txt на наличие всех PLUGIN_ZVUK_SETTING_* строк
- Проверить синтаксис меню в Plugin.pm (скобки, запятые)

---

## Часть 2: Слайдеры (Popular, Energy, Fun)

### 2.1 Открыть Popularity слайдер

**Действие:**
1. Settings → Popularity
2. Должно открыться меню слайдера

**Ожидание:**
- Слайдер или text input (0-1)
- Текущее значение: 0.5 (дефолт)

**Результат:** ✅ / ❌

---

### 2.2 Изменить Popularity на 0.3

**Действие:**
1. Settings → Popularity
2. Изменить значение с 0.5 на 0.3
3. Подтвердить (нажать OK или выход)

**Проверка в логах LMS:**
```bash
tail -f /path/to/lms/logs/plugin.zvuk.log | grep "Wave setting"
```

**Ожидание в логах:**
```
Wave setting updated: popular = 0.3
```

**Результат:** ✅ / ❌

**Если сообщения нет:**
- Проверить что _updateSetting вызывается (добавить debug в Plugin.pm)
- Проверить доступность logger('plugin.zvuk')

---

### 2.3 Вернуться в Settings и проверить что Popularity = 0.3

**Действие:**
1. Settings → Popularity (повторно открыть)
2. Проверить что значение 0.3, а не 0.5

**Ожидание:**
- Слайдер показывает 0.3 (сохранилось!)

**Результат:** ✅ / ❌

**Если значение 0.5:**
- Preferences не сохраняются → проверить saveSettings в WaveSettings.pm
- Проверить что WaveSettings используется правильно

---

### 2.4 Проверить Energy и Fun слайдеры

**Повторить 2.1-2.3 для:**
- Energy: установить 0.7
- Fun: установить 0.6

**Логирование:** должно быть 3 сообщения об обновлении

```
Wave setting updated: popular = 0.3
Wave setting updated: energy = 0.7
Wave setting updated: fun = 0.6
```

**Результат:** Energy ✅ / ❌, Fun ✅ / ❌

---

## Часть 3: Выбор (Language, Vocal)

### 3.1 Выбрать Language = Foreign

**Действие:**
1. Settings → Language
2. Выбрать "Foreign"

**Ожидание в логах:**
```
Wave setting updated: language = foreign
```

**Результат:** ✅ / ❌

---

### 3.2 Проверить что Language = Foreign сохранилось

**Действие:**
1. Settings → Language (повторно)
2. Проверить что "Foreign" выбран

**Результат:** ✅ / ❌

---

### 3.3 Выбрать Vocal = Instrumental (Without)

**Действие:**
1. Settings → Vocal
2. Выбрать "Instrumental" (Without Vocals)

**Ожидание в логах:**
```
Wave setting updated: vocal = 0
```

**Результат:** ✅ / ❌

**Примечание:** vocal = 0 значит "без вокала", vocal = 1 значит "с вокалом"

---

## Часть 4: Жанры (Genres)

### 4.1 Открыть меню Genres

**Действие:**
1. Settings → Genres
2. Должен открыться список с чекбоксами

**Ожидание:**
```
Genres
☑ Easy Listening / Ambient
☑ Electronic
☑ Classical
☑ Folk / World / Country
☑ Hip-Hop
☑ Indie
☑ Instrumental / Acoustic
☑ Metal
☑ Pop
☑ Rock
☑ Soundtrack
```

**Все по умолчанию выбраны (☑)**

**Результат:** ✅ / ❌

**Если жанры не видны:**
- Проверить strings.txt на PLUGIN_ZVUK_GENRE_* строки
- Проверить getGenres() в WaveSettings.pm

---

### 4.2 Отключить все кроме Rock и Metal

**Действие:**
1. Genres → Rock (оставить ☑)
2. Genres → Metal (оставить ☑)
3. Все остальные → отключить (☐)
4. Вернуться в Settings

**Ожидание в логах:**
Много сообщений:
```
Genre toggled: easy_listening_ambient = 0
Genre toggled: electronic = 0
...
Genre toggled: rock = 1
Genre toggled: metal = 1
```

**Результат:** ✅ / ❌

---

### 4.3 Проверить что только Rock и Metal остались выбраны

**Действие:**
1. Settings → Genres (повторно)
2. Проверить что только Rock и Metal отмечены

**Результат:** ✅ / ❌

---

## Часть 5: Запуск Personal Wave с кастомными параметрами

### 5.1 Вернуться в Personal Wave главное меню

**Действие:**
1. Нажать кнопку "Назад" несколько раз или вернуться на уровень Personal Wave
2. Должны видеть "Start Wave" и "Settings"

---

### 5.2 Запустить волну с настроенными параметрами

**Действие:**
1. Personal Wave → Start Wave
2. Волна должна начать воспроизведение

**Ожидание в логах:**
```
Loading Personal Wave
Got 3 wave tracks
```

**И самое главное — проверить что getPersonalWave вызвана с правильными параметрами:**

Включить DEBUG режим в API/Async.pm (добавить строку перед _graphql):
```perl
$log->info("Wave settings: popular=$wave_settings->{popular}, "
          . "language=$wave_settings->{language}, "
          . "genres=" . join(',', @{$wave_settings->{genres} || []}) );
```

**Ожидание в логах:**
```
Wave settings: popular=0.3, language=foreign, genres=rock,metal
```

**Результат:** ✅ / ❌

---

### 5.3 Проверить что волна играет

**Действие:**
1. Убедиться что музыка играет
2. Прослушать 1-2 трека полностью
3. Пропустить 1 трек (нажать "Next" сразу)

**Ожидание:**
- Музыка воспроизводится без ошибок
- Dozagurka загружает новые треки когда приближаетесь к концу плейлиста

**В логах:**
```
Dozagurka loaded 3 more tracks
```

**Результат:** ✅ / ❌

---

## Часть 6: Проверка persistence (сохранение между сеансами)

### 6.1 Остановить волну

**Действие:**
1. Нажать Stop или вернуться в главное меню
2. Волна должна остановиться

**Ожидание в логах:**
```
zvuk_wave_active flag cleared
```

**Результат:** ✅ / ❌

---

### 6.2 Запустить волну снова

**Действие:**
1. Personal Wave → Start Wave (снова)

**Ожидание:**
- Волна запускается с теми же параметрами (popular=0.3, language=foreign, genres=rock,metal)

**В логах должно быть:**
```
Wave settings: popular=0.3, language=foreign, genres=rock,metal
```

**Результат:** ✅ / ❌

**Если параметры не сохранились:**
- Проверить что preferences работают
- Проверить loadSettings получает правильный account_id

---

## Часть 7: Полный цикл

### 7.1 Изменить все параметры (разные от дефолта)

**Популярность:** 0.8 (было 0.3)  
**Energy:** 0.2 (было 0.7)  
**Fun:** 0.9 (было 0.6)  
**Language:** Russian (было foreign)  
**Vocal:** With (было Without, т.е. 1 вместо 0)  
**Genres:** Pop, Classical (было Rock, Metal)

**Логирование:**
```
Wave setting updated: popular = 0.8
Wave setting updated: energy = 0.2
Wave setting updated: fun = 0.9
Wave setting updated: language = russian
Wave setting updated: vocal = 1
Genre toggled: rock = 0
Genre toggled: metal = 0
Genre toggled: pop = 1
Genre toggled: classical = 1
```

**Результат:** ✅ / ❌

---

### 7.2 Запустить волну и проверить параметры в логах

**Действие:**
1. Personal Wave → Start Wave

**Ожидание в логах:**
```
Wave settings: popular=0.8, language=russian, genres=classical,pop
```

**Примечание:** genres отсортированы по алфавиту (classical перед pop)

**Результат:** ✅ / ❌

---

## Итоговый отчет

**Заполнить после тестирования:**

| Часть | Тест | Результат | Заметки |
|-------|------|-----------|---------|
| 1.1 | Структура меню | ✅/❌ | |
| 1.2 | Settings подменю | ✅/❌ | |
| 2.1-2.4 | Слайдеры (Popular, Energy, Fun) | ✅/❌ | |
| 3.1-3.3 | Выбор (Language, Vocal) | ✅/❌ | |
| 4.1-4.3 | Жанры | ✅/❌ | |
| 5.1-5.3 | Запуск волны | ✅/❌ | |
| 6.1-6.2 | Persistence | ✅/❌ | |
| 7.1-7.2 | Полный цикл | ✅/❌ | |

**Итого пройдено:** __/8 частей

---

## Возможные проблемы и решения

### "Settings меню не появляется"
1. Проверить синтаксис Plugin.pm (скобки, запятые)
2. Проверить что WaveSettings.pm подключен: `use Plugins::Zvuk::WaveSettings;`
3. Перезагрузить LMS: `systemctl restart logitechmediaserver`

### "Параметры не сохраняются"
1. Проверить что saveSettings вызывается: добавить $log->info в _updateSetting
2. Проверить что preferences работают: закомментировать код и вызвать вручную
3. Проверить права доступа к папке preferences LMS

### "Волна не запускается"
1. Проверить что getPersonalWave получает правильный account_id
2. Проверить логи API запросов (может быть проблема с авторизацией)
3. Запустить базовый тест: `perl t/wave_settings_test.pl`

### "Не видно логов в LMS"
1. Включить debug logging: LMS Settings → Log Level → Debug
2. Найти файл логов: `/var/log/lms/plugin.zvuk.log` или `/opt/logitechmediaserver/logs/`
3. Добавить print для вывода в STDOUT: `print STDERR "DEBUG: $msg\n";`

---

## По завершению тестирования

1. ✅ Если все тесты пройдены:
   - Выполнить Task 8 (тестирование с несколькими аккаунтами, если есть)
   - Выполнить Task 9 (final verification)
   - Подготовить PR к merge

2. ❌ Если есть ошибки:
   - Документировать точное описание проблемы
   - Предоставить логи с ошибками
   - Проверить точный шаг где произошла ошибка

