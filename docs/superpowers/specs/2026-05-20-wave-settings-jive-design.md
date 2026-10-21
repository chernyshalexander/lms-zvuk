# Дизайн: Интерактивные настройки Personal Wave (Jive интерфейсы)

**Дата:** 2026-05-20  
**Статус:** Дизайн для утверждения  
**Целевые интерфейсы:** Jive (Squeezeplay, Touch, Radio), Squeezebox Classic, Boom

---

## Краткое описание

Добавить меню конфигурации параметров Personal Wave перед запуском волны. Пользователь может настроить популярность, mood (energy, fun), язык, вокал и жанры. Параметры сохраняются в preferences (привязаны к аккаунту) и используются при каждом запуске волны.

---

## Требования

### Функциональные требования

1. **Меню конфигурации Волны** (одноуровневое)
   - Пункт "Start Wave" → запускает волну с текущими параметрами
   - Пункт "Settings" → подменю с параметрами

2. **Параметры конфигурации**
   - **Popular** (слайдер 0.0–1.0, дефолт 0.5)
   - **Energy** (слайдер 0.0–1.0, дефолт 0.5)
   - **Fun** (слайдер 0.0–1.0, дефолт 0.5)
   - **Language** (выбор: All / Foreign / Russian, дефолт All)
   - **Vocal** (выбор: With / Without, дефолт With)
   - **Genres** (список с чекбоксами, дефолт все выбраны)

3. **Сохранение параметров**
   - Сохраняются в `preferences` сразу при изменении (без диалога подтверждения)
   - Привязаны к аккаунту (ключ: `wave_settings_{account_id}`)
   - Загружаются при инициализации плагина/выбора аккаунта
   - Используются в следующем запросе getPersonalWave

4. **Передача параметров в API**
   - При запуске волны параметры передаются в getPersonalWave()
   - Формируют часть `options` в GraphQL запросе

### Функциональность Jive интерфейсов

- Слайдеры для Popular, Energy, Fun (нативные диалоги Jive)
- Выбор для Language, Vocal (нативные диалоги Jive)
- Чекбоксы для Genres (диалог с множественным выбором)

---

## Архитектура

### 1. Структура Preferences

```perl
# Ключ в preferences: "wave_settings_<account_id>"
# Значение:
{
    popular => 0.5,           # float 0.0-1.0
    energy  => 0.5,           # float 0.0-1.0
    fun     => 0.5,           # float 0.0-1.0
    language => "all",        # "all" | "foreign" | "russian"
    vocal   => 1,             # 1 = with vocals, 0 = without
    genres  => [              # array of genre names
        "easy_listening_ambient",
        "electronic",
        "classical",
        "folk_world_country",
        "hip_hop",
        "indie",
        "instrumental_acoustic",
        "metal",
        "pop",
        "rock",
        "soundtrack"
    ],
}
```

### 2. Меню структура (Plugin.pm)

**Текущее меню:**
```
Personal Wave (type: 'audio', url: 'zvuk://wave')
```

**Новое меню:**
```
Personal Wave (type: 'link')
├ Start Wave (type: 'audio', url: 'zvuk://wave')
└ Settings (type: 'link', submenu)
   ├ Popular (type: 'input' slider)
   ├ Energy (type: 'input' slider)
   ├ Fun (type: 'input' slider)
   ├ Language (type: 'select')
   ├ Vocal (type: 'select')
   └ Genres (type: 'checkbox' list)
```

### 3. Компоненты

#### Plugin.pm
- Расширить метод меню на основе текущей волны/аккаунта
- Добавить обработчик для диалогов параметров
- Интеграция с preferences загрузки/сохранения

#### ProtocolHandler.pm
- Загружать параметры из preferences в `_explodeWave()`
- Передавать параметры в `getPersonalWave()`
- Сохранять параметры в pluginData текущего клиента

#### API/Async.pm
- Принимать параметры в `getPersonalWave($cb, $options)`
- Формировать `$vars->{options}` на основе переданных параметров
- Преобразовать mood в строку: `"energy:X,fun:Y"`

#### Strings.txt (локализация)
- Добавить строки меню, описания, значения параметров

### 4. Поток пользователя

```
1. Открывает "Personal Wave" → видит "Start Wave" и "Settings"
2. Нажимает "Settings" → подменю с параметрами
3. Выбирает "Popular" → диалог слайдера (0.0-1.0)
4. Меняет значение → СРАЗУ сохраняется в preferences
5. Диалог закрывается, возвращается в "Settings" подменю
6. Выбирает "Genres" → диалог со списком жанров и чекбоксами
7. Выбирает жанры → СРАЗУ сохраняются в preferences при каждом клике
8. Возвращается в подменю
9. Нажимает "Start Wave" → волна запускается с сохранёнными параметрами
10. Волна играет с новыми параметрами (популярность, mood, язык, вокал, жанры)
```

### 5. Инициализация при старте плагина

При инициализации плагина:
1. Определить текущий аккаунт
2. Загрузить параметры из preferences (ключ: `wave_settings_{account_id}`)
3. Если параметры не найдены → использовать дефолты (popular: 0.5, energy: 0.5, fun: 0.5, language: all, vocal: 1, genres: all)
4. Сохранить в памяти плагина для доступа из ProtocolHandler

---

## Интеграция с API

### getPersonalWave() сигнатура

```perl
sub getPersonalWave {
    my ($self, $cb, $options) = @_;  # $options = wave_settings
    
    my $vars = {
        waveSrc => "AMAZME",
        first   => 3,
        options => {
            popular  => $options->{popular} // 0.5,
            mood     => sprintf("energy:%g,fun:%g", 
                                $options->{energy} // 0.5,
                                $options->{fun} // 0.5),
            language => $options->{language},  # "all" | "foreign" | "russian"
            vocal    => $options->{vocal},     # 1 | 0
            genre    => $options->{genres} || [],  # array of objects
        },
    };
    
    # GraphQL call...
}
```

### ProtocolHandler.pm изменения

В `_explodeWave()`:
```perl
sub _explodeWave {
    my ($client) = @_;
    return unless $client;
    
    # Загрузить параметры из preferences
    my $account_id = ...;  # текущий аккаунт
    my $wave_settings = _loadWaveSettings($account_id);
    
    # Запросить волну с параметрами
    _getAPIHandler($client)->getPersonalWave(sub { ... }, $wave_settings);
}
```

---

## Список жанров

```
easy_listening_ambient  - Лёгкая музыка / Эмбиент
electronic              - Электроника
classical               - Классика
folk_world_country      - Фолк / Мировая музыка / Кантри
hip_hop                 - Хип-хоп
indie                   - Инди
instrumental_acoustic   - Инструментальная / Акустика
metal                   - Метал
pop                     - Поп
rock                    - Рок
soundtrack              - Саундтреки
```

---

## Обработка ошибок

- Если preferences повреждены/пусты → использовать дефолты
- Если диалог слайдера отменён → значение не изменяется, не сохраняется
- Если передача параметров в API не удалась → логировать, использовать дефолты

---

## Тестирование

1. **Базовое**: Изменить Popular на 0.3 → запустить волну → проверить в логах что popular: 0.3 передан
2. **Жанры**: Выбрать 2 жанра → запустить волну → проверить что массив genres содержит 2 жанра
3. **Persistence**: Изменить параметры → остановить волну → запустить волну заново → параметры должны быть те же
4. **Аккаунты**: Переключиться на другой аккаунт → параметры должны быть дефолты или сохранённые для того аккаунта

---

## Дальнейшие расширения (не в этом спринте)

- Material UI интерфейс (слайдеры, чекбоксы)
- Веб-интерфейс (Settings страница)
- Сохранённые предустановки ("Energetic", "Chill", "Discovery")
- Динамическая загрузка списка жанров из API

---

## Файлы для изменения

| Файл | Изменения | Масштаб |
|------|-----------|---------|
| Plugin.pm | Расширить меню, добавить обработчик диалогов | +50-80 строк |
| ProtocolHandler.pm | Загрузить параметры из prefs, передать в API | +20-30 строк |
| API/Async.pm | Принимать параметры, формировать options | +10-15 строк |
| Strings.txt | Локализация меню и значений | +20-30 строк |
| Constants (новый?) | Список жанров, дефолты | +30 строк |
