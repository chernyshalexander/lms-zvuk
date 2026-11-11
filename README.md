#### Звук для Lyrion Music Server
Плагин для прослушивания стримингового сервиса Звук (zvuk.com) на Lyrion Music Server (LMS).

**Для полного доступа к медиатеке и воспроизведения в Lossless-качестве (FLAC) рекомендуется действующая подписка.** Для ознакомления доступен гостевой (анонимный) режим, однако он максимально ограничен по функционалу.

##### Возможности
- Доступ к вашей коллекции: избранные треки, альбомы, исполнители и пользовательские плейлисты.
- **«Сила Звука» (Персональная волна)** — бесконечный поток персональных рекомендаций с автоматической подгрузкой следующих треков.
- **Тонкая настройка волны** — гибкое управление радиопотоком:
  - Слайдеры популярности (хиты / редкие), энергии (спокойно / бодро) и настроения (радостно / грустно).
  - Фильтры вокала (с вокалом / только инструментальная музыка) и языка (русский / иностранный / любой).
  - Каталог жанров: выбор из 13 жанровых семейств и более 50 конкретных жанров.
- **Удобное управление настройками волны** — как в веб-интерфейсе (встроенное модальное окно для Material Skin и стандартного скина), так и через меню SqueezePlay/Jive на аппаратных плеерах (Squeezebox Touch, Radio), и классических плееров семейств IP3k и IP2k (Classic, Boom, Transporter).
- **Атлас музыкального вкуса (Taste Atlas)** — интерактивная 2D-карта ваших музыкальных предпочтений: навигация по «островам музыкальных вкусов» (Islands) и запуск персональной волны по выбранному острову.
- **GigaMix** — генерация умных плейлистов и персональных миксов по текстовому описанию на основе искусственного интеллекта с опцией автовоспроизведения.
- **Радио по треку, альбому и исполнителю** (Recommender Radio) для быстрого перехода к похожему контенту.
- **Контекстные меню и действия**:
  - Быстрый лайк/дизлайк.
  - Управление воспроизведением: «Воспроизвести следующим», «Добавить в конец очереди».
  - Переход к карточке исполнителя или альбома на сервисе Звук.
- **Интеграция с локальной медиатекой ( Online Music Library Integration)**:
  - Полная синхронизация избранного в медиатеку LMS (альбомы, исполнители, плейлисты и треки).
  - Отображение эмблемы сервиса Звук на обложках альбомов.
  - Прямой переход «Звук: перейти к исполнителю» из карточки артиста в локальной медиатеке.

- **Высокое качество аудио**:
  - **FLAC (Lossless)** — оригинальное качество без потерь.
  - **MP3** высокого качества (до 320 кбит/с).
- **Поиск** по трекам, альбомам, исполнителям и подкастам.
- **Поддержка нескольких учётных записей** (мультиаккаунт) с индикацией устаревших сессий и предупреждением в интерфейсе настроек.

##### Настройка и авторизация
Для работы с вашей личной медиатекой требуется токен авторизации. Доступные способы входа:
1. **Вход через браузер (Сбер ID / Звук):** в настройках плагина нажмите «Вход в Звук», авторизуйтесь в открывшемся окне, и плагин автоматически получит токен (либо следуйте инструкции по копированию JSON профиля).
2. **Вставка токена из буфера обмена:** скопируйте токен или строку авторизации и нажмите кнопку «Вставить из буфера» (плагин автоматически извлечет 32-значный токен).
3. **Гостевой (анонимный) режим:** нажмите кнопку «Получить анонимный токен» для быстрого ознакомления без ввода учетных данных.

##### Установка
Стабильная версия плагина доступна в стандартном списке плагинов Lyrion Music Server - 

`https://lyrion.org/lms-plugin-repository/extensions.xml`

Перейдите в настройки сервера → Управление плагинами (Manage Plugins), найдите Zvuk и установите его. После установки перезапустите Lyrion Music Server.

Чтобы добавить репозиторий вручную:
В настройках LMS (Plugins → Additional Repositories) добавьте ссылку:
Стабильная версия: `https://chernyshalexander.github.io/lms-zvuk/public.xml`
Версия в разработке: `https://chernyshalexander.github.io/lms-zvuk/dev.xml`

В настройках LMS (**Настройки** → **Подключаемые модули** → **Дополнительные репозитории**) добавьте ссылку на репозиторий со стабильной версией или с версией в разработке
Примените настройки, найдите **Zvuk** в списке доступных сторонних плагинов, установите его и перезапустите сервер.

##### Лицензия
Лицензия MIT. Подробности в файле LICENSE. zvuk.com, Звук и соответствующие логотипы являются товарными знаками их законных правообладателей. Данный плагин является независимой разработкой и не связан с сервисом Звук.

---

#### Zvuk for Lyrion Music Server
A plugin to stream music from the Zvuk music service (zvuk.com) on Lyrion Music Server (LMS).

**An active subscription is recommended for full library access and lossless audio (FLAC) playback.** A guest (anonymous) mode is available for trial listening, but its functionality is heavily restricted.

##### Features
- Access to your personal collection: favorite tracks, albums, artists, and custom playlists.
- **"Power of Zvuk" (Personal Wave)** — endless personal recommendation stream with automatic preloading of upcoming tracks.
- **Fine-Grained Wave Controls** — flexible control over your radio stream:
  - Sliders for popularity (hits / deep cuts), energy (calm / energetic), and mood (happy / sad).
  - Toggles for vocal content (vocal / instrumental only) and language (Russian / foreign / any).
  - Genre catalog: select from 13 genre families and more than 50 specific genres.
- **Seamless Wave Settings UI** — available in the web interface (integrated modal overlay for Material Skin and default skin), SqueezePlay/Jive menus on hardware players (Squeezebox Touch, Radio), and classic players from the IP3k and IP2k families (Classic, Boom, Transporter).
- **Musical Taste Atlas (Taste Atlas)** — interactive 2D visualization of your musical preferences: navigate "taste islands" and launch a personal wave based on any chosen island.
- **GigaMix** — AI-powered generation of smart playlists and custom mixes from text descriptions, with an optional autoplay feature.
- **Recommender Radio** — contextual radio stations seeded by track, album, or artist for quick discovery of similar content.
- **Context Menus & Actions**:
  - Quick like / dislike.
  - Playback control: "Play Next", "Add to Queue".
  - Jump to the artist or album page on Zvuk.
- **Online Music Library Integration**:
  - Full synchronization of favorites into the LMS library (albums, artists, playlists, and tracks).
  - Zvuk service emblem badging on album artwork.
  - Direct "Zvuk: On Zvuk" jump link from an artist entry in the local library.

- **High-Quality Audio**:
  - **FLAC (Lossless)** — original lossless audio quality.
  - **MP3** high quality (up to 320 kbps).
- **Search** for tracks, albums, artists, and podcasts.
- **Multi-Account Support** with stale session detection and warning banners in the settings interface.

##### Configuration & Authentication
An authorization token is required to access your personal library. Available login methods:
1. **Browser Login (Sber ID / Zvuk):** in the plugin settings, click "Login to Zvuk", authenticate in the opened window, and the plugin will automatically receive the token (or follow the instructions to copy the profile JSON).
2. **Clipboard Paste:** copy the token or authorization string and click "Paste from clipboard" (the plugin will automatically extract the 32-character token).
3. **Guest (Anonymous) Mode:** click "Get Anonymous Token" for quick trial listening without entering credentials.

##### Installation
The plugin is available in the official plugin directory of Lyrion Music Server. Go to the server settings, click **Manage Plugins**, search for **Yandex Music** and install it. Restart Lyrion Music Server after installation.

To add the plugin repository manually:  
In LMS settings (Plugins → Additional Repositories) add:  
Stable: `https://chernyshalexander.github.io/lms-zvuk/public.xml`  
Dev: `https://chernyshalexander.github.io/lms-zvuk/public.xml`

Apply settings, find **Zvuk** in the list of available 3rd-party plugins, install it, and restart the server.

##### License
MIT License. See LICENSE for details. zvuk.com, Zvuk, and corresponding logos are trademarks of their respective owners. This plugin is an independent development and is not affiliated with the Zvuk service.
