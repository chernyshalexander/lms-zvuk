# Интерактивные элементы в меню плагина: слайдеры, radio, checkbox и HTML‑модалки

**Дата:** 2026‑07‑07
**Аудитория:** разработчик уровня middle, который будет реализовывать это самостоятельно.
**Область:** LMS (Lyrion / Logitech Media Server), плагин `Plugins::Zvuk`, скин `lms-material`, кнопочный UI железных плееров.

Документ отвечает на два вопроса:

1. Можно ли из **пункта меню плагина** (а не со страницы настроек) показывать слайдеры, radio‑списки, checkbox‑списки и произвольное модальное HTML‑окно — и как это сделать.
2. Как **разделить интерфейс** по поверхностям рендеринга (classic web / Material / SqueezePlay / кнопочные плееры типа Boom, Transporter) и как в SqueezePlay показывать checkbox/radio/slider прямо в меню.

Все утверждения проверены по исходникам. Ссылки на код даны в формате `файл:строка` относительно `~/Projects/slimserver` и `~/Projects/lms-material`.

---

## 1. Ключевая идея: два разных мира рендеринга

В LMS есть принципиальное разделение, из которого следует всё остальное.

### Мир A — «Страница как HTML» (Settings и raw‑страницы)

Страницы настроек (`Slim::Web::Settings`) и любые страницы, зарегистрированные через `Slim::Web::Pages->addRawFunction(...)`, — это **полноценный HTML**, рендерящийся через Template Toolkit. Туда можно положить что угодно: `<input type="range">`, radio, checkbox, свой JS/CSS, fetch к API.

Именно поэтому у нас уже работает `HTML/EN/plugins/zvuk/waveSliders.html` — это HTML‑страница, а не пункт меню. Она отдаётся обработчиком `handleWaveSettingsWebUI` (`Plugin.pm:~1796`) по адресу `/plugins/zvuk/waveSettings`, зарегистрированному в `Plugin.pm:51`.

**Ограничение:** это только веб (браузер). Железные плееры и SqueezePlay HTML не рендерят.

### Мир B — «Меню как данные» (OPML / Jive‑фид)

Меню плагина (`handleFeed` в `OPMLBased`) — это не HTML, а **абстрактные данные**: список элементов с атрибутами (`name`, `type`, `url`, `actions`, ...). Эти данные каждый клиент рисует по‑своему:

- classic web skin — как HTML‑список;
- Material — своими Vue‑компонентами;
- железный плеер — на своём VFD/цветном экране;
- SqueezePlay / jivelite — своим Lua‑рендерером.

Плагин **не может** «впрыснуть» произвольный HTML в пункт меню. Он ограничен теми типами элементов, которые понимает протокол, а рисует их клиент. Разные клиенты понимают **разное подмножество** типов — отсюда и вся сложность.

> **Вывод №1:** «слайдер в меню» — это не HTML. Это либо нативный виджет протокола (рисует клиент), либо ссылка (`weblink`), которая открывает HTML‑страницу из Мира A во внешнем окне/iframe.

---

## 2. Поверхности рендеринга и что каждая умеет

В экосистеме LMS есть, по сути, **пять** поверхностей рендеринга. Важно: поверхность определяется тем, **чем пользователь смотрит меню**, а не тем, какой плеер играет (см. §4 про player‑centric).

| # | Поверхность | Код рендерера | Слайдер | Radio (выбор одного) | Checkbox (независимый) | Произвольный HTML |
|---|-------------|---------------|:---:|:---:|:---:|:---:|
| 1 | **Classic Web skin** (Default) | `Slim/Web/XMLBrowser.pm` | ✗ | ✗¹ | ✗ | только Settings/raw‑страницы |
| 2 | **Material skin** | `lms-material` browse‑resp.js | ✗ | ✗¹ | ✗ | ✓ через `weblink`→iframe |
| 3 | **SqueezePlay / SqueezeOS**: Controller (Duet), Radio, Touch, десктопный SqueezePlay, jivelite/piCorePlayer | Lua на устройстве, данные из `Slim/Control/Jive.pm` | ✓ `slider` | ✓ `radio` | ✓ `checkbox` | ✗ (кроме iPeng/SqueezePad — см. ниже) |
| 4 | **Кнопочные SlimProto‑плееры**: SB1/2/3 (Classic), **Transporter**, **Boom**, Receiver | `Slim/Buttons/XMLBrowser.pm` + `Slim/Buttons/Input/*` | ✓ `INPUT.Bar` | ✓ OPML `type=radio` | ~² | ✗ |
| 5 | **Сторонние контроллеры**: iPeng, SqueezePad, OrangeSqueeze, Squeezer и т.п. | приложение | зависит | зависит | зависит | ✓ (часть умеет weblink) |

¹ classic web и Material получают `type=radio`/`checkbox` как обычные строки списка — нативного «radio‑виджета» с точкой выбора там нет, элемент деградирует в кликабельный пункт.
² на кнопочных плеерах чекбокс изображается символом‑оверлеем (галочка) у пункта `INPUT.Choice`, но «список независимых чекбоксов» как отдельный виджет протокола OPML не пробрасывает — делается через overlay/`INPUT.Choice`.

### Важные факты, которые надо принять

- **Классический Boom и Transporter — это НЕ SqueezePlay.** Оба наследуют `Slim::Player::Squeezebox2` (`Slim/Player/Boom.pm:19`, `Slim/Player/Transporter.pm:21`), то есть это старые SlimProto‑плееры с **серверным** рендерингом дисплея (`Slim::Display::*`) и навигацией кнопками/пультом через `Slim::Buttons::*`. Их «интерфейс» — поверхность №4, а не №3.
- SqueezeOS‑устройства (Controller/Duet, Radio, Touch) и десктопный SqueezePlay — поверхность №3, они рисуют `item_loop` с нативными `slider/radio/checkbox`.
- **Ни classic web, ни Material не рисуют инлайн‑слайдеры/чекбоксы/радио в списках меню.** Проверено: в `Slim/Web/XMLBrowser.pm` нет обработки `slider/checkbox/radio`; в `lms-material/.../browse-resp.js` тоже (есть только `weblink`→iframe и `choice`‑диалог для контекстных действий). Для веба богатый UI = либо Settings‑страница, либо `weblink`‑модалка.

---

## 3. Модальное HTML‑окно из пункта меню

Здесь хорошая новость — для **Material это уже работает штатно**, и почти вся инфраструктура у нас есть.

### 3.1. Механизм `weblink` → iframe (Material)

На стороне сервера у OPML‑элемента есть атрибут `weblink`. XMLBrowser пробрасывает его в ответ (`Slim/Control/XMLBrowser.pm:1155`):

```perl
if ($item->{weblink} && $item->{name}) {
    $hash{'weblink'} = $item->{weblink};
}
```

Material видит `item.weblink` (`browse-functions.js:1167`) и вызывает `openWebLink()` (`utils-deferred.js:889`):

```js
function openWebLink(item) {
    let url = item.weblink;
    // ... для локальных/относительных URL:
    bus.$emit('dlg.open', 'iframe', url, item.title, ...);   // iframe-dialog.js
    // для внешних http(s): window.open(url)
}
```

То есть **относительный URL открывается в модальном iframe‑диалоге прямо внутри Material**. Это и есть «произвольное модальное HTML‑окно с любыми элементами» — внутри iframe живёт наш `waveSliders.html` со слайдерами, radio и checkbox.

**Никакой доработки самого Material не требуется.**

### 3.2. Рецепт для zvuk (минимальные изменения)

Что уже готово:
- `handleWaveSettingsWebUI` отдаёт `waveSliders.html` по `/plugins/zvuk/waveSettings` (`Plugin.pm:51`, `~1796`);
- AJAX‑сохранение `/plugins/zvuk/saveWaveSettings` (`Plugin.pm:56`).

Сейчас в меню для веба (`Plugin.pm:1285`) отдаётся заглушка `type => 'text'` («настройки на странице плагина»). Заменяем её на `weblink`‑пункт:

```perl
# Plugin.pm, ветка $useWebUI в handleWaveSettingsRouter
$callback->([{
    name    => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
    type    => 'link',
    weblink => '/plugins/zvuk/waveSettings?player=' . ($client ? $client->id : ''),
}]);
```

В Material тап по пункту откроет форму со слайдерами/radio/checkbox в модальном iframe.

**Две правки в `waveSliders.html` для работы в iframe‑режиме:**

1. `closeWaveSliderModal()` определён в контексте страницы настроек — внутри iframe его не будет. Рамку и кнопку закрытия даёт сам диалог Material. Поэтому свою кнопку «Отмена» либо убрать, либо обернуть:
   ```js
   function closeWaveSliderModal() {
       if (window.parent && window.parent !== window) {
           // Material сам управляет диалогом; можно ничего не делать
           return;
       }
       // ... старое поведение для standalone
   }
   ```
2. Material встраивает в iframe только **относительные/локальные** URL. `/plugins/zvuk/waveSettings` подходит. Внешние `http(s)` ушли бы в новую вкладку.

### 3.3. Альтернатива для Material: Home Extra (пункт в разделе Extras)

Material даёт базовый класс `Plugins::MaterialSkin::HomeExtraBase` (`lms-material/MaterialSkin/HomeExtraBase.pm`) — плагин регистрирует пункт в домашнем меню, который открывает кастомную страницу. Это удобно, когда нужен **постоянный вход** в наш UI из главного меню Material, а не пункт внутри дерева плагина. Регистрация — через `registerHomeExtra` (`MaterialSkin/Plugin.pm:531`). Использовать, если хотим отдельную «плитку» в Extras; для нашей задачи достаточно `weblink` (§3.2).

### 3.4. Classic web skin

В classic web `weblink` штатной iframe‑модалки не даёт так красиво, как Material. Практика для классики — оставить вход через **страницу настроек** (уже реализовано) либо отдать обычную ссылку на `/plugins/zvuk/waveSettings`, которая откроется как страница. Богатый инлайн‑UI в дереве меню classic web невозможен.

---

## 4. Как определять поверхность (детекция клиента)

Это самая тонкая часть. Нужно принять фундаментальное ограничение архитектуры LMS.

### 4.1. LMS — player‑centric, а не UI‑centric

Меню строится **вокруг плеера**, а не вокруг рендерера. Один и тот же плеер (например, Boom) можно листать:
- с самого Boom (пультом, поверхность №4);
- из Material в браузере (поверхность №2);
- из iPeng на телефоне (поверхность №5);
- с Controller (поверхность №3).

Поэтому `$client->model` говорит о **целевом плеере**, а не о том, **чем сейчас рисуют меню**. Единого чистого флага «какой UI рендерит этот запрос» для обычного browse‑запроса в LMS нет. Это надо заложить в дизайн.

### 4.2. Сигналы, которые реально доступны

**(а) `isWeb`** — надёжно отличает **classic web skin**. Ставится только классическим скином при вызове фида (`Slim/Web/XMLBrowser.pm:130` и `:505`):
```perl
$feed->($client, $callback, {isWeb => 1, ...});
```
В аргументах `handleFeed`/роутера приходит как `$args->{isWeb}`.

**(б) `isControl`** — ставится для всего, что идёт через CLI/JSON‑RPC/cometd (`Slim/Control/XMLBrowser.pm:149`): Material, SqueezePlay, железо в server‑driven режиме, мобильные приложения. Сам по себе **не различает** Material vs SqueezePlay vs железо.

**(в) `controllerUA` + функции возможностей** — самый полезный сигнал про рендерер. При JSON‑RPC/cometd сервер запоминает User‑Agent управляющего приложения (`Slim/Web/JSONRPC.pm:467`, `Slim/Web/Cometd.pm:877`) в `$client->controllerUA`. Поверх него есть готовые проверки в `Slim/Utils/Misc.pm`:

```perl
# Slim/Utils/Misc.pm:68-69
my $WEBLINK_SUPPORTED_UA_RE = qr/\b(?:iPeng|SqueezePad|OrangeSqueeze|Squeeze-Control|Squeezer|OpenSqueeze|SqueezeClient)\b/i;
my $WEBBROWSER_UA_RE        = qr/\b(?:FireFox|Chrome|Safari|Mozilla)\b/i;

sub isWebBrowser   { ... controllerUA =~ WEBLINK_SUPPORTED_UA_RE || WEBBROWSER_UA_RE }  # :408
sub canFollowWeblinks { ... isWebBrowser || controllerUA =~ WEBLINK_SUPPORTED_UA_RE }   # :413
```

- `Slim::Utils::Misc::canFollowWeblinks($client)` — **можно ли этому клиенту дать `weblink`** (браузер типа Material/classic web, либо iPeng/SqueezePad и т.п.). Это ровно то, что нужно, чтобы решить «отдать HTML‑модалку или нативные виджеты».
- SqueezePlay распознаётся как `$client->controllerUA =~ /^SqueezePlay/` (пример в `Slim/Plugin/RemoteLibrary/Plugin.pm:124`).

**(г) `$client->model` / `$client->modelName`** — тип целевого плеера. Значения: `boom`, `transporter`, `squeezebox` (SB2/3/Classic), `receiver` (Duet Receiver), `baby` (Radio), `fab4` (Touch), `squeezeplay` (десктоп/jivelite), `controller` (Duet Controller), `http`/`softsqueeze`, `group`. Полезно для тонкой настройки под конкретное железо, но помнить про player‑centric (§4.1).

### 4.3. Три флага контекста запроса

У фида есть **три взаимоисключающих флага источника**, и это самый надёжный первый шаг. Каждый ставит свой рендерер:

| Флаг | Кто ставит | Где в коде | Означает |
|------|-----------|-----------|----------|
| `isWeb`     | classic web skin | `Slim/Web/XMLBrowser.pm:130,505` | листает браузер через Default‑скин |
| `isButton`  | кнопочный SlimProto‑плеер | `Slim/Buttons/XMLBrowser.pm:193,1392` | плеер листает **свой** VFD/экран пультом |
| `isControl` | CLI / JSON‑RPC / cometd | `Slim/Control/XMLBrowser.pm:149` | Material, SqueezePlay, мобильные приложения |

`isButton` — это и есть явный сигнал «классический SlimProto‑плеер (SB, Transporter, Boom) рисует сам себя». Не нужно выводить его через `!isControl`.

### 4.4. Рекомендуемая стратегия детекции (capability‑based)

Не угадывайте «Material или SqueezePlay» по эвристикам вроде `quantity > 5000` (сейчас так в `Plugin.pm:1271` — хрупко). Сначала — флаг источника, потом — возможности рендерера:

```perl
sub _uiKind {
    my ($client, $args) = @_;

    # 1. Классический веб-скин — Settings/страница.
    return 'classic_web' if $args && $args->{isWeb};

    # 2. Кнопочный SlimProto-плеер листает свой дисплей (SB/Transporter/Boom).
    return 'player_buttons' if $args && $args->{isButton};

    # 3. CLI/JSON-RPC/cometd. Различаем по возможностям рендерера.
    if ($client && Slim::Utils::Misc::canFollowWeblinks($client)) {
        return 'weblink_capable';        # Material, iPeng, SqueezePad, браузер...
    }
    if ($client && $client->controllerUA && $client->controllerUA =~ /^SqueezePlay/) {
        return 'jive';                   # Radio/Touch/Controller/desktop SqueezePlay
    }

    # 4. Источник неизвестен (UA пуст и т.п.) — безопасная деградация в jive:
    #    нативные виджеты рисуются как список даже там, где виджетов нет.
    return 'jive';
}
```

> **Замечание про `controllerUA`:** заполняется, когда клиент представился (JSON‑RPC/cometd со своим UA). Material ходит на `/jsonrpc.js` через axios с браузерным UA (Chrome/Firefox/Safari) → `canFollowWeblinks` истинно. SqueezePlay‑устройства шлют UA `SqueezePlay-baby/…`, `SqueezePlay-fab4/…` и т.п. → попадают в ветку 3. Если UA пуст, уходим в `jive` — это безопасно.

### 4.5. Полная детекция ВСЕХ известных типов клиентов

Разделение из §4.4 отвечает на вопрос «какой UI рисует» (это то, что нужно для выбора фич). Но если нужно опознать **конкретное железо** (например, для аналитики или тонкой подстройки под SlimProto‑плеер) — это **вторая ось**: идентичность плеера, независимая от поверхности.

#### Иерархия классов плееров

```
Slim::Player::Client
└── Slim::Player::Player
    ├── Slim::Player::SLIMP3                     model: slimp3        (SLIMP3 — кнопочный)
    └── Slim::Player::Squeezebox
        ├── Slim::Player::Squeezebox1            model: squeezebox    (SB1 — кнопочный)
        ├── Slim::Player::SqueezeSlave           model: squeezeslave
        └── Slim::Player::Squeezebox2            model: squeezebox2 / squeezebox3  (SB2, SB3/Classic — кнопочный)
            ├── Slim::Player::Transporter        model: transporter   (кнопочный VFD)
            │   └── Slim::Player::SoftSqueeze    model: softsqueeze
            ├── Slim::Player::Boom               model: boom          (кнопочный VFD)
            ├── Slim::Player::Receiver           model: receiver      (Duet Receiver — без дисплея)
            └── Slim::Player::SqueezePlay        model: baby/fab4/controller/squeezeplay/squeezelite  (Jive/SqueezeOS)

Slim::Player::HTTP                               model: http          (веб/сторонний, отдельная ветка)
```

> **⚠️ Критичный нюанс:** `Slim::Player::SqueezePlay` **наследует** `Slim::Player::Squeezebox2`. Поэтому `$client->isa('Slim::Player::Squeezebox2')` истинно и для Boom/Transporter, и для Radio/Touch/Controller. Всегда проверяйте `SqueezePlay` **раньше** `Squeezebox2`. Это ровно то, что различает «рисует jive нативно» и «кнопочный server‑driven UI».

Источник: `Slim/Player/*.pm` (`push @ISA`), список deviceid — `Slim/Networking/Slimproto.pm:28`, маппинг SqueezePlay‑UA → имя — `Slim/Control/Queries.pm:3748‑3754`.

#### Таблица `$client->model` → человек. имя, класс, поверхность

| `model` | Устройство (`modelName`) | Класс | Поверхность рендеринга своего меню |
|---------|--------------------------|-------|-----------------------------------|
| `slimp3` | SLIMP3 | `SLIMP3` | кнопочный (`Slim::Buttons`) |
| `squeezebox` | Squeezebox 1 | `Squeezebox1` | кнопочный |
| `squeezebox2` | Squeezebox 2 | `Squeezebox2` | кнопочный |
| `squeezebox3` | Squeezebox Classic (SB3) | `Squeezebox2` | кнопочный |
| `transporter` | Transporter | `Transporter` | кнопочный (VFD) |
| `boom` | Squeezebox Boom | `Boom` | кнопочный (VFD) |
| `receiver` | Squeezebox Receiver (Duet) | `Receiver` | без дисплея — управляется извне |
| `controller` | Squeezebox Controller (Duet) | `SqueezePlay` | **Jive** (нативные виджеты) |
| `baby` | Squeezebox Radio | `SqueezePlay` | **Jive** |
| `fab4` | Squeezebox Touch | `SqueezePlay` | **Jive** |
| `squeezeplay` | SqueezePlay (десктоп) | `SqueezePlay` | **Jive** |
| `squeezelite` | squeezelite / piCorePlayer | `SqueezePlay` | без своего UI (управляется извне; jivelite отдельно) |
| `softsqueeze` | SoftSqueeze | `SoftSqueeze` | эмулятор SlimProto |
| `squeezeslave` | Squeezeslave | `SqueezeSlave` | headless |
| `http` | Web Client | `HTTP` | нет своего плеерного UI |
| `group` | Sync Group | (виртуальный) | нет |
| `dummy` | Disconnected | `Disconnected` | нет |

#### Функция идентификации плеера (вторая ось)

```perl
sub _playerKind {
    my ($client) = @_;
    return 'none' unless $client;                       # серверный/веб-контекст без плеера

    # Порядок важен: SqueezePlay isa Squeezebox2!
    return 'jive_device'  if $client->isa('Slim::Player::SqueezePlay');  # Radio/Touch/Controller/desktop
    return 'slimproto'    if $client->isa('Slim::Player::Squeezebox');   # SB1/2/3, Transporter, Boom, Receiver
    return 'slimp3'       if $client->isa('Slim::Player::SLIMP3');
    return 'http'         if $client->isa('Slim::Player::HTTP');
    return 'other';
}

# Точная модель, когда нужно конкретное железо:
my $model = $client->model;         # 'boom', 'transporter', 'fab4', ...
my $human = $client->modelName;     # 'Squeezebox Boom', 'Transporter', 'Touch', ...
```

#### Как две оси сочетаются

- **Поверхность (`_uiKind`, §4.4)** решает, **какой UI отдать** (HTML‑модалка / jive‑виджеты / кнопочный / classic web). Это главное для нашей задачи.
- **Плеер (`_playerKind`)** нужен реже: тонкая подстройка под железо, аналитика, ограничения формата.

Важно помнить про player‑centric (§4.1): когда меню листают из Material, `_uiKind` вернёт `weblink_capable`, а `$client->model` при этом покажет, например, `boom` — потому что *играет* Boom, а *рисует* Material. Для выбора UI ориентируйтесь на `_uiKind`, не на `model`.

Полезные capability‑методы (когда важно именно «умеет ли»): `Slim::Utils::Misc::isWebBrowser($client)`, `Slim::Utils::Misc::canFollowWeblinks($client)`, `$client->hasIR`, `$client->display` (класс дисплея), `$client->displayWidth`.

### 4.4. Разделение обработчиков

```perl
sub handleWaveSettingsRouter {
    my ($client, $callback, $args) = @_;
    my $kind = _uiKind($client, $args);

    if    ($kind eq 'classic_web')     { $callback->([ _settingsHintItem($client) ]); }      # ссылка на страницу настроек
    elsif ($kind eq 'weblink_capable') { $callback->([ _weblinkItem($client) ]); }           # §3.2 iframe-модалка
    elsif ($kind eq 'jive')            { $callback->({ items => _jiveNativeItems($client) }); } # §5 нативные виджеты
    else  # player_buttons             { $callback->({ items => _buttonNativeItems($client) }); } # §5.2 INPUT.Bar / type=radio
}
```

Так каждая поверхность получает свой оптимальный UI, и добавление новой поверхности — это одна новая ветка.

---

## 5. Нативные виджеты checkbox / radio / slider в SqueezePlay и на кнопочных плеерах

### 5.1. SqueezePlay / SqueezeOS (поверхность №3)

SqueezePlay рисует `item_loop`, где элемент несёт специальные поля. Все примеры ниже — из ядра LMS (`Slim/Control/Jive.pm`), это канон.

#### Checkbox (независимое вкл/выкл)

`Slim/Control/Jive.pm:715` (будильник ON/OFF):
```perl
my $onOff = {
    text     => $client->string("ALARM_ALARM_ENABLED"),
    checkbox => ($enabled == 1) + 0,          # 1 = отмечен, 0 = нет
    actions  => {
        on  => { player => 0, cmd => ['alarm','update'], params => { id => $id, enabled => 1 } },
        off => { player => 0, cmd => ['alarm','update'], params => { id => $id, enabled => 0 } },
    },
};
```
Ключ `checkbox => 0|1` + два действия `on`/`off`. Тап переключает состояние. Для «списка независимых чекбоксов» — просто массив таких элементов.

#### Radio (выбор одного из группы)

`Slim/Control/Jive.pm:795‑844` (режим shuffle):
```perl
my @shuffleMode_menu = (
    { text => $client->string('SHUFFLE_OFF'),      radio => ($mode==0)+0,
      actions => { do => { player=>0, cmd=>['alarm','update'], params=>{ id=>$id, shufflemode=>0 } } },
      nextWindow => 'refresh' },
    { text => $client->string('SHUFFLE_ON_SONGS'),  radio => ($mode==1)+0, ... },
    { text => $client->string('SHUFFLE_ON_ALBUMS'), radio => ($mode==2)+0, ... },
);
```
Ключ `radio => 0|1` (у выбранного — 1), действие `do`. `nextWindow => 'refresh'`/`onClick => 'refreshOrigin'` обновляют отметку после выбора.

#### Choice (циклический выбор в одной строке)

`Slim/Control/Jive.pm:607‑625`:
```perl
my $onOff = {
    text          => $client->string("ALARM_ALL_ALARMS"),
    choiceStrings => [ 'Off', 'On' ],   # варианты
    selectedIndex => $val + 1,          # 1-based (как в Lua)
    actions => { do => { choices => [
        { player=>0, cmd=>['alarm','disableall'] },
        { player=>0, cmd=>['alarm','enableall'] },
    ] } },
};
```
Одна строка, значение переключается по кругу тапом. Массив `choices` в действии соответствует индексам `choiceStrings`.

#### Slider (ползунок)

`Slim/Control/Jive.pm:1269` (тон/бас) и `:1039` (громкость):
```perl
my $slider = {
    slider  => 1,
    min     => -23,
    max     => 23,
    adjust  => 24,          # сдвиг: слайдер не любит старт в нуле/минусе
    initial => $val,        # текущее значение
    actions => {
        do => { player => 0, cmd => ['playerpref', $tone], params => { valtag => 'value' } },
    },
};
```
При перетаскивании SqueezePlay шлёт `cmd` с параметром, имя которого указано в `valtag` (сюда подставится значение слайдера).

#### Text input (ввод текста/времени)

`Slim/Control/Jive.pm:740`:
```perl
my $setTime = {
    text  => $client->string("ALARM_SET_TIME"),
    input => { initialText => $t, title => ..., _inputStyle => 'time', len => 1, help => {...} },
    actions => { do => { player=>0, cmd=>['alarm','update'],
                         params => { id=>$id, time=>'__TAGGEDINPUT__' } } },   # плейсхолдер введённого
};
```

#### Как отдать это из плагина (важно!)

Обычный OPML‑фид **не пробрасывает** `checkbox/radio/slider/choiceStrings` в SqueezePlay. Проверено: XMLBrowser копирует из OPML‑элемента только ограниченный набор. Из блока `jive` пробрасываются лишь `window`, `showBigArtwork`, `style`, `nextWindow`, `icon-id` и `actions` (`Slim/Control/XMLBrowser.pm:1354‑1368`):

```perl
if ( $item->{jive} ) {
    # actions + только эти ключи:
    for my $key ('window','showBigArtwork','style','nextWindow') { ... }
}
```

Значит, чтобы показать нативные виджеты в SqueezePlay, нужен **собственный CLI‑обработчик**, который вернёт «сырой» `item_loop`. Схема:

1. Регистрируем команду (в `initPlugin`):
   ```perl
   Slim::Control::Request::addDispatch(
       ['zvuk', 'wavecontrols', '_index', '_quantity'],
       [1, 1, 1, \&cliWaveControls]   # [needsClient, isQuery, hasTags, coderef]
   );
   ```
   (аналог `Slim/Plugin/Favorites/Plugin.pm:75`).

2. В `cliWaveControls($request)` собираем `@menu` из элементов §5.1 (checkbox/radio/slider) и отдаём:
   ```perl
   $request->addResult('offset', 0);
   $request->addResult('count', scalar @menu);
   $request->addResult('item_loop', \@menu);
   $request->setStatusDone();
   ```

3. В OPML‑меню плагина ведём на эту команду через `jive.actions.go`:
   ```perl
   {
       name => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
       type => 'link',
       jive => { actions => { go => { player => 0, cmd => ['zvuk','wavecontrols'] } } },
   }
   ```
   SqueezePlay по тапу выполнит `zvuk wavecontrols` и отрисует наши нативные слайдеры/чекбоксы.

> Действия виджетов (`cmd` в `on/off/do`) должны указывать на команды, которые сохраняют pref. Можно завести маленькие CLI‑команды `zvuk setwave popular:0.7` через тот же `addDispatch`, которые пишут в `WaveSettings::saveSettings`.

### 5.2. Кнопочные плееры: Boom, Transporter, SB Classic (поверхность №4)

Эти плееры листают OPML через `Slim/Buttons/XMLBrowser.pm` и рисуют дисплей на сервере. Богатые виджеты — из `Slim/Buttons/Input/*`.

#### Radio‑список — работает прямо из OPML

`Slim/Buttons/XMLBrowser.pm` **нативно** понимает OPML `type => 'radio'`:
- `:517‑522` — элемент с `type=radio` и `default` задаёт выбранное значение; остальным radio‑элементам копируется тот же `default`;
- `:735‑765` — при выборе radio‑пункта URL уходит в фоне (`getFeedAsync`), а после успеха у всех соседних radio обновляется `default` (перерисовывается отметка).

То есть для кнопочных плееров radio‑выбор делается штатным OPML без своих CLI‑команд:
```perl
{
    name    => 'С вокалом',
    type    => 'radio',
    default => $currentVocalLabel,           # какой сейчас выбран
    url     => sub { my ($client,$cb) = @_; saveVocal(1); $cb->({ items => [] }); },
}
```

#### Slider — через `INPUT.Bar`

Ползунок на кнопочном плеере — это режим `INPUT.Bar` (`Slim/Buttons/Input/Bar.pm`). Из OPML напрямую его не вызвать так же просто, как radio; практичный путь — свой button‑режим/обработчик, который пушит `INPUT.Bar`:
```perl
Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Bar', {
    header    => $client->string('PLUGIN_ZVUK_SETTING_POPULAR'),
    min => 0, max => 100, increment => 5,
    valueRef  => \$value,
    onChange  => sub { my ($client, $v) = @_; savePopular($v/100); },
});
```
`INPUT.Choice` (`Slim/Buttons/Input/Choice.pm`) даёт список с оверлеем‑галочкой — так изображают «чекбокс» на этих плеерах.

> Если в приоритете только Material + SqueezePlay, кнопочную ветку можно реализовать по минимуму (radio через OPML `type=radio`, слайдеры — опционально), а тонкую доводку `INPUT.Bar` отложить.

### 5.3. Что где не работает — резюме

- **Слайдер инлайн в списке меню** есть только на SqueezePlay (`slider`) и кнопочных плеерах (`INPUT.Bar`). В classic web и Material — нет; для веба используем HTML‑модалку (§3).
- **Checkbox/radio как визуальный виджет** — SqueezePlay (`checkbox`/`radio`) и кнопочные (`type=radio`, оверлей). В веб‑скинах деградируют в обычные строки.
- **Произвольный HTML‑модал** — только веб (Material через `weblink`→iframe; classic web — как страница). На плеерах невозможно.

---

## 6. Пошаговый план реализации для zvuk

Порядок — от самого дешёвого и ценного к дорогому.

1. **Material‑модалка (быстрый выигрыш).** В `handleWaveSettingsRouter` для `weblink_capable` вернуть `weblink`‑пункт на `/plugins/zvuk/waveSettings` (§3.2). Адаптировать `waveSliders.html` под iframe (гард на `closeWaveSliderModal`). Проверить в Material.

2. **Заменить эвристику детекции.** Внедрить `_uiKind()` (§4.3) на базе `isWeb` + `canFollowWeblinks` вместо `quantity > 5000`. Это делает разделение поверхностей надёжным и расширяемым.

3. **Classic web.** Оставить вход через страницу настроек (уже есть) либо простая ссылка на `/plugins/zvuk/waveSettings`. Инлайн‑виджеты не пытаться.

4. **SqueezePlay нативные виджеты (по желанию).** Зарегистрировать `addDispatch(['zvuk','wavecontrols',...])`, собрать `item_loop` из checkbox/radio/slider (§5.1), провести к нему пункт меню через `jive.actions.go`. Завести CLI‑команды сохранения pref.

5. **Кнопочные плееры (по желанию).** Radio‑выбор — через OPML `type=radio` (§5.2), почти бесплатно. Слайдеры — через `INPUT.Bar`, если нужно.

---

## 7. Подводные камни

- **Не полагайтесь на `$client->model` как на «тип UI».** Он про плеер, не про рендерер (§4.1). Для «чем рисуют» — `controllerUA`/`canFollowWeblinks`.
- **`controllerUA` может быть пуст**, если клиент не представился. Стратегия §4.3 деградирует безопасно (в `jive`), но проверьте на стенде и при необходимости добавьте явные проверки.
- **`jive`‑блок в OPML пробрасывает только `window/showBigArtwork/style/nextWindow/actions/icon-id`** — checkbox/radio/slider через него не пройдут (`XMLBrowser.pm:1361`). Только свой CLI‑хэндлер.
- **Material встраивает в iframe лишь локальные/относительные URL.** Внешние `http(s)` откроются новой вкладкой (`utils-deferred.js:889`).
- **`type=radio` в OPML по‑разному живёт на разных поверхностях:** кнопочные плееры дают полноценный radio‑выбор (`Buttons/XMLBrowser.pm`), веб‑скины — обычную строку. Не рассчитывайте на единый вид на всех поверхностях; отсюда и разделение обработчиков.
- **Разные строки/значения на поверхностях:** нативные виджеты берут `text`, а OPML — `name`. При переиспользовании кода учитывайте имя поля.

---

## 8. Ссылки на код

**Сервер (`~/Projects/slimserver`):**
- `Slim/Control/XMLBrowser.pm:1057` — список типов OPML; `:1155` — проброс `weblink`; `:1354‑1368` — проброс блока `jive`.
- `Slim/Control/Jive.pm` — эталоны виджетов: checkbox `:715`, radio `:795‑844`/`:855‑887`, choice `:607‑625`, slider `:1039`/`:1269`, input `:740`.
- `Slim/Buttons/XMLBrowser.pm:517‑528`, `:735‑765` — OPML `type=radio` на кнопочных плеерах.
- `Slim/Buttons/Input/Bar.pm`, `Input/Choice.pm`, `Input/List.pm` — виджеты кнопочного UI.
- `Slim/Utils/Misc.pm:68‑69`, `:408‑418` — UA‑регэкспы и `isWebBrowser`/`canFollowWeblinks`.
- `Slim/Web/JSONRPC.pm:467`, `Slim/Web/Cometd.pm:877` — установка `controllerUA`.
- `Slim/Web/XMLBrowser.pm:130`, `:505` — установка `isWeb`.
- `Slim/Control/XMLBrowser.pm:149` — установка `isControl`.
- `Slim/Buttons/XMLBrowser.pm:193`, `:1392` — установка `isButton` (кнопочный плеер листает себя).
- `Slim/Player/Boom.pm:19`, `Slim/Player/Transporter.pm:21` — наследование от Squeezebox2 (кнопочный UI).
- `Slim/Player/SqueezePlay.pm:26` — SqueezePlay наследует Squeezebox2 (важно для порядка `isa`).
- `Slim/Networking/Slimproto.pm:28` — список deviceid → все базовые модели.
- `Slim/Control/Queries.pm:3748‑3754` — маппинг `SqueezePlay-baby/fab4/jive/squeezeplay` → Radio/Touch/Controller/desktop.
- `Slim/Player/*.pm` — `sub model` / `sub modelName` для каждой модели (полная таблица в §4.5).
- `Slim/Control/Request.pm:350` (`addDispatch`), пример `Slim/Plugin/Favorites/Plugin.pm:75`.

**Material (`~/Projects/lms-material`):**
- `MaterialSkin/HTML/material/html/js/browse-functions.js:1167` — обработка `item.weblink`.
- `MaterialSkin/HTML/material/html/js/utils-deferred.js:889` — `openWebLink()`.
- `MaterialSkin/HTML/material/html/js/iframe-dialog.js` — iframe‑диалог.
- `MaterialSkin/HTML/material/html/js/choice-dialog.js` — диалог выбора.
- `MaterialSkin/HomeExtraBase.pm`, `MaterialSkin/Plugin.pm:531` (`registerHomeExtra`).

**Плагин (`~/Projects/lms-zvuk`):**
- `Plugin.pm:51‑74` — регистрация raw‑страниц; `~1796` — `handleWaveSettingsWebUI`.
- `Plugin.pm:1236‑1292` — `handleWaveSettingsRouter` (точка для §4/§6).
- `HTML/EN/plugins/zvuk/waveSliders.html` — готовая HTML‑форма для iframe‑модалки.
