#### Звук для Lyrion Music Server
Плагин для прослушивания стримингового сервиса Звук на Lyrion Music Server (LMS).

**Для полного доступа к медиатеке и воспроизведения в Lossless-качестве (FLAC) рекомендуется действующая подписка СберПрайм.** Для ознакомления доступен гостевой (анонимный) режим, однако он максимально ограничен по каталогу, длительности треков и функционалу.

##### Возможности
- Доступ к вашей коллекции: избранные треки, альбомы, исполнители и пользовательские плейлисты.
- **«Сила Звука» (Персональная волна)** — бесконечный поток персональных рекомендаций с автоматической подгрузкой следующих треков и адаптацией под ваш вкус.
- **Тонкая настройка волны** — гибкое управление радиопотоком:
  - Слайдеры популярности (хиты / редкие), энергии (спокойно / бодро) и настроения (радостно / грустно).
  - Фильтры вокала (с вокалом / только инструментальная музыка) и языка (русский / иностранный / любой).
  - Полный каталог жанров: выбор из 13 жанровых семейств и более 50 конкретных жанров.
- **Удобное управление настройками волны** — как в веб-интерфейсе (встроенное модальное окно для Material Skin и стандартного скина), так и через меню SqueezePlay/Jive на аппаратных плеерах (Squeezebox Touch, Radio и др.).
- **Карта вкусов (Taste Atlas)** — интерактивная 2D-карта ваших музыкальных предпочтений: навигация по «островам вкусов» (Islands) и запуск персональной волны по выбранному острову.
- **GigaMix** — генерация умных плейлистов и персональных миксов по текстовому описанию на основе искусственного интеллекта с опцией автовоспроизведения.
- **Радио по треку, альбому и исполнителю** (Recommender Radio) для быстрого перехода к похожему контенту.
- **Контекстные меню и действия**:
  - Быстрый лайк / дизлайк (с возможностью навсегда скрыть трек из рекомендаций волны).
  - Управление воспроизведением: «Воспроизвести следующим», «Добавить в конец очереди».
  - Переход к карточке исполнителя или альбома на сервисе Звук.
- **Интеграция с локальной медиатекой (Online Music Library Integration)**:
  - Полная синхронизация избранного в медиатеку LMS (альбомы, исполнители, плейлисты и треки).
  - Отображение эмблемы сервиса Звук на обложках альбомов.
  - Прямой переход «Звук: перейти к исполнителю» из карточки артиста в локальной медиатеке.
  - Фоновое определение изменений в медиатеке по MD5-отпечатку.
- **Высокое качество аудио**:
  - **FLAC (Lossless)** — оригинальное качество без потерь (до 16 бит / 44.1 кГц и Hi-Res при наличии подписки).
  - **MP3** высокого качества (до 320 кбит/с).
- **Поиск** по трекам, альбомам, исполнителям и подкастам.
- **Поддержка нескольких учётных записей** (мультиаккаунт) с индикацией устаревших сессий и предупреждением в интерфейсе настроек.

##### Настройка и авторизация
Для работы с вашей личной медиатекой требуется токен авторизации. Доступные способы входа:
1. **Вход через браузер (Сбер ID / Звук):** в настройках плагина нажмите «Вход в Звук», авторизуйтесь в открывшемся окне, и плагин автоматически получит токен (либо следуйте инструкции по копированию JSON профиля).
2. **Вставка токена из буфера обмена:** скопируйте токен или строку авторизации и нажмите кнопку «Вставить из буфера» (плагин автоматически извлечет 32-значный токен).
3. **Гостевой (анонимный) режим:** нажмите кнопку «Получить анонимный токен» для быстрого ознакомления без ввода учетных данных (режим с максимальными ограничениями).

##### Установка

###### Вариант 1. Установка из GitHub (вручную)
1. Перейдите в каталог плагинов вашего сервера Lyrion Music Server (обычно `~/.slimserver/Plugins` или `/var/lib/squeezeboxserver/Plugins` в Linux):
   ```bash
   cd ~/.slimserver/Plugins
   git clone https://github.com/chernyshalexander/lms-zvuk.git Zvuk
   ```
2. Перезапустите Lyrion Music Server.
3. Откройте веб-интерфейс LMS → **Настройки** → вкладка **Дополнительно** → в выпадающем списке выберите **Zvuk** и авторизуйтесь.

###### Вариант 2. Через репозиторий LMS (Additional Repositories)
В настройках LMS (**Настройки** → **Подключаемые модули** → **Дополнительные репозитории**) добавьте ссылку на репозиторий:
```text
https://chernyshalexander.github.io/lms-zvuk/repo.xml
```
Примените настройки, найдите **Zvuk** в списке доступных сторонних плагинов, установите его и перезапустите сервер.

##### Благодарности
Выражаем благодарность сообществу Lyrion Music Server (LMS) за развитие экосистемы, поддержку открытых стандартов воспроизведения и неоценимую помощь в разработке плагинов.

##### Лицензия
Лицензия MIT. Подробности в файле LICENSE. Звук, СберПрайм и соответствующие логотипы являются товарными знаками их законных правообладателей. Данный плагин является независимой разработкой и не связан с сервисом Звук или компанией Сбер.

---

#### Zvuk for Lyrion Music Server
A plugin to stream music from the Zvuk music service on Lyrion Music Server (LMS).

**An active SberPrime subscription is recommended for full library access and lossless audio (FLAC) streaming.** An anonymous (guest) mode is available for trial listening, but it is heavily restricted in catalog availability, track preview length, and features.

##### Features
- Access to your personal collection: favorite tracks, albums, artists, and custom playlists.
- **"Power of Zvuk" (Personal Wave)** — endless intelligent recommendation stream with automatic next-batch track preloading tailored to your listening habits.
- **Fine-Grained Wave Controls**:
  - Sliders for popularity (hits vs. deep cuts), energy (calm vs. energetic), and mood (happy vs. sad).
  - Toggles for vocal content (vocal tracks vs. instrumental only) and language (Russian, foreign, or any).
  - Full genre catalog: select from 13 genre families and more than 50 subgenres.
- **Seamless Wave Settings UI** — accessible as an integrated overlay modal in modern web skins (Material Skin and Default web) as well as native SqueezePlay/Jive menus on hardware players (Squeezebox Touch, Radio, Controller).
- **Taste Atlas** — an interactive 2D visualization of your personal taste map with customizable clusters ("islands") and instant "Island Wave" radio playback.
- **GigaMix** — AI-generated custom playlists and themed mixes based on natural language prompts with optional autoplay.
- **Recommender Radio** — contextual radio stations seeded by any track, album, or artist.
- **Context Menus & Track Actions**:
  - Like and Dislike tracks (including permanently hiding disliked tracks from your wave recommendations).
  - Queue actions: "Play Next", "Add to Queue".
  - Jump to the artist page or full album on Zvuk.
- **Online Music Library Integration**:
  - Seamlessly imports your favorite albums, artists, and playlists into the native LMS "My Music" library.
  - Streaming service emblem badging on album artwork.
  - Quick-link "Zvuk: On Zvuk" from local library artist entries directly to the streaming service artist page.
  - Incremental sync with MD5 library fingerprinting to avoid unnecessary rescans.
- **High-Quality Audio**:
  - **FLAC (Lossless)** — CD-quality lossless streaming (up to 16-bit / 44.1 kHz and Hi-Res with active subscription).
  - **MP3** high-quality stream (up to 320 kbps).
- Global search for tracks, albums, artists, and podcasts.
- **Multi-Account Support** with stale account detection and warnings in the settings interface.

##### Configuration & Authentication
An authorization token is required to access your library. Available login methods:
1. **Browser Login (Sber ID / Zvuk):** In plugin settings, click "Login to Zvuk", sign in through the opened popup window, and the plugin will automatically capture your session token.
2. **Clipboard Paste:** Copy your auth token and click "Paste from clipboard" (the plugin automatically parses 32-character tokens from raw text or JSON).
3. **Guest / Anonymous Mode:** Click "Get Anonymous Token" to try the plugin without entering credentials (features and tracks will be heavily restricted).

##### Installation

###### Method 1: Manual Installation from GitHub
1. Navigate to your Lyrion Music Server plugins directory (typically `~/.slimserver/Plugins` or `/var/lib/squeezeboxserver/Plugins` on Linux):
   ```bash
   cd ~/.slimserver/Plugins
   git clone https://github.com/chernyshalexander/lms-zvuk.git Zvuk
   ```
2. Restart Lyrion Music Server.
3. Open LMS Web UI → **Settings** → **Advanced** tab → select **Zvuk** from the dropdown menu and log in.

###### Method 2: Via LMS Additional Repositories
In LMS settings (**Settings** → **Plugins** → **Additional Repositories**), add:
```text
https://chernyshalexander.github.io/lms-zvuk/repo.xml
```
Save settings, locate **Zvuk** under the Available Plugins list, install it, and restart the server.

##### Credits
Special thanks to the Lyrion Music Server (LMS) community for supporting the open-source audio streaming ecosystem and fostering independent plugin development.

##### License
MIT License. See LICENSE for details. Zvuk, SberPrime, and related logos are trademarks of their respective owners. This plugin is an independent open-source project and is not affiliated with or endorsed by Zvuk or Sber.
