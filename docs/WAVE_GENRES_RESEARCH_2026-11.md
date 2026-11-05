# Жанры Zvuk для настройки Волны: API и эмпирическая карта (2026-11)

Исследование по вопросу «можно ли перестать хардкодить жанры в `WaveSettings.pm` и брать их из API».
Проверено живыми запросами с реальным токеном (`777701291`).

## 1. Что есть в API

| Операция | Что отдаёт | Проверено |
|---|---|---|
| `recommenderOnboarding { getOnboardingGenres { genre_id title image_url } }` | 20 «витринных» жанров: `genre_id` — слаг, `title` — локализованное имя | HTTP 200; **одинаков для всех авторизованных аккаунтов**, у анонимного — 401 |
| `genres(ids: [ID!]!)` | таксономия: `{ id name shortName parent { id name } }`; 289 жанров, id 1..314 | HTTP 200 |
| `contentCategories(contentTypes:)` | редакторские карточки (MUSIC/KIDS), **не жанры волны** | HTTP 200, не подходит |
| `/api/tiny/grid?name=grid_search` | только баннер «Жанры», списка нет | HTTP 200, бесполезно |

Сторонние проекты (`zvuk-music`, `ma-provider-zvuk-music`) каталог жанров **не получают вообще**:
у первого `Genre` приходит только внутри `getReleases.graphql`, у второго жанры — лишь метаданные
при парсинге релиза/трека; в browse-дереве MA-провайдера жанров нет.

## 2. Как Волна принимает жанр

`personalWaveContent(options: { genre: [{ name, type }] })`, где:

- `name` — **слаг**: нижний регистр, пробелы → подчёркивания (`Italo Disco` → `italo_disco`);
  display-name с пробелом **не работает** (проверено: `"Italo Disco"` LVL3 → мусор, `italo_disco` LVL3 → точное попадание);
- `type` — уровень: `LVL1` широкие категории, `LVL2` / `LVL3` — таксономические поджанры.

Хорошая эвристика для таксономии: `parent == null → LVL2`, иначе `LVL3`
(подтвердилось на Disco/House/Italo Disco/Nu Disco/Trip Hop/Chillwave/Shoegaze/Dubstep/Ska/Darkwave/Neo Soul).

**Критично:** неверная пара (слаг, уровень) **не даёт ошибки** — HTTP 200 и обычный микс
«популярное/знакомое». Валидность никак не сигнализируется.

## 3. Подтверждённые рабочие пары (проверены по артистам)

### LVL1 — широкие (наши 13 + онбординг)
`pop`, `rock`, `metal`, `jazz`, `classical`, `electronic`, `indie`, `hip_hop`, `latin`, `easy_listening_ambient`, `folk_world_country`, `instrumental_acoustic`

Подтверждение примерами: `easy_listening_ambient` → Arvo Pärt, Hôtel Costes, Алексей Козлов;
`folk_world_country` → Willie Nelson, Johnny Cash, Песняры; `instrumental_acoustic` → Argerich, Enya, Mahler;
`latin` → Buena Vista Social Club, Gotan Project; `hip_hop` → Noize MC, GALAGA; `metal` → Motörhead, Tool.

### LVL2
`disco`, `house`, `funk`, `folk`

- `disco` → Radiorama, Savage, Toto Cutugno, The Italians, D.White
- `house` → Faithless, Giorgio Moroder, Parov Stelar, Enigma
- `funk` → Khruangbin, Donna Summer, The Doobie Brothers, Herb Alpert, La Bionda
- `folk` → Simon & Garfunkel, Отава Ё, Белый День, Katie Melua

### LVL3
`italo_disco`, `nu_disco`, `trip_hop`, `chillwave`, `shoegaze`, `dubstep`, `ska`, `darkwave`, `neo_soul`, `synthwave`, `future_funk`, `rnb`, `bebop`, `psychedelic_rock`, `trance`, `estrada`, `gothic_rock`, `garage_rock`, `afrobeat`, `j_rock`, `indie_rock`, `progressive_house`

- `italo_disco` → Radiorama, Savage, Toto Cutugno, DNDM
- `trip_hop` → Morcheeba, Bonobo, Hooverphonic, Thievery Corporation, Massive Attack, Air
- `chillwave` → Blood Orange, Odesza, Cannons, Teen Daze, Chromatics, Com Truise
- `shoegaze` → Sigur Rós, Kinokoteikoku, Life on Venus, культодиночества
- `dubstep` → Cookie Monsta, JSTJR, Jon Hopkins
- `ska` → Рви Меха-Оркестр, Russkaja, Prime Time Gang, Combustible Edison
- `darkwave` → Lacrimosa, Diorama, Diary of Dreams, X-Perience
- `neo_soul` → Thundercat, WILLOW, Montell Fish, Badbadnotgood, Steve Lacy
- `synthwave` → Lazerhawk, Scandroid, FM-84, Perturbator, Gunship, Carpenter Brut
- `indie_rock` → Kasabian, Arctic Monkeys, Franz Ferdinand, Editors
- `bebop` → Milt Jackson, Grant Green, Wes Montgomery, The Ray Brown Trio
- `psychedelic_rock` → Jefferson Airplane, The Kinks, King Gizzard, Khruangbin
- `rnb` → Diana Ross, The Platters, The Ojays, Simply Red

## 4. Vaporwave: сам жанр не подключён, но пул доступен через `future_funk`

Проверка по конкретным артистам сцены (Saint Pepsi, Luxury Elite, Equip, 18 Carat Affair, Macintosh Plus,
Esprit, Haircuts for Men, Windows96, Cat System Corp, Blank Banshee, Telepath, Nmesh, Vektroid и др.):

| Слаг | Уровень | Что вернулось |
|---|---|---|
| `vaporwave` | LVL2, LVL3 | Kraftwerk, ELO, Bach, Pink Floyd — **generic-пул**, жанр не подключён |
| `vaportrap`, `mallsoft`, `chillsynth`, `darksynth` | LVL3 | тот же generic-пул |
| **`future_funk`** | **LVL3** | **Com Truise×3, Night Tempo×3, Yung Bae×3, Jamiroquai, Miami Vice×2, Tupperwave×2, Vantage×2, Luxury Elite×2, Desired** |

То есть эстетика 80-х в выдаче `vaporwave` — это не грубое попадание, а именно **невалидный слаг**;
рабочий ключ к этой сцене — `future_funk`. Saint Pepsi/Skylar Spence в выборке не встретился, но весь
остальной пул — ровно future-funk/vaporwave-сцена (Luxury Elite, Miami Vice, Night Tempo, Yung Bae, Tupperwave).

## 5. Полный скан 289 жанров таксономии

Протокол: слаг по правилу `lower → underscores`, уровень по `parent`; 2 вызова × 6 треков на жанр;
вердикт по доле пересечения с generic-пулом (48 id без жанра + 48 id мусорного слага).
Затем — независимая перепроверка спорных в 3 вызова × 8 треков с проверкой артистов.

Результат первого прохода: 217 «отличимых», 12 частичных, 60 «мёртвых».
Второй проход по 72 спорным с исправленными слагами (`R&B`→`rnb`, `Funk/Soul`→`funk`, `Folk&World`→`folk`,
`French Сhanson`→`french_chanson`) и перебором уровней улучшил 64 позиции — **но** независимая проверка
показала, что значительная часть этих «улучшений» — ложные плюсы от выбора минимума по шумной метрике.

**Опровергнуто перепроверкой** (возвращают классику/рок-пул): `skate_punk`, `black_metal`, `bluegrass`, `psy_trance`, `gypsy_jazz`, `emo_rock`, `minimal_house`, `experimental`, `modern_rock`, `math_rock`, `vaporwave`, `vaporwave`, `mallsoft`, `chillsynth`, `vaportrap`, `darksynth`

**Вывод:** список «отличимых» жанров — это генератор кандидатов, а не готовый каталог.
Каждую пару нужно подтверждать серией вызовов и глазами по артистам.

### Кандидаты (overlap ≤ 0.2, вручную не проверялись) — 184 шт.

| жанр | слаг | уровень | overlap |
|---|---|---|---|
| Acid Techno | `acid_techno` | LVL3 | 0.17 |
| Acoustic Rock | `acoustic_rock` | LVL3 | 0.00 |
| Afrobeats | `afrobeats` | LVL3 | 0.00 |
| Alternative Metal | `alternative_metal` | LVL3 | 0.00 |
| Alternative Pop | `alternative_pop` | LVL3 | 0.00 |
| Alternative Rock | `alternative_rock` | LVL3 | 0.00 |
| Ambient | `ambient` | LVL3 | 0.00 |
| Anatolian Rock | `anatolian_rock` | LVL3 | 0.00 |
| Art Pop | `art_pop` | LVL3 | 0.00 |
| Art Rock | `art_rock` | LVL3 | 0.00 |
| Avant Garde Jazz | `avant_garde_jazz` | LVL3 | 0.00 |
| Baroque Pop | `baroque_pop` | LVL3 | 0.17 |
| Bedroom Pop | `bedroom_pop` | LVL3 | 0.00 |
| Blackgaze | `blackgaze` | LVL3 | 0.00 |
| Bollywood | `bollywood` | LVL3 | 0.00 |
| Boogie-Woogie | `boogie_woogie` | LVL3 | 0.17 |
| Boom Bap | `boom_bap` | LVL3 | 0.00 |
| Bossa Nova | `bossa_nova` | LVL3 | 0.00 |
| Brazilian Funk | `brazilian_funk` | LVL3 | 0.00 |
| Brazilian Phonk | `brazilian_phonk` | LVL3 | 0.00 |
| Breakbeat/Breaks | `breakbeat_breaks` | LVL3 | 0.00 |
| Breakcore | `breakcore` | LVL3 | 0.00 |
| Britpop | `britpop` | LVL3 | 0.00 |
| C-Pop | `c_pop` | LVL3 | 0.00 |
| Chanson | `chanson` | LVL2 | 0.00 |
| Children | `children` | LVL3 | 0.00 |
| Chill House | `chill_house` | LVL3 | 0.00 |
| Chiptune | `chiptune` | LVL3 | 0.00 |
| Christian | `christian` | LVL3 | 0.00 |
| Christian Rock | `christian_rock` | LVL3 | 0.00 |
| City Pop | `city_pop` | LVL3 | 0.00 |
| Classic Rock | `classic_rock` | LVL3 | 0.00 |
| Cloud Rap | `cloud_rap` | LVL3 | 0.00 |
| Comedy | `comedy` | LVL3 | 0.00 |
| Country | `country` | LVL3 | 0.08 |
| Cumbia | `cumbia` | LVL3 | 0.00 |
| Dance | `dance` | LVL2 | 0.08 |
| Dancehall | `dancehall` | LVL3 | 0.00 |
| Dancehall Reggae | `dancehall_reggae` | LVL3 | 0.00 |
| Dark Ambient | `dark_ambient` | LVL3 | 0.00 |
| Dark Folk | `dark_folk` | LVL3 | 0.00 |
| Death Metal | `death_metal` | LVL3 | 0.00 |
| Deathcore | `deathcore` | LVL3 | 0.00 |
| Deep House | `deep_house` | LVL3 | 0.00 |
| Digital Hardcore | `digital_hardcore` | LVL3 | 0.00 |
| Disco House | `disco_house` | LVL3 | 0.00 |
| Djent | `djent` | LVL3 | 0.00 |
| Doom Metal | `doom_metal` | LVL3 | 0.00 |
| Downtempo | `downtempo` | LVL3 | 0.00 |
| Dream Pop | `dream_pop` | LVL3 | 0.00 |
| Drill | `drill` | LVL3 | 0.00 |
| Drone | `drone` | LVL3 | 0.00 |
| Drone Ambient | `drone_ambient` | LVL3 | 0.00 |
| Dub | `dub` | LVL3 | 0.00 |
| EBM | `ebm` | LVL3 | 0.00 |
| EDM | `edm` | LVL3 | 0.00 |
| Easy Listening | `easy_listening` | LVL2 | 0.00 |
| Electro | `electro` | LVL3 | 0.00 |
| Electro Swing | `electro_swing` | LVL3 | 0.00 |
| Emo Rap | `emo_rap` | LVL3 | 0.00 |
| Eurodance | `eurodance` | LVL3 | 0.00 |
| Experimental Electronic | `experimental_electronic` | LVL3 | 0.00 |
| Flamenco | `flamenco` | LVL3 | 0.00 |
| Folk Metal | `folk_metal` | LVL3 | 0.00 |
| Folk Pop | `folk_pop` | LVL3 | 0.00 |
| Folk Rock | `folk_rock` | LVL3 | 0.08 |
| Free Jazz | `free_jazz` | LVL3 | 0.00 |
| French House | `french_house` | LVL3 | 0.00 |
| Funk Rock | `funk_rock` | LVL3 | 0.00 |
| Future Bass | `future_bass` | LVL3 | 0.00 |
| Future Garage | `future_garage` | LVL3 | 0.00 |
| Glam Metal | `glam_metal` | LVL3 | 0.00 |
| Glitch | `glitch` | LVL3 | 0.00 |
| Goa Trance | `goa_trance` | LVL3 | 0.08 |
| Gospel | `gospel` | LVL3 | 0.00 |
| Gothic Metal | `gothic_metal` | LVL3 | 0.00 |
| Grime | `grime` | LVL3 | 0.00 |
| Grindcore | `grindcore` | LVL3 | 0.00 |
| Groove Metal | `groove_metal` | LVL3 | 0.00 |
| Grunge | `grunge` | LVL3 | 0.00 |
| Happy Hardcore | `happy_hardcore` | LVL3 | 0.00 |
| Hard Rock | `hard_rock` | LVL3 | 0.00 |
| Hard Techno | `hard_techno` | LVL3 | 0.00 |
| Hardbass | `hardbass` | LVL3 | 0.00 |
| Hardcore | `hardcore` | LVL3 | 0.00 |
| Hardcore Punk | `hardcore_punk` | LVL3 | 0.00 |
| Hardcore Techno | `hardcore_techno` | LVL3 | 0.00 |
| Heavy Metal | `heavy_metal` | LVL3 | 0.00 |
| Hyperpop | `hyperpop` | LVL3 | 0.00 |
| IDM | `idm` | LVL3 | 0.00 |
| Indie Pop | `indie_pop` | LVL3 | 0.00 |
| Industrial | `industrial` | LVL3 | 0.00 |
| Industrial Metal | `industrial_metal` | LVL3 | 0.00 |
| Industrial Rock | `industrial_rock` | LVL3 | 0.00 |
| Instrumental Hip-Hop | `instrumental_hip_hop` | LVL3 | 0.00 |
| J-pop | `j_pop` | LVL3 | 0.00 |
| Jazz Fusion | `jazz_fusion` | LVL3 | 0.00 |
| Jersey Club | `jersey_club` | LVL3 | 0.00 |
| Jungle/Drum'n'Bass | `jungle_drumnbass` | LVL3 | 0.08 |
| K-Rap | `k_rap` | LVL3 | 0.00 |
| K-pop | `k_pop` | LVL3 | 0.00 |
| Karaoke | `karaoke` | LVL3 | 0.00 |
| Kizomba | `kizomba` | LVL3 | 0.00 |
| Latin Jazz | `latin_jazz` | LVL3 | 0.00 |
| Lo-Fi Hip-Hop | `lo_fi_hip_hop` | LVL3 | 0.00 |
| Lo-Fi House | `lo_fi_house` | LVL3 | 0.00 |
| Lounge | `lounge` | LVL2 | 0.00 |
| Lullaby | `lullaby` | LVL3 | 0.00 |
| Mambo | `mambo` | LVL3 | 0.00 |
| Mathcore | `mathcore` | LVL3 | 0.00 |
| Medieval Metal | `medieval_metal` | LVL3 | 0.00 |
| Melodic Death Metal | `melodic_death_metal` | LVL3 | 0.00 |
| Melodic Metal | `melodic_metal` | LVL3 | 0.00 |
| Metalcore | `metalcore` | LVL3 | 0.00 |
| Minimal Techno | `minimal_techno` | LVL3 | 0.00 |
| Motown | `motown` | LVL3 | 0.00 |
| Neo Classical | `neo_classical` | LVL3 | 0.00 |
| Neofolk | `neofolk` | LVL3 | 0.00 |
| Neurofunk | `neurofunk` | LVL3 | 0.00 |
| New Age | `new_age` | LVL3 | 0.00 |
| New Rave | `new_rave` | LVL3 | 0.17 |
| New Wave | `new_wave` | LVL3 | 0.00 |
| Non-Music | `non_music` | LVL3 | 0.00 |
| Nu Jazz | `nu_jazz` | LVL3 | 0.00 |
| Nu Metal | `nu_metal` | LVL3 | 0.00 |
| Opera | `opera` | LVL3 | 0.00 |
| Phonk | `phonk` | LVL3 | 0.00 |
| Pop Punk | `pop_punk` | LVL3 | 0.00 |
| Pop Rap | `pop_rap` | LVL3 | 0.00 |
| Pop Rock | `pop_rock` | LVL3 | 0.17 |
| Post-Grunge | `post_grunge` | LVL3 | 0.00 |
| Post-Hardcore | `post_hardcore` | LVL3 | 0.00 |
| Post-Punk | `post_punk` | LVL3 | 0.00 |
| Post-rock | `post_rock` | LVL3 | 0.00 |
| Power Metal | `power_metal` | LVL3 | 0.00 |
| Prog Rock | `prog_rock` | LVL3 | 0.08 |
| Progressive Death Metal | `progressive_death_metal` | LVL3 | 0.00 |
| Progressive Metal | `progressive_metal` | LVL3 | 0.00 |
| Progressive Trance | `progressive_trance` | LVL3 | 0.00 |
| Punk Rock | `punk_rock` | LVL3 | 0.00 |
| Ragtime | `ragtime` | LVL3 | 0.00 |
| Rap | `rap` | LVL3 | 0.00 |
| Rap Rock | `rap_rock` | LVL3 | 0.00 |
| Rapcore | `rapcore` | LVL3 | 0.17 |
| Reggae | `reggae` | LVL2 | 0.00 |
| Reggaeton | `reggaeton` | LVL3 | 0.00 |
| Religion | `religion` | LVL2 | 0.00 |
| Rockabilly | `rockabilly` | LVL3 | 0.00 |
| Romance | `romance` | LVL3 | 0.00 |
| Rumba | `rumba` | LVL3 | 0.00 |
| Russian Bard | `russian_bard` | LVL3 | 0.00 |
| Russian Rap | `russian_rap` | LVL3 | 0.00 |
| Russian Rock | `russian_rock` | LVL3 | 0.00 |
| Salsa | `salsa` | LVL3 | 0.00 |
| Samba | `samba` | LVL3 | 0.00 |
| Screamo | `screamo` | LVL3 | 0.00 |
| Singer-Songwriter | `singer_songwriter` | LVL2 | 0.00 |
| Ska Punk | `ska_punk` | LVL3 | 0.00 |
| Slap House | `slap_house` | LVL3 | 0.00 |
| Smooth Jazz | `smooth_jazz` | LVL3 | 0.00 |
| Soft Rock | `soft_rock` | LVL3 | 0.00 |
| Soul | `soul` | LVL3 | 0.00 |
| Soviet Music | `soviet_music` | LVL3 | 0.00 |
| Space Rock | `space_rock` | LVL3 | 0.00 |
| Spoken Word | `spoken_word` | LVL3 | 0.00 |
| Stoner Rock | `stoner_rock` | LVL3 | 0.00 |
| Surf Rock | `surf_rock` | LVL3 | 0.00 |
| Swing | `swing` | LVL3 | 0.00 |
| Symphonic Black Metal | `symphonic_black_metal` | LVL3 | 0.00 |
| Symphonic Metal | `symphonic_metal` | LVL3 | 0.00 |
| Symphonic Rock | `symphonic_rock` | LVL3 | 0.00 |
| Symphony | `symphony` | LVL3 | 0.00 |
| Synthpop | `synthpop` | LVL3 | 0.17 |
| Tango | `tango` | LVL3 | 0.00 |
| Tech House | `tech_house` | LVL3 | 0.00 |
| Techno | `techno` | LVL2 | 0.00 |
| Thrash Metal | `thrash_metal` | LVL3 | 0.00 |
| Trap | `trap` | LVL3 | 0.00 |
| Trap Metal | `trap_metal` | LVL3 | 0.00 |
| Turntablism | `turntablism` | LVL3 | 0.00 |
| UK Garage | `uk_garage` | LVL3 | 0.00 |
| Underground Hip-Hop | `underground_hip_hop` | LVL3 | 0.00 |
| Witch House | `witch_house` | LVL3 | 0.00 |
| World | `world` | LVL3 | 0.00 |

### Отвергнутые (overlap > 0.6, generic-пул) — 59 шт.

| жанр | слаг | уровень | overlap |
|---|---|---|---|
| Acid House | `acid_house` | LVL3 | 1.00 |
| Acid Jazz | `acid_jazz` | LVL3 | 1.00 |
| Afro Cuban Jazz | `afro_cuban_jazz` | LVL3 | 1.00 |
| Alternative | `alternative` | LVL2 | 0.42 |
| Alternative R&B | `alternative_r_b` | LVL3 | 1.00 |
| Bachata | `bachata` | LVL3 | 1.00 |
| Beatdown Hardcore | `beatdown_hardcore` | LVL3 | 1.00 |
| Blues | `blues` | LVL2 | 0.33 |
| Cha Cha Cha | `cha_cha_cha` | LVL3 | 0.58 |
| Chamber Music | `chamber_music` | LVL3 | 1.00 |
| Chamber Pop | `chamber_pop` | LVL3 | 1.00 |
| Chillstep | `chillstep` | LVL3 | 1.00 |
| Cold Wave | `cold_wave` | LVL3 | 1.00 |
| Cool Jazz | `cool_jazz` | LVL3 | 1.00 |
| Dance/Electronic | `dance_electronic` | LVL2 | 0.50 |
| Dark R&B | `dark_r_b` | LVL3 | 1.00 |
| Dungeon Synth | `dungeon_synth` | LVL3 | 1.00 |
| Electro R&B | `electro_r_b` | LVL3 | 0.83 |
| Emocore | `emocore` | LVL3 | 0.92 |
| Folk&World | `folk_world` | LVL2 | 1.00 |
| French Rap | `french_rap` | LVL3 | 0.92 |
| French Сhanson | `french_hanson` | LVL3 | 1.00 |
| Funk/Soul | `funk_soul` | LVL2 | 0.92 |
| G-funk | `g_funk` | LVL3 | 1.00 |
| Glam Rock | `glam_rock` | LVL3 | 1.00 |
| Gothabilly | `gothabilly` | LVL3 | 0.58 |
| Gothic Country | `gothic_country` | LVL3 | 1.00 |
| Horror Punk | `horror_punk` | LVL3 | 0.50 |
| Horrorcore | `horrorcore` | LVL3 | 1.00 |
| K-Rock | `k_rock` | LVL3 | 1.00 |
| Krautrock | `krautrock` | LVL3 | 0.83 |
| Latin Afrobeats | `latin_afrobeats` | LVL3 | 1.00 |
| Liquid Funk | `liquid_funk` | LVL3 | 1.00 |
| Madchester | `madchester` | LVL3 | 0.67 |
| Melodic Black Metal | `melodic_black_metal` | LVL3 | 1.00 |
| Melodic Hardcore | `melodic_hardcore` | LVL3 | 0.42 |
| Memphis Rap | `memphis_rap` | LVL3 | 1.00 |
| Midwest Emo | `midwest_emo` | LVL3 | 0.92 |
| Miscellaneous/Other | `miscellaneous_other` | LVL2 | 1.00 |
| Muslim | `muslim` | LVL3 | 1.00 |
| Neue Deutsche Härte | `neue_deutsche_h_rte` | LVL3 | 0.83 |
| Noise Pop | `noise_pop` | LVL3 | 0.67 |
| Noise Rock | `noise_rock` | LVL3 | 1.00 |
| Psychobilly | `psychobilly` | LVL3 | 0.83 |
| R&B | `r_b` | LVL3 | 1.00 |
| Rap Metal | `rap_metal` | LVL3 | 1.00 |
| Rap/R&B | `rap_r_b` | LVL2 | 1.00 |
| Rock&Roll | `rock_roll` | LVL3 | 1.00 |
| Russian | `russian` | LVL2 | 0.75 |
| Russian Pop | `russian_pop` | LVL3 | 0.25 |
| Schlager | `schlager` | LVL3 | 1.00 |
| Slowcore | `slowcore` | LVL3 | 0.50 |
| Sludge Metal | `sludge_metal` | LVL3 | 1.00 |
| Smooth R&B | `smooth_r_b` | LVL3 | 1.00 |
| Soundtrack | `soundtrack` | LVL2 | 1.00 |
| Speed Garage | `speed_garage` | LVL3 | 0.42 |
| Speed Metal | `speed_metal` | LVL3 | 0.75 |
| Stoner Metal | `stoner_metal` | LVL3 | 0.92 |
| Unknown | `unknown` | LVL2 | 1.00 |

## 6. Рекомендация для плагина

1. Хардкод в `WaveSettings.pm` **не устарел**: все 13 констант подтверждены рабочими (LVL1).
2. Замена на «20 из `getOnboardingGenres`» — **регресс**: потеряются `easy_listening_ambient`,
   `folk_world_country`, `instrumental_acoustic`, `latin` и др., которых в онбординге нет.
3. Правильная схема — **курируемый union**: 13 текущих (LVL1) + проверенные LVL2/LVL3 из таблицы §3,
   с уровнем в константе. Расширять — только после проверки конкретной пары.
4. `getOnboardingGenres` годится как источник **локализованных подписей** (`title`) и как индикатор
   доступности аккаунта (401 → анонимный аккаунт, показываем хардкод).
5. Автогенерацию списка из таксономии (289 вариантов) делать нельзя: ~половина окажется мёртвой
   и никак об этом не сообщит — пользователь выберет «Vaporwave» и получит Бетховена.


## 6b. Проверка всех 184 кандидатов (3 вызова × 8 треков + разбор артистов)
Вердикт по списку артистов, а не только по метрике: `ok` — жанр отдаёт собственный пул; `mixed` — частично/соседний жанр; `parent` — совпадает с широким жанром; `junk` — чужой пул.

### Подтверждено: жанр отдаёт свой пул — 105 шт.

| жанр | слаг | уровень | примеры артистов |
|---|---|---|---|
| Alternative Metal | `alternative_metal` | LVL3 | RADIO TAPOK, Skindred, Deftones, Paradise Lost, Son of the Dead Sun, Father Of Peace, Jackyl, Детский метал-хо |
| Alternative Pop | `alternative_pop` | LVL3 | АИГЕЛ, CREAM SODA, Slayyyter, Jonathan Bree, Röyksopp, Lamb, sombr, Noga Erez, IC3PEAK |
| Ambient | `ambient` | LVL3 | Музыка для Релаксации, Iren Lullaby, Музыка для медитации, Origen, Sat-Chit, Amiina, Нина Коляда, Jon Hopkins, |
| Anatolian Rock | `anatolian_rock` | LVL3 | emre aydın, Gripin, Mor ve Ötesi, Şerif Ali Boztepe, Nilüfer, Celal İnce, Murat Boz, B.B. King |
| Art Pop | `art_pop` | LVL3 | Unlike Pluto, Dean Blunt, David Bowie, Mili, Róisín Murphy, Agnes Obel, Grimes, Bear McCreary |
| Art Rock | `art_rock` | LVL3 | Pixies, Roger Waters, Nick Cave, Gregorian, David Bowie, Nautilus Pompilius, Пикник, Will Wood, Сон у Красной  |
| Bedroom Pop | `bedroom_pop` | LVL3 | Rex Orange County, Role Model, Conan Gray, girl in red, Cuco, PinkPantheress, Malcolm Todd, Hauser |
| Bollywood | `bollywood` | LVL3 | Navraj Hans, Sachin-Jigar, A.R. Rahman, Mond. Rafi, Richa Sharma, Sharon Prabhakar, Divya Kumar, Aditya Rikhar |
| Bossa Nova | `bossa_nova` | LVL3 | Richard Smith, Jósean Log, Beady Belle, Groove da Praia, The Moleskins, Andrea Cardillo, Marcela Mangabeira, B |
| Brazilian Phonk | `brazilian_phonk` | LVL3 | ZXKAI, DJ KOALA6, Lenar, Ksusha Pachuli, Gazan, DJ FallThox, GameboyJones, Cacau Chuu, Kickrix |
| Breakbeat/Breaks | `breakbeat_breaks` | LVL3 | 3D Stas, Puretone, Breaking System, Артем Пора Домой, Apollo 440, DJ Dee Kline, Bomfunk MC's, Rozalla, DJ Spoo |
| Breakcore | `breakcore` | LVL3 | Tiktok Remixer, femtanyl, Aphrodite, Sink Saiko, stagger!, Rory in early 20s, Thievery Corporation |
| C-Pop | `c_pop` | LVL3 | 周深, 颜安, YUQI, A2O, THE 8, YANGYINYUE, 黄星, 马卓冰, Zhang Bichen |
| Chanson | `chanson` | LVL2 | Олег Шеременко, Александр Малинин, Анатолий Горохов, Игорь Крутой, Аркадий Северный, Михаил Боярский, Людмила  |
| Children | `children` | LVL3 | Ум и Хрум, Любаша, Детские Песни Советские, Pinkfong, Смешарики, Фиксики, МУЛЬТИВАРИК ТВ, Юни |
| Christian | `christian` | LVL3 | Sasha Komovich, Хор братии Валаамского монастыря, Новая Жизнь Music, Алексей Каратаев, Виктор Лавриненко, Puri |
| Christian Rock | `christian_rock` | LVL3 | Vitaliy Yefremochkin, Jesus Culture, Hawk Nelson, Hillsong United, Bethel Music, Iulia Fridrik, Новое начало,  |
| City Pop | `city_pop` | LVL3 | Junko Yagami, Night Tempo, Lamp, Carlos Toshiki And Omega Tribe, Miki Matsubara, The Beatles, Bill Evans |
| Classic Rock | `classic_rock` | LVL3 | Foreigner, Zakk Wylde, Slade, Ozzy Osbourne, Larkin Poe, Beth Hart, Dorothy, Bread |
| Dark Folk | `dark_folk` | LVL3 | Trobar de Morte, Der Golem, Чёрная Тайга, Demons & Wizards, Folake, Castle Rat, Burzum, The Bridge City Sinner |
| Death Metal | `death_metal` | LVL3 | Behemoth, Necrotted, Opeth, Slaughter to Prevail, Immolation, Chris Botti, Nina Simone |
| Deathcore | `deathcore` | LVL3 | TEYU, BRUTALLIZM, fxdedthemm, Fucking Werewolf Asso, Distant, NeurofilAi, Slaughter to Prevail, Duke Ellington |
| Digital Hardcore | `digital_hardcore` | LVL3 | fxlse, Venjent, шизоняшка, PISSGOBLIN, Whybaby_ff, Boom Kitty, gold archive, Hard Bass School |
| Djent | `djent` | LVL3 | Emma Ruth Rundle, Свет нового солнца, If These Trees Could Talk, Lustre, Therion, LULU Suicide, Under LB, Mell |
| Doom Metal | `doom_metal` | LVL3 | Sons Of Otis, Paradise Lost, Tiamat, Woods Of Ypres, Blues Saraceno, Soen, Grave Disgrace, Darkher |
| Downtempo | `downtempo` | LVL3 | Thievery Corporation, Glenn Main, Shpongle, Morcheeba, Emancipator, Air, Five Seasons, Mark Pritchard, Velvet  |
| EBM | `ebm` | LVL3 | Gezebelle Gaburgably, Abney Park, Nitzer Ebb, Tulsi Devi, Everything Everything, Primal Scream, Bassvictim, DE |
| EDM | `edm` | LVL3 | Tiësto, Martin Garrix, Daft Punk, LCD Soundsystem, Dynoro, Kygo, Armin Van Buuren, Justice, Angèle |
| Easy Listening | `easy_listening` | LVL2 | Red Light Orchestra, НРГ, July Sax, Духовой Оркестр МВД СССР, Park Seong-Jin, Chet Atkins, Зодиак, Алексей Коз |
| Electro | `electro` | LVL3 | Virtuals, A-Trak, Metronomy, CMH, Hans Zimmer, Shirobon, The Chipmunks, GFOTY, MOONLGHT |
| Electro Swing | `electro_swing` | LVL3 | faverman, Ghost and Pals, HiiragiKirai, Caravan Palace, Jamie Berry, Drinnane, Black Gryph0n, Jules Gaia, FAKE |
| Emo Rap | `emo_rap` | LVL3 | FLESH, Lil Peep, дипинс, Кореш, Falling In Reverse, ЗимойБезШапки, Lil Uzi Vert, Arizona Zervas, Кишлак |
| Eurodance | `eurodance` | LVL3 | Secret Service, Digital Emotion, Black Box, E-Rotic, Oliver Tree, Lida, Mo-Do, Haddaway, The Italians |
| Folk Metal | `folk_metal` | LVL3 | Irdorath, Братство Атома, Lindsey Stirling, Хеменес, Darker than Dark, Curta'n Wall, Алькасар, Saltatio Mortis |
| Folk Pop | `folk_pop` | LVL3 | Дмитрий Журавлёв, El De Las R's, Белый День, Варвара, Katie Melua, Григорий Гладков, LP, Крыс, Alena Sviridova |
| Folk Rock | `folk_rock` | LVL3 | Leonard Cohen, Bob Dylan, Buffalo Springfield, Blackmore's Night, Пелагея, Donovan, Песняры, Калинов Мост |
| French House | `french_house` | LVL3 | L'Impératrice, Marie Davidson, Vive la Fête, Mount Sims, Indochine, Mr. Oizo, Modjo, Twenty 4 Seven, Reptile Y |
| Funk Rock | `funk_rock` | LVL3 | Fun Lovin' Criminals, Club des Belugas ft Ashley Slater, Дочь Монро и Кеннеди, Don Fardon, Infectious Grooves, |
| Future Bass | `future_bass` | LVL3 | Nevve, Terror, Aurora Night, idntt, Fourward, Lunax, Butch U, Тренировка и Спорт, Neovaii |
| Glam Metal | `glam_metal` | LVL3 | Europe, Def Leppard, Whitesnake, Warrant, ВИА Пламя, Steve Miller Band |
| Glitch | `glitch` | LVL3 | урал гайсин, Toby Fox, greyrock, Arca, Apparat, Bob Drake, Messer Chups, KAMZ0NER, Darren Korb |
| Gospel | `gospel` | LVL3 | Topsy Chapman, Marti Nikko, Larkin Poe, Jai-Jagdeesh, Poor Man's Poison, Moise Mbiye, James Ingram, Daniel Far |
| Gothic Metal | `gothic_metal` | LVL3 | Paradise Lost, Leaves’ Eyes, Tiamat, The Banshee, Draconian, Woods Of Ypres, High Parasite, Antimatter |
| Grime | `grime` | LVL3 | ELLM, Scrufizzer, Sola Project, Rose Gray, Kai Angel, Master Peace, The Streets, Freestylers, Wax Motif |
| Grunge | `grunge` | LVL3 | Santana, CUPSIZE, The HU, Pearl Jam, Daughtry, Nirvana, Soundgarden, Chris Cornell |
| Hard Rock | `hard_rock` | LVL3 | Ken Hensley, System of A Down, Nazareth, Lamb of God, Uriah Heep, Living Colour, UFO, Ozzy Osbourne, AC/DC |
| Hardbass | `hardbass` | LVL3 | Аржан Тодош, ШГШ, ZYZZCVNT, toshizou, Papa GOOO!, Коды воды, табурет, Hard Bass School |
| Hardcore Punk | `hardcore_punk` | LVL3 | Константин Ступин, Машнинбэнд, Финник, Последний Пионер, ТТ34, Toxic Lipstick, I Hate Sex, Иверия, ZАРЯДЪ |
| Heavy Metal | `heavy_metal` | LVL3 | Blindspott, Кипелов, Def Leppard, Чёрный кофе, Uriah Heep, Iron Maiden, Steel Panther, The Soundtrack Studio S |
| IDM | `idm` | LVL3 | Smile High, Moby, Boards of Canada, Bob Drake, Deep Forest, FKA twigs, David Bowie, Messer Chups, Darren Korb |
| Industrial | `industrial` | LVL3 | Nine Inch Nails, Orgy, Сергей Курёхин, Otto Dix, Dead Can Dance, Nick Cave, Death in June, Coil, Recoil |
| Industrial Metal | `industrial_metal` | LVL3 | Zior Park, Propellerheads, Extreme Hybrid Wrestling, Massive Ego, De Staat, Sigue Sigue Sputnik, Celldweller,  |
| Industrial Rock | `industrial_rock` | LVL3 | TommyMuzzic, Exfeind, Denis Dyakov, KMFDM, Einstürzende Neubauten, море лун, Manfred Mann's Earth Band, Elton  |
| Instrumental Hip-Hop | `instrumental_hip_hop` | LVL3 | Arca, Mo Anando, CFC, Moderator, Bill Laurance, Gordon, Badbadnotgood, Glimlip, D'va |
| J-pop | `j_pop` | LVL3 | Tatuya Ishii, Ado, 高橋洋子, 马卓冰, 井上あずみ, Kenshi Yonezu, fhana, YOASOBI |
| Jazz Fusion | `jazz_fusion` | LVL3 | Stereolab, Ghostface Killah, Portico Quartet, Tatuya Ishii, SuperSolar, Girls in Airports, egor kozlov, CASIOP |
| K-Rap | `k_rap` | LVL3 | Audrey Nuna, LE SSERAFIM, JENNIE, CORTIS, Stray Kids, KOCHNEVA, BABYMONSTER, Jay Park |
| Lo-Fi Hip-Hop | `lo_fi_hip_hop` | LVL3 | Nokiaa, Work Music, Gabin, Musickon, Lemon Jelly, Velvet Dreamer, Lofi Hip Hop, Pokesh, Knorozov |
| Lo-Fi House | `lo_fi_house` | LVL3 | Terekke |
| Lounge | `lounge` | LVL2 | Mirage of Deep, Gramatik, Ballet Music, Club Des Belugas, Enigma, The Cooltrane Quartet, The Smooth Ballroom B |
| Lullaby | `lullaby` | LVL3 | Детские колыбельные, Current 93, midnight.loop, Наталия Фаустова, Мишка Винни, Максим Калуцкий, Музыка для Фон |
| Mambo | `mambo` | LVL3 | Chuy Reyes, [dunkelbunt], Benny Dayal, Antoine Villoutreix, Masafumi Takada, Isaac, La Sonora Yarana-Rosa Mel, |
| Melodic Metal | `melodic_metal` | LVL3 | АТЭН, Святогора, Axel Rudi Pell, Wage War, Ария, Renivend, Toby Fox, Dark Tranquillity, The Unguided |
| Metalcore | `metalcore` | LVL3 | Jarrod Alonge, BRUTALLIZM, Glassjaw, Let Babylon Burn, Casey Edwards, Inexist, Angelmaker, The Limerick Rovers |
| Neo Classical | `neo_classical` | LVL3 | Vanessa-Mae, Sophie Hutchings, Hans Zimmer, Richard Wright, Escala, Ennio Morricone, Moby, Ryuichi Sakamoto, B |
| Neurofunk | `neurofunk` | LVL3 | Voss, Commix, Shpongle, V, Liquid Bass, Aphrodite, Rautu, MC Conrad, Fade Black |
| New Age | `new_age` | LVL3 | George Davidson, ДиДюЛя, Eve Beglarian, Дзен-Музыка, David Gilmour, Nature And Bird Sounds, Vangelis, Bruce Sp |
| New Wave | `new_wave` | LVL3 | Diorama, Blondie, Falco, Spandau Ballet, Bonnie Tyler, Belinda Carlisle, Nautilus Pompilius, Bronski Beat, Cul |
| Non-Music | `non_music` | LVL3 | Иеромонах Роман, Хор сестёр Свято-Елисаветинского монастыря, The Holy Quran (Koran) from QuranNow, ВОЛШЕБНАЯ Б |
| Pop Punk | `pop_punk` | LVL3 | 5 Seconds Of Summer, NateWantsToBattle, Джизус, Breesku & Nika De, Ber-linn, нексюша, ПокаЧтоНикто, Борщ и Нер |
| Pop Rap | `pop_rap` | LVL3 | БРЕДИШЬ, Джиган, C.ONE, Shohrux Ummon, Teriyaki Boyz, IShowSpeed, Баста, YOUNG POSSE, Uzmir |
| Pop Rock | `pop_rock` | LVL3 | The Oscar Peterson Trio, Поющие гитары, Electric Light Orchestra, Цветы, David Bowie, Billy Joel, John Lennon, |
| Post-Grunge | `post_grunge` | LVL3 | Shinedown, Oh The Larceny, Skull Liryx, Петля Пристрастия, Daughtry, Prime Circle, Nine Lashes, V O E |
| Post-Hardcore | `post_hardcore` | LVL3 | Title Fight, АНТ, НЕБОТОШНИТ, Texas is the Reason, VOVVA, sleperai, Vdoxnovin, Cyber Bard, vaswij |
| Post-Punk | `post_punk` | LVL3 | The Stranglers, Fontaines D.C., The Clash, Modern English, Telex, David Sylvian, Sleaford Mods, Yes, Killing J |
| Post-rock | `post_rock` | LVL3 | Коммерсанты, Slow Meadow, Sigur Rós, Анна Сегалис, God is an Astronaut, Mogwai, Ibrahim Maalouf, Guthrie Govan |
| Power Metal | `power_metal` | LVL3 | Cliff Richard, Sabaton, Inkubus Sukkubus, Ivan Torrent, Iron Savior, DragonForce, Sonata Arctica, Rhapsody Of  |
| Prog Rock | `prog_rock` | LVL3 | Electric Light Orchestra, King Crimson, Songs: Ohia, Procol Harum, Roger Waters, Girls in Airports, Archive, P |
| Progressive Metal | `progressive_metal` | LVL3 | Opeth, Guillaume Perret, Свет нового солнца, Manic Street Preachers, Black Mountain, Guilt Machine, NIGHT TRAV |
| Punk Rock | `punk_rock` | LVL3 | Talking Heads, Король и Шут, Nouvelle Vague, The Clash, Morfinng, Соломенные Еноты, Patti Smith, Ramones |
| Rap Rock | `rap_rock` | LVL3 | Dominic Fike, Gym Class Heroes, Кишлак, Bizzy Bone, Noize MC, Port Avenue, Mike Shinoda, A Broken Silence, J.  |
| Reggaeton | `reggaeton` | LVL3 | Simon Field, Daddy Yankee, Pitbull, Al Bano Carrisi, Jain, Наталья Подольская, Kokoshka, Jada Kingdom, Afro Ho |
| Religion | `religion` | LVL2 | Sasha Komovich, Hawk Nelson, Хор братии Валаамского монастыря, Новая Жизнь Music, Виктор Лавриненко, Purim mus |
| Romance | `romance` | LVL3 | Хибла Герзмава, Нани Брегвадзе, Владимир Трошин, Олег Погудин, Андрей Бандера, David Sylvian, Chip Wickham |
| Rumba | `rumba` | LVL3 | Koffie Olomide, Takagi & Ketra, Toto Guillaume, Férré Gola, Gipsy Kings, Didier Marouani, Supermax |
| Russian Bard | `russian_bard` | LVL3 | Григорий Данской, Павел Кашин, Игорь Савошинский, Мой двор, Сергей Тимошенко, Леонид Сергеев, Елена Фролова, Е |
| Russian Rock | `russian_rock` | LVL3 | Александр Лаэртский, Валерий Короп, Альянс, Павел Кашин, МультFильмы, Борис Гребенщиков, Патамушта, Aleksandr  |
| Salsa | `salsa` | LVL3 | Coro Rociero Hermandad de Coria, Montefiori Cocktail, Johannes Linstead, Олег Сарыглар, Ladaniva, 山根ミチル, La So |
| Samba | `samba` | LVL3 | Sambabook, Noriel Vilela, Marisa Monte, Jorge Ben Jor, Chico Band, Lucinha Bandeira, Alcione, Mikael Mutti |
| Singer-Songwriter | `singer_songwriter` | LVL2 | Сергей Никитин, Александр Розенбаум, Владимир Высоцкий, Булат Окуджава, Hazlett, Начало века, Юрий Визбор, Еле |
| Ska Punk | `ska_punk` | LVL3 | MILASH, Лорд Пневмослон, Ze Fish, In Extremo, Ritmos Latinos, Tony Holiday, Лампасы, COMEDOZ, The Hatters |
| Smooth Jazz | `smooth_jazz` | LVL3 | Slow Stantion, Reza Khan, Jonathan Fritzen, John Lawton, Brian Simpson, Rob Tardik, Kim and Buran, DarReec, Ка |
| Soul | `soul` | LVL3 | Sade, Charlotte Day Wilson, Aretha Franklin, Janis Joplin, Annie Lennox, Morgan Luna, Let Babylon Burn, Scott  |
| Soviet Music | `soviet_music` | LVL3 | Сергей Беликов, Аида Ведищева, Оля Рождественская, Микаэл Таривердиев, Сергей Старостин, Владимир Златоустовск |
| Space Rock | `space_rock` | LVL3 | Rockets, Peggy Lee, Giorgio Moroder |
| Surf Rock | `surf_rock` | LVL3 | Дмитрий Гусаров, Atsuko Hiyajo, Messer Chups, The Hillbilly Moon Explosion, Buddha Bar, Юрий Наумов, Сергей Ку |
| Swing | `swing` | LVL3 | Hazbin Hotel, Tape Five, Scott Bradlee's Postmodern Jukebox, Горькие усы, Squirrel Nut Zippers, Royal Crown Re |
| Symphonic Metal | `symphonic_metal` | LVL3 | Myth, Tarja, Catharsis, Laibach, Jackie Chan, UNREAL, Axel Rudi Pell, Within Temptation |
| Symphony | `symphony` | LVL3 | Howard Shore, James Hannigan, Игорь Корнелюк, Ennio Morricone, Ryuichi Sakamoto, Two Steps from Hell, Симфонич |
| Synthpop | `synthpop` | LVL3 | Superheart, Goldfrapp, Diorama, Kraftwerk, Eurythmics, Fury Weekend, Depeche Mode, Martin L. Gore, The Toxic A |
| Tech House | `tech_house` | LVL3 | Jake Daniels, Alec Troniq, Poylow, Mat.Joe, Panjabi MC, Райм, Telex, Burak Özan, Jackson 5 |
| Trap | `trap` | LVL3 | LXST CXNTURY, Фикс, Aarne,  Steve Lacy, Dodesz, Lubalin, L'Impératrice, SQWOZ BAB, Kai Angel |
| Underground Hip-Hop | `underground_hip_hop` | LVL3 | ГИО ПИКА, ХТБ, УННВ, whitek3d, Красное Дерево, AK47, METAN, M()eSTRo, Кровосток |
| Witch House | `witch_house` | LVL3 | The Banshee, SONYACHNA, NIVIRO, Salem Slut, cowboyclicker, yeule, Pastel Ghost, Snow Strippers, ENCASSATOR |
| World | `world` | LVL3 | Richard Thompson, Gipsy Kings, William Joseph, Krishna Das, Астемир Апанасов, Денис Майданов, Enigma, Медитати |

### Смешанное / соседний пул — 47 шт.

| жанр | слаг | уровень | примеры артистов |
|---|---|---|---|
| Acoustic Rock | `acoustic_rock` | LVL3 | Michael Bennett, Tony Lee King, Agalloch, Земфира, Коммунизм, alexgoffline, Дарья Чеботарева, Brazzaville |
| Afrobeats | `afrobeats` | LVL3 | LANA RAY, Ruwa Jin, Omega 256, CKay, The Second Voice, Alabina, Let Babylon Burn, Eir.M, Benjamin |
| Alternative Rock | `alternative_rock` | LVL3 | Stereophonics, Pearl Jam, Santana, Glass Beams, Justefunk Funk, Алексей Козлов, Nick Cave, Queens Of The Stone |
| Boogie-Woogie | `boogie_woogie` | LVL3 | Stevie Ray Vaughan and Double Trouble, Zz top, Eric Clapton, Tom Waits, Joe Bonamassa, Morgan Luna, Stevie Ray |
| Boom Bap | `boom_bap` | LVL3 | YOUNG POSSE, Line, Logic, STAFIEVSKAYA, Culture Beat, DJ.M@R [Massive Breakz], TLC, Carl Douglas, Roy Orbison |
| Brazilian Funk | `brazilian_funk` | LVL3 | Zumba Fitness, Vanessa Da Mata, Dj tz da zz, Pat Lok, Safety Trance, DJ Asul, Mc Rd, KEAN DYSSO, KXLXER |
| Britpop | `britpop` | LVL3 | Летучий Корабль, Noel Gallagher's High Flying Birds, Curve, Chick Corea, Donna Summer |
| Chill House | `chill_house` | LVL3 | Soul to Speak, Years, Віктор Павлік, Varvara Krasa, PHNTXM, Ladynsax, RILTIM, TASSO, Moonkids |
| Cloud Rap | `cloud_rap` | LVL3 | GONE.Fludd, LERAIIE, ONUKA, Jus P, ваня пиво, ZippO, Orbit, хинков, Sapfear |
| Country | `country` | LVL3 | Crash Test Dummies, Ryuichi Sakamoto, Morten Harket, Alan Parsons, Willie Nelson, Neil Young, Dave Gahan, Mart |
| Cumbia | `cumbia` | LVL3 | Чёрный Лукич & Летучие Рыбы, Katzenjammer, Elia, French Latino, Toto Cutugno, Talco, Los Angeles Negros, Юлия  |
| Dance | `dance` | LVL2 | Thievery Corporation, Gigi D'Agostino, UNKLE, Kraftwerk, The Flirts, Didier Marouani, Гунтис Везгайлис, Kim an |
| Dancehall | `dancehall` | LVL3 | INNA, Luna Orbit, Akhmedov, Alpha Blondy, Let Babylon Burn, P-Square, DJ Lava, John Holt |
| Dancehall Reggae | `dancehall_reggae` | LVL3 | Angie, SOJA, Выход, Dismantle, Playing for Change, Комитет охраны тепла, Jimmy Somerville, Fugees, Harry Nilss |
| Dark Ambient | `dark_ambient` | LVL3 | Air, Bombay dub Orchestra, Сергей Курёхин, Manfred Mann's Earth Band, Visage, Chris Joss, Nigel Stanford, Kyle |
| Deep House | `deep_house` | LVL3 | Maya Fadeeva, Club des Belugas, CREAM SODA, Lounge Music, Krister, Dynoro, Azimov, Glenn Main, DVN, Menda |
| Disco House | `disco_house` | LVL3 | Techno Project, Adex, Cat Vader, Nightcrawlers, MARI BLEN, REYVI, FERRIZA, Иван Дорн |
| Dream Pop | `dream_pop` | LVL3 | Superheart, Mia Nicolai, Sweet, Armin Van Buuren, Visage, Holly Humberstone, Heavenly, Fiona Apple, The Flamin |
| Drone | `drone` | LVL3 | Air, Bombay dub Orchestra, Manfred Mann's Earth Band, Сергей Курёхин, Bark Psychosis, Can, Chris Joss, Kyle Di |
| Drone Ambient | `drone_ambient` | LVL3 | Chris Benstead, Summoning, Panchiko, Murray Gold, Trudge, Asura, Agriculture, Morbid Angel, AK |
| Dub | `dub` | LVL3 | Sinan Özen, NMIXX, Thievery Corporation, Александр Литвиненко, Pure Negga, Stick Figure, Gone Gone Beyond, Kat |
| Experimental Electronic | `experimental_electronic` | LVL3 | Yosi Horikawa, Сергей Курёхин, Jim Morrison, Andreas Dorau, dyan dxddy, Blood On The Dance Floor, A. G. Cook,  |
| Flamenco | `flamenco` | LVL3 | Nordsø & Theill, Old Man’s Child, Estrella Morente, Takagi & Ketra, Emilie Autumn, Alabina, Shiro SAGISU, Gips |
| Groove Metal | `groove_metal` | LVL3 | Musashi Project, CFO$, Kill Shelter, Машнинбэнд, Гвоздодёр, Infant Annihilator, RADOPI, Son of the Dead Sun, C |
| Happy Hardcore | `happy_hardcore` | LVL3 | Aku P, Vampyx, Starving Trancer, Nayutalien, dennokop, S3rl, aki <3, WEDNESDAY CAMPANELLA, BBpanzu |
| Hard Techno | `hard_techno` | LVL3 | Moonshine, Alan Aztec, Confetti's, Police In Paris, стил, 8rings, XmegaLxl, slenderpill, RUDI B8 |
| Hardcore Techno | `hardcore_techno` | LVL3 | dismenki, Alan Aztec, Ночное Движение, Salem Slut, стил, Starving Trancer, DJ Hazard, Hard Bass School, Kensuk |
| Hyperpop | `hyperpop` | LVL3 | daryana, Лисса, Sqwore, Остап Парфёнов, SuperSolar, BBpanzu, Фикс, Lida, Or3o |
| Indie Pop | `indie_pop` | LVL3 | Таллис, BEARWOLF, Alice Merton, Musia Totibadze, polnalyubvi, Баста, Zero 7, The Macarons Project, Moby |
| K-pop | `k_pop` | LVL3 | Livingston, Chokirya, Sati Akura, Sam Tinnesz, Benson Boone, Диана Анкудинова, Anne-Marie, DLEJ, TAEMIN |
| Latin Jazz | `latin_jazz` | LVL3 | Марлины, Chuy Reyes, Can, Deise Costa, B-Tribe, United Melodies, Alex Lacamoire, WDR Big Band Köln, Montefiori |
| Medieval Metal | `medieval_metal` | LVL3 | Feuerschwanz, Saltatio Mortis, Dire Straits, Pink Floyd |
| Minimal Techno | `minimal_techno` | LVL3 | Primal Scream, Telex, Politics of Dancing, The Beloved, Rhinestone Ricky, Daniel Haaksman, Visage, Glenn Main, |
| Motown | `motown` | LVL3 | Kim and Buran, Dead or Alive, Talk Talk, Bill Withers, Janis Joplin, Patrice Rushen, Bee Gees, Etta James, Sad |
| Neofolk | `neofolk` | LVL3 | Richard Armitage, Cyber Bard, WoT Music Team, Death in June, Екатерина Тур, The Oscar Peterson Trio, Boney M. |
| Nu Jazz | `nu_jazz` | LVL3 | De-Phazz, Jazzamor, Peter White, The Who |
| Nu Metal | `nu_metal` | LVL3 | RADIO TAPOK, Kim Dracula, You Me At Six, 7000$, Linkin Park, Ravdina, Мегамозг, Broadus, Insolence |
| Phonk | `phonk` | LVL3 | DVRST, Butthole Surfers, Смешарики, Kordhell, Rouge Rouge, Angel, DJ Asul, Doğuş E. K., LXXD SXFFERING |
| Progressive Trance | `progressive_trance` | LVL3 | Complex Numbers, Gennadiy Adamenko, Republica, Yndling, Django Django, Daniel Lopatin, Robert Miles, Ladytron, |
| Rap | `rap` | LVL3 | Francis and the Lights, АИГЕЛ, tape joe, Little Simz, Lo-Fi Beats, Зараза, Afrika Bambaataa, Princess Nokia, E |
| Rapcore | `rapcore` | LVL3 | 5sta Family, Sero4ka, Lauren Sanderson, Molotov, U-TOPIA, Ringo Starr, Peter Gabriel |
| Reggae | `reggae` | LVL2 | Jah Divizion, The Housemartins, Madness, Zero 7, Supermax, Krister, Outlaw Ritual, Harry Belafonte, Top Cat |
| Rockabilly | `rockabilly` | LVL3 | Chris Isaak, The Beatles Recovered Band, Don McLean, Daryl Hall, That Handsome Devil, The Cog is Dead, Jeff Be |
| Slap House | `slap_house` | LVL3 | D.M.Music, VØNTAK, Nowakowski, POLI, Игнатий Винтуров, Suspicious Unicorn, Kristina Volodina, Imael Angel, Sha |
| Soft Rock | `soft_rock` | LVL3 | Вячеслав Малежик, Rockets, Whitesnake, Eagles, Mikhail Bennett, Pulp, The Starlight Orchestra, CHARTY |
| Techno | `techno` | LVL2 | Boris Brejcha, I Monster, Messer Chups, Spoon, Police In Paris, Children Slyness, Glenn Main, Crazy Music Chan |
| UK Garage | `uk_garage` | LVL3 | Sub Terra, ELLM, Scrufizzer, не совладал, токсичный ансамбль лягухо, Master Peace, PinkPantheress, Freestylers |

### Совпадает с широким жанром (parent-подмена) — 14 шт.

| жанр | слаг | уровень | примеры артистов |
|---|---|---|---|
| Acid Techno | `acid_techno` | LVL3 | Dead Can Dance, The Flirts, Daft Punk, Kraftwerk, Zodiac, Oxygene, Didier Marouani, Visage, Thievery Corporati |
| Avant Garde Jazz | `avant_garde_jazz` | LVL3 | Badbadnotgood, Tape Five, Mahala Rai Banda, JERRY'S SOUND ROOM, Fourplay, Eir.M, Royal Crown Revue, Shakira, Д |
| Baroque Pop | `baroque_pop` | LVL3 | a-ha, Kraftwerk, Donna Summer, Procol Harum, Красные маки, Eurythmics, Алла Пугачёва, Depeche Mode, Валерий Об |
| Blackgaze | `blackgaze` | LVL3 | Grave Digger, Whitesnake, Black Sabbath, Кипелов, Motörhead, Uriah Heep, The Soundtrack Studio Stars, Status Q |
| Free Jazz | `free_jazz` | LVL3 | Can, Tatuya Ishii, Girls in Airports, Badbadnotgood, Alex Lacamoire, CASIOPEA, Brian Simpson, Shakira, Дмитрий |
| Goa Trance | `goa_trance` | LVL3 | Dead Can Dance, The Flirts, Daft Punk, Kraftwerk, Zodiac, Oxygene, Didier Marouani, Visage, Thievery Corporati |
| Grindcore | `grindcore` | LVL3 | Grave Digger, Whitesnake, Black Sabbath, Кипелов, Motörhead, Uriah Heep, The Soundtrack Studio Stars, Dirkschn |
| Jungle/Drum'n'Bass | `jungle_drumnbass` | LVL3 | Dead Can Dance, Сергей Курёхин, The Flirts, Daft Punk, Kraftwerk, Zodiac, Oxygene, Didier Marouani, Thievery C |
| Mathcore | `mathcore` | LVL3 | Whitesnake, Кипелов, Motörhead, Cruachan, Uriah Heep, The Soundtrack Studio Stars, Status Quo, Dirkschneider |
| New Rave | `new_rave` | LVL3 | Thievery Corporation, Iren Lullaby, George Davidson, Зодиак, Morcheeba, Daft Punk, Moloko, Bruce Springsteen,  |
| Progressive Death Metal | `progressive_death_metal` | LVL3 | Grave Digger, Whitesnake, Кипелов, Motörhead, Uriah Heep, The Soundtrack Studio Stars, Status Quo, Dirkschneid |
| Ragtime | `ragtime` | LVL3 | Дмитрий Гусаров, Can, Brian Simpson, CASIOPEA, Girls in Airports, B-Tribe, DarReec, Shakira, Reza Khan |
| Screamo | `screamo` | LVL3 | Whitesnake, Кипелов, Motörhead, Cruachan, Uriah Heep, The Soundtrack Studio Stars, Status Quo, Dirkschneider |
| Symphonic Black Metal | `symphonic_black_metal` | LVL3 | Steve Miller Band, Grave Digger, Whitesnake, Cruachan, Uriah Heep, The Soundtrack Studio Stars, Status Quo, Di |

### Не работает: чужой пул — 18 шт.

| жанр | слаг | уровень | примеры артистов |
|---|---|---|---|
| Chiptune | `chiptune` | LVL3 | Mischäseri, The Starlight Orchestra, I Monster, Gold Rush Studio Orchestra, KVINKA, Pierre Thibault, Virtuals, |
| Comedy | `comedy` | LVL3 | Илюша, Don Padro, Михаил Задорнов, Gabin, Marcus Miller |
| Drill | `drill` | LVL3 | Johan, блэйзи?, SODA LUV, Gino, Baauer, ЕГОР КРИД, Zerrid, JAX, Brian Simpson |
| Future Garage | `future_garage` | LVL3 | Toma Polak, Riversilvers, David Gilmour, T. Rex |
| Hardcore | `hardcore` | LVL3 | vexsyn, Master CC, Сергей Минаев, The Faceless, Type O Negative, prodbykenny, Confetti's, Zimanova, Hardtekk |
| Jersey Club | `jersey_club` | LVL3 | Кира Тимралеева, Lil Uzi Vert, BEARWOLF, 74jzi, MEOVV, SQWOZ BAB, SkyCan, TAIL MASSAGE, WokkHelly |
| Karaoke | `karaoke` | LVL3 | Mozart Festival Orchestra, Pink Floyd, Electric Light Orchestra, Kraftwerk, Пётр Ильич Чайковский, Depeche Mod |
| Kizomba | `kizomba` | LVL3 | Los Lobos, Julio Iglesias, Erik Satie, Il Volo, Дмитрий Колтаков, Abdullah Ibrahim, Georg Friedrich Händel, Ch |
| Melodic Death Metal | `melodic_death_metal` | LVL3 | Mozart Festival Orchestra, Pink Floyd, Electric Light Orchestra, Kraftwerk, Пётр Ильич Чайковский, Владимир Сп |
| Opera | `opera` | LVL3 | Mozart Festival Orchestra, Pink Floyd, Electric Light Orchestra, Kraftwerk, Пётр Ильич Чайковский, Владимир Сп |
| Russian Rap | `russian_rap` | LVL3 | Pit Baumgartner, GENER8ION, Rouge Rouge, Velvet Dreamer, Dana, RUN DMC, Lofi Hip Hop, Work Music |
| Spoken Word | `spoken_word` | LVL3 | Nuckids, Православный молитвослов, SUGA, Gjeldrune, Enigma, Kunteynir, Мария Сунгурова, ночные грузчики, Олег  |
| Stoner Rock | `stoner_rock` | LVL3 | Mozart Festival Orchestra, Pink Floyd, Electric Light Orchestra, Kraftwerk, Алексей Рыбников, Yo-Yo Ma, Johann |
| Symphonic Rock | `symphonic_rock` | LVL3 | Kraftwerk, Electric Light Orchestra, Claudio Abbado, Pink Floyd, Johann Sebastian Bach, Владимир Федосеев, Fré |
| Tango | `tango` | LVL3 | Sampology, Hauser, Rodrigo, Jeanette, Richard Cheese, Erik Satie, Shigueru Umebayashi, William Joseph |
| Thrash Metal | `thrash_metal` | LVL3 | Ministry, Billy Morrison, Последний Пионер, Скворцы Степанова, Машнинбэнд, Toxic Lipstick, Jeff Russo, Led Zep |
| Trap Metal | `trap_metal` | LVL3 | Mozart Festival Orchestra, Kraftwerk, Pink Floyd, Electric Light Orchestra, Владимир Спиваков, Yo-Yo Ma, Johan |
| Turntablism | `turntablism` | LVL3 | RUN DMC, GENER8ION, Velvet Dreamer, Doechii, Dana, Tom Browne, Lofi Hip Hop, Work Music, Kon Kan |

## 7. Методические грабли (чтобы не повторять)

- `personalWaveContent` **стохастичен**: один и тот же запрос даёт разные треки. Одиночные пробы дают
  ложные выводы в обе стороны.
- Порог `getOnboardingGenres` не принимает `image_url` первым полем в некоторых комбинациях → 500
  «Invalid AST Node: undefined»; безопасно `{ genre_id title image_url }`.
- Мусорный слаг (`zzz_no_such_genre`) → HTTP 200 и обычный микс. Ошибки не будет никогда.
- Широкие жанры (`rock`, `pop`, `classical`) частично пересекаются с generic-пулом естественным образом —
  метрика по пересечению для них непригодна, нужна проверка артистов.

## 8. Реализация (2026-11-05)

Каталог перестал быть хардкодом из 13 позиций и стал единым источником для всех поверхностей.

**Состав:** 144 жанра, 7 семей — Рок и метал (47), Электроника (27), Фолк и мир (21),
Поп и ретро (16), Хип-хоп и R&B (16), Классика и атмосфера (11), Джаз и блюз (6).
Уровни: 13 `LVL1`, 9 `LVL2`, 122 `LVL3` — уровень хранится рядом со слагом, потому что
неверный уровень сервер молча игнорирует.

**Единый источник** — `Plugins::Zvuk::WaveSettings`:

| Функция | Назначение |
|---|---|
| `GENRE_FAMILIES` | 7 семей: `id`, i18n-ключ подписи |
| `GENRES` | 144 записи: `name`, `label`, `family`, `level` |
| `getCatalog($client)` | плоский список с разрешёнными подписями — для веба и JSON |
| `getCatalogByFamily($client, $selected)` | семьи с жанрами и флагом `selected` — для группировки |
| `countSelectedByFamily($selected)` | счётчики для первого уровня меню плеера |
| `getGenresByFamily($id)` | жанры одной семьи |
| `getGenreNames($slugs)` | payload для API с уровнем из каталога |
| `isKnownGenre($slug)` | валидация сохранённых настроек |

`WebHandlers.pm` и `Settings.pm` больше не собирают JSON сами — обе точки вызывают
`getCatalog()`. Прежние копии логики очистки жанров удалены: `loadSettings()` отбрасывает
всё, чего нет в каталоге.

**UI:**

- *Плееры:* первый уровень — семьи со счётчиком выбранных (`[x] Рок и метал (3)`), второй —
  жанры этой семьи. После переключения меню остаётся в той же семье; для `player_buttons`
  `nextWindow => 'refresh'` по-прежнему не ставится.
- *Веб/Material:* секции по семьям внутри карточки «Жанры», над ними поиск и счётчик
  выбранных. Название семьи — такой же овал: клик выбирает все жанры семьи, повторный клик
  снимает всю семью (частичный выбор показывается отдельным состоянием овала).
- *Material* получает данные через `getWaveSettings`: в ответ добавлены `family`, `level`,
  `family_label` у жанров и готовый блок `families`.

**Тесты:** `t/test_wave_genre_catalog.pl` (43 проверки: форма каталога, уровни в API-payload,
санитайзинг настроек, два уровня меню, возврат в семью, JSON-контракт);
`t/test_vfd_genres_knob.pl` обновлён под двухуровневое меню. Полный набор `t/` — зелёный.

### 8.1. Раскрытие семей и схлопывание payload

- В вебе у каждой семьи есть кнопка `+`/`−`; по умолчанию все семьи **закрыты**, видна только
  строка семьи (овал + счётчик `выбрано/всего`). Поиск временно раскрывает семьи с совпадениями.
- `getGenreNames()` схлопывает **полностью выбранную** семью в одну запись — представляющий слаг
  семьи и его уровень; частично выбранная семья уходит отдельными жанрами.

| Семья | Схлопывается в | Уровень |
|---|---|---|
| Рок и метал | `rock` | LVL1 |
| Электроника | `electronic` | LVL1 |
| Поп и ретро | `pop` | LVL1 |
| Хип-хоп и R&B | `hip_hop` | LVL1 |
| Джаз и блюз | `jazz` | LVL1 |
| Фолк и мир | `world` | LVL3 |
| Классика и атмосфера | `classical` | LVL1 |

**Компромисс:** схлопывание — это огрубление. Полный набор «Хип-хоп и R&B» уйдёт как `hip_hop`,
то есть без funk/soul/rnb; «Классика и атмосфера» — как `classical`, без ambient/lounge.
Если такое поведение нежелательно, этим двум семьям достаточно не задавать `slug` —
схлопывание для них отключится, остальные продолжат работать.
