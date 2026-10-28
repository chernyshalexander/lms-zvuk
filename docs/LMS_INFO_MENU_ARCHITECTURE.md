# Архитектура и особенности построения инфоменю и контекстных меню в LMS

В данном документе обобщены особенности, тонкости протокола и скрытые ловушки построения контекстных меню (info menu / context menu) для Logitech Media Server (LMS / Lyrion Music Server) и клиентских платформ семейства Jive/SqueezePlay (Squeezebox Touch, Radio, Controller, программный SqueezePlay / Jivelite).

---

## 1. Контекст проблемы и симптомы сбоя

### Симптомы
В плагине при работе из SqueezePlay («Моя музыка → Альбомы»):
1. Пользователь удерживает строку альбома (долгий тап / клик / кнопка *More*).
2. Открывается контекстное меню с вариантами действий: «Добавить в конец», «Слушать следующим», «Воспроизвести».
3. При нажатии на «Воспроизвести» (`PLAY`) **ничего не происходит**: треки альбома не добавляются в плейлист, воспроизведение не начинается, интерфейс закрывается или возвращается назад.

---

## 2. Анатомия проблемы: два независимых уровня сбоя

Сбой происходил из-за наложения двух архитектурных особенностей LMS и SqueezePlay:

### Уровень 1: Игнорирование `itemActions->{go}` в ядре LMS (`Slim/Control/XMLBrowser.pm`)

Клиенты семейства Jive (SqueezePlay) для выполнения действий по клику ожидают от сервера блок:
```json
"actions": {
    "go": {
        "cmd": ["playlist", "play", "zvuk://album:12345", "", 0],
        "params": { ... },
        "nextWindow": "nowPlaying"
    }
}
```

Сервер LMS (`Slim::Control::XMLBrowser.pm:1280–1360`) генерирует поле `actions.go` для клиента следующим образом:
1. Вызывается внутренний вспомогательный метод:
   ```perl
   _makeAction($item->{itemActions}, 'items', ...)
   ```
2. Метод `_makeAction` ищет внутри переданного хеша ключ с именем запрашиваемого действия:
   ```perl
   sub _makeAction {
       my ($actions, $actionName, ...) = @_;
       if (my $action = $actions->{$actionName}) { ... }
   }
   ```
3. **Критическая ловушка**: в строке вызова передается имя действия `'items'`!
   LMS **вообще не ищет ключ `'go'`** внутри `$item->{itemActions}`. Если разработчик плагина наивно объявил:
   ```perl
   # ОШИБКА: LMS проигнорирует этот блок!
   itemActions => {
       go => {
           player => 0,
           cmd    => ['playlist', 'play', $targetUrl],
       },
   }
   ```
   то `_makeAction($item->{itemActions}, 'items')` возвращает `undef`!
4. **Падение в fallback (`XMLBrowser.pm:1242`)**:
   Когда `_makeAction` возвращает `undef`, LMS считает, что отдельного действия для пункта нет, и подставляет в `actions.go` команду родительского вызова. В нашем случае родительским вызовом было контекстное меню `['zvuk_info', 'items']`.
5. **Итог на клиенте**: SqueezePlay при нажатии кнопки «Воспроизвести» получал команду повторно запросить инфо-меню (`zvuk_info`), а команда `playlist play` даже не отправлялась на сервер.

#### Исключение: блок `jive` (`XMLBrowser.pm:1354–1360`)
Ядро LMS имеет явный прямой проброс для Jive-устройств:
```perl
if ( $item->{jive} && (my $actions = $item->{jive}->{actions}) ) {
    for my $action (keys %$actions) {
        $hash{actions}->{$action} = $actions->{$action};
    }
}
```
Если у элемента задан блок `$item->{jive}->{actions}->{go}`, LMS скопирует его напрямую в ответ клиенту в обход логики `_makeAction`.

---

### Уровень 2: Позиционные токены CLI-диспетчера LMS

Даже если команда `playlist play` будет передана клиенту, возникает вторая ловушка — сигнатура CLI LMS:

1. Диспетчер команд плейлиста в LMS зарегистрирован со следующей сигнатурой параметров:
   ```perl
   ['playlist', 'play', '_item', '_title', '_fadein']
   ```
   Здесь:
   - токен 0: `'playlist'`
   - токен 1: `'play'`
   - токен 2: `'_item'` — целевой URL трека, альбома или плейлиста;
   - токен 3: `'_title'` — заголовок (опционально);
   - токен 4: `'_fadein'` — плавное нарастание громкости (0 или 1).

2. В SqueezePlay функция `_performJSONAction` (`SlimBrowserApplet.lua:2102–2119`) упаковывает запрос в плоский массив:
   ```lua
   [ ...cmd, from, quantity, ...tagged_params ]
   ```
   Если в `cmd` передать только два элемента `['playlist', 'play']`, а URL передать в `params => { url => $targetUrl }`:
   - На позицию токена 2 (`_item`) в диспетчере LMS попадет число `from` (обычно `0`)!
   - Параметр `url:...` останется в именованных параметрах, но стандартный метод `playlist play` извлекает цель воспроизведения из позиционного аргумента `_item`.

3. **Корректные позиционные сигнатуры**:
   - Для воспроизведения: `['playlist', 'play', $targetUrl, '', 0]`
   - Для добавления в конец очереди: `['playlist', 'add', $targetUrl, '']`
   - Для вставки следующим: `['playlist', 'insert', $targetUrl, '']`

---

## 3. Сравнение с другими плагинами

| Плагин / Компонент | Как организовано контекстное меню | Особенности |
|---|---|---|
| **Yandex Music** (`yandex/Browse/Favorites.pm`) | На верхнем уровне элемента передаются `play => 'yandexmusic://album/...'` и `type => 'album'`. | Контекстное меню генерируется штатным обработчиком альбомов ядра LMS, где `play` содержит готовый URI, раскрываемый через `explodePlaylist`. |
| **Deezer** (`lms-deezer/InfoMenu.pm:630–670`) | Задаются как `itemActions` (`items`, `play`, `add`, `insert`), так и явный блок `jive => { actions => { go => ... } }`. | Дублирование через `jive` обеспечивает 100% совместимость со старыми и новыми прошивками SqueezePlay/Jivelite. |
| **LMS Core** (`Slim/Menu/AlbumInfo.pm`) | Базовый эталон LMS: использует структуру с `command` и `fixedParams` под ключами `items`, `add`, `insert`, `play`. | Полностью согласован с `_makeAction`. |

---

## 4. Канонический шаблон построения пунктов контекстного меню

Для гарантированной работы действий контекстного меню на всех платформах (SqueezePlay, Jive, Classic Web, Material Skin, мобильные контроллеры) каждый исполняемый пункт меню должен строиться по следующему шаблону:

```perl
my $targetUrl = 'zvuk://album:' . $albumId;

# 1. Пункт "Воспроизвести" (PLAY)
{
    name        => cstring($client, 'PLAY'),
    type        => 'link',
    nextWindow  => 'nowPlaying',
    playcontrol => 'play',
    url         => sub {
        my ($client, $cb) = @_;
        Slim::Control::Request::executeRequest($client, ['playlist', 'play', $targetUrl]);
        $cb->({ items => [] });
    },
    itemActions => {
        # Ключ 'items' необходим для XMLBrowser::_makeAction($itemActions, 'items')
        items => {
            command     => ['playlist', 'play', $targetUrl, '', 0],
            fixedParams => { url => $targetUrl },
        },
        # Ключ 'play' используется при прямом нажатии кнопки Play на пульте
        play => {
            command     => ['playlist', 'play', $targetUrl, '', 0],
            fixedParams => { url => $targetUrl },
        },
        # Обратная совместимость с альтернативными контроллерами
        go => {
            player     => 0,
            cmd        => ['playlist', 'play', $targetUrl, '', 0],
            params     => { url => $targetUrl },
            nextWindow => 'nowPlaying',
        },
    },
    # Прямой блок для SqueezePlay / Jive (XMLBrowser.pm:1354-1360)
    jive => {
        actions => {
            go => {
                player     => 0,
                cmd        => ['playlist', 'play', $targetUrl, '', 0],
                params     => { url => $targetUrl },
                nextWindow => 'nowPlaying',
            },
        },
    },
}
```

```perl
# 2. Пункт "Добавить в конец" (ADD_TO_END)
{
    name        => cstring($client, 'ADD_TO_END'),
    type        => 'link',
    nextWindow  => 'parent',
    playcontrol => 'add',
    url         => sub {
        my ($client, $cb) = @_;
        Slim::Control::Request::executeRequest($client, ['playlist', 'add', $targetUrl]);
        $cb->({ items => [] });
    },
    itemActions => {
        items => {
            command     => ['playlist', 'add', $targetUrl, ''],
            fixedParams => { url => $targetUrl },
        },
        add => {
            command     => ['playlist', 'add', $targetUrl, ''],
            fixedParams => { url => $targetUrl },
        },
        go => {
            player     => 0,
            cmd        => ['playlist', 'add', $targetUrl, ''],
            params     => { url => $targetUrl },
            nextWindow => 'parent',
        },
    },
    jive => {
        actions => {
            go => {
                player     => 0,
                cmd        => ['playlist', 'add', $targetUrl, ''],
                params     => { url => $targetUrl },
                nextWindow => 'parent',
            },
        },
    },
}
```

```perl
# 3. Пункт "Слушать следующим" (PLAY_NEXT)
{
    name        => cstring($client, 'PLAY_NEXT'),
    type        => 'link',
    nextWindow  => 'parent',
    playcontrol => 'insert',
    url         => sub {
        my ($client, $cb) = @_;
        Slim::Control::Request::executeRequest($client, ['playlist', 'insert', $targetUrl]);
        $cb->({ items => [] });
    },
    itemActions => {
        items => {
            command     => ['playlist', 'insert', $targetUrl, ''],
            fixedParams => { url => $targetUrl },
        },
        insert => {
            command     => ['playlist', 'insert', $targetUrl, ''],
            fixedParams => { url => $targetUrl },
        },
        go => {
            player     => 0,
            cmd        => ['playlist', 'insert', $targetUrl, ''],
            params     => { url => $targetUrl },
            nextWindow => 'parent',
        },
    },
    jive => {
        actions => {
            go => {
                player     => 0,
                cmd        => ['playlist', 'insert', $targetUrl, ''],
                params     => { url => $targetUrl },
                nextWindow => 'parent',
            },
        },
    },
}
```

---

## 5. Методология тестирования и предотвращение «слепых зон»

При написании тестов контекстного меню легко совершить ошибку «ложноположительного теста»: проверять наличие ключей в хеше меню (`$items->[2]{itemActions}{go}`), минуя сам механизм сборки ответа LMS.

В тестовом наборе [`t/test_album_context_menu.pl`](file:///home/chernysh/Projects/lms-zvuk/t/test_album_context_menu.pl) внедрен комплексный подход к валидации:

1. **Эмуляция работы `XMLBrowser::_makeAction`**:
   Тест проверяет, что вызов `_makeAction($itemActions, 'items')` успешно находит команду, заполняет `cmd`, `fixedParams`, `player` и `nextWindow`.
2. **Демонстрация дефекта старой структуры**:
   Тест подает на вход старую структуру (`только { go => { ... } }`) и валидирует, что `_makeAction` возвращает `undef`.
3. **Проверка эмуляции пакета SqueezePlay**:
   Моделируется упаковка токенов в `SlimBrowserApplet.lua` и парсинг их позиционным обработчиком команд CLI LMS (`_item`, `_title`, `_fadein`).
4. **Проверка работы `explodePlaylist`**:
   Тестируется, что переданный URI (`zvuk://album:<id>`) успешно передается в `ProtocolHandler->explodePlaylist` и разворачивается в массив ссылок на отдельные треки.
