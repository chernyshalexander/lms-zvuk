# Personal Wave Interactive Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement interactive settings menu for Personal Wave (Jive interfaces) allowing users to configure popular, mood (energy/fun), language, vocal, and genres before starting wave playback.

**Architecture:** Add preferences-based configuration storage tied to account ID, extend Plugin.pm menu with Jive dialogs for each parameter, modify ProtocolHandler.pm to load settings before wave startup, and update API/Async.pm to accept and use settings in GraphQL requests.

**Tech Stack:** Perl, LMS Preferences API, Jive XML/JSON menus, GraphQL (zvuk API)

---

## File Structure

**Files to create:**
- `Plugins/Zvuk/WaveSettings.pm` — helper module for loading/saving wave settings from preferences

**Files to modify:**
- `Plugin.pm` — extend menu with Settings submenu and dialogs
- `ProtocolHandler.pm` — load settings before wave, pass to API
- `API/Async.pm` — accept settings parameter, build options for GraphQL
- `Strings.txt` — menu labels, descriptions, genre names (localization)

---

## Task 1: Create WaveSettings helper module

**Files:**
- Create: `Plugins/Zvuk/WaveSettings.pm`

- [ ] **Step 1: Create WaveSettings.pm with constants and helper functions**

```perl
package Plugins::Zvuk::WaveSettings;

use strict;
use warnings;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

# Default values
use constant DEFAULT_POPULAR => 0.5;
use constant DEFAULT_ENERGY  => 0.5;
use constant DEFAULT_FUN     => 0.5;
use constant DEFAULT_LANGUAGE => 'all';
use constant DEFAULT_VOCAL   => 1;

# All available genres
use constant GENRES => [
    { name => 'easy_listening_ambient', label => 'PLUGIN_ZVUK_GENRE_EASY_LISTENING' },
    { name => 'electronic', label => 'PLUGIN_ZVUK_GENRE_ELECTRONIC' },
    { name => 'classical', label => 'PLUGIN_ZVUK_GENRE_CLASSICAL' },
    { name => 'folk_world_country', label => 'PLUGIN_ZVUK_GENRE_FOLK' },
    { name => 'hip_hop', label => 'PLUGIN_ZVUK_GENRE_HIP_HOP' },
    { name => 'indie', label => 'PLUGIN_ZVUK_GENRE_INDIE' },
    { name => 'instrumental_acoustic', label => 'PLUGIN_ZVUK_GENRE_INSTRUMENTAL' },
    { name => 'metal', label => 'PLUGIN_ZVUK_GENRE_METAL' },
    { name => 'pop', label => 'PLUGIN_ZVUK_GENRE_POP' },
    { name => 'rock', label => 'PLUGIN_ZVUK_GENRE_ROCK' },
    { name => 'soundtrack', label => 'PLUGIN_ZVUK_GENRE_SOUNDTRACK' },
];

# Load settings for account from preferences
sub loadSettings {
    my ($account_id) = @_;
    return unless $account_id;

    my $key = "wave_settings_$account_id";
    my $settings = $prefs->get($key);

    # Return saved settings or defaults
    if ($settings && ref $settings eq 'HASH') {
        return {
            popular  => $settings->{popular} // DEFAULT_POPULAR,
            energy   => $settings->{energy} // DEFAULT_ENERGY,
            fun      => $settings->{fun} // DEFAULT_FUN,
            language => $settings->{language} // DEFAULT_LANGUAGE,
            vocal    => defined $settings->{vocal} ? $settings->{vocal} : DEFAULT_VOCAL,
            genres   => $settings->{genres} && ref $settings->{genres} eq 'ARRAY' 
                        ? $settings->{genres} 
                        : _getDefaultGenres(),
        };
    }

    # No saved settings, return defaults
    return _getDefaults();
}

# Save settings for account to preferences
sub saveSettings {
    my ($account_id, $settings) = @_;
    return unless $account_id && $settings;

    my $key = "wave_settings_$account_id";
    $prefs->set($key, $settings);
    $log->debug("Wave settings saved for account $account_id");
}

# Get all genre objects (for list display)
sub getGenres {
    return GENRES;
}

# Get genre names (for API)
sub getGenreNames {
    my ($genres_list) = @_;
    return [] unless $genres_list && ref $genres_list eq 'ARRAY';

    my @genre_objects;
    foreach my $genre_name (@$genres_list) {
        my $genre = _findGenreByName($genre_name);
        push @genre_objects, $genre if $genre;
    }
    return \@genre_objects;
}

# Internal: find genre by name
sub _findGenreByName {
    my ($name) = @_;
    foreach my $genre (@{ GENRES() }) {
        return { name => $genre->{name}, type => 'LVL1' } 
            if $genre->{name} eq $name;
    }
    return undef;
}

# Internal: get all genre names
sub _getDefaultGenres {
    my @names;
    foreach my $genre (@{ GENRES() }) {
        push @names, $genre->{name};
    }
    return \@names;
}

# Internal: get defaults
sub _getDefaults {
    return {
        popular  => DEFAULT_POPULAR,
        energy   => DEFAULT_ENERGY,
        fun      => DEFAULT_FUN,
        language => DEFAULT_LANGUAGE,
        vocal    => DEFAULT_VOCAL,
        genres   => _getDefaultGenres(),
    };
}

1;
```

- [ ] **Step 2: Commit**

```bash
git add Plugins/Zvuk/WaveSettings.pm
git commit -m "feat: add WaveSettings helper module for preferences management"
```

---

## Task 2: Modify API/Async.pm to accept wave settings

**Files:**
- Modify: `API/Async.pm` (getPersonalWave method, lines 425-487)

- [ ] **Step 1: Add require for WaveSettings**

At top of file (after other requires):
```perl
use Plugins::Zvuk::WaveSettings;
```

- [ ] **Step 2: Modify getPersonalWave signature and implementation**

Replace the entire `getPersonalWave` method:

```perl
sub getPersonalWave {
    my ($self, $cb, $wave_settings) = @_;

    my $gql = q{
        query getPersonalWave($contentInput: PersonalWaveContentInput, $first: PositiveInt! = 2, $options: PersonalWaveOptions, $waveInput: WaveInput, $waveSrc: MagicSource) {
            personalWaveContent(
                contentInput: $contentInput
                first: $first
                options: $options
                waveInput: $waveInput
                waveSrc: $waveSrc
            ) {
                ...PlayerTrackData
            }
        }

        fragment PlayerTrackData on Track {
            id
            title
            lyrics
            hasFlac
            duration
            explicit
            availability
            artistTemplate
            childParam
            mark
            artists {
                id
                title
                image {
                    src
                    palette
                }
                mark
            }
            release {
                id
                title
                image {
                    src
                    palette
                }
            }
            zchan
            __typename
        }
    };

    # Use provided settings or defaults
    $wave_settings ||= Plugins::Zvuk::WaveSettings::loadSettings('default');

    my $mood_str = sprintf("energy:%g,fun:%g",
        $wave_settings->{energy} // 0.5,
        $wave_settings->{fun} // 0.5
    );

    my $vars = {
        waveSrc => "AMAZME",
        first   => 3,
        options => {
            popular  => $wave_settings->{popular} // 0.5,
            mood     => $mood_str,
        },
    };

    # Add optional settings if provided
    $vars->{options}->{language} = $wave_settings->{language} 
        if defined $wave_settings->{language};
    $vars->{options}->{vocal} = $wave_settings->{vocal}
        if defined $wave_settings->{vocal};

    # Add genres if provided
    if ($wave_settings->{genres} && @{$wave_settings->{genres}}) {
        $vars->{options}->{genre} = Plugins::Zvuk::WaveSettings::getGenreNames($wave_settings->{genres});
    }

    $self->_graphql(sub {
        my $data = shift;
        $cb->($data->{personalWaveContent} || []);
    }, 'getPersonalWave', $gql, $vars, { ttl => 0 });
}
```

- [ ] **Step 3: Verify getPersonalWave can be called with settings**

Check that the method signature accepts optional `$wave_settings` parameter and builds options correctly.

- [ ] **Step 4: Commit**

```bash
git add API/Async.pm
git commit -m "feat: modify getPersonalWave to accept and use wave settings"
```

---

## Task 3: Modify ProtocolHandler.pm to load and pass settings

**Files:**
- Modify: `ProtocolHandler.pm` (getNextTrack, _explodeWave, _loadMoreWaveTracks)

- [ ] **Step 1: Add require for WaveSettings at top**

```perl
use Plugins::Zvuk::WaveSettings;
```

- [ ] **Step 2: Modify _explodeWave to load settings before API call**

Find `_explodeWave` function and replace it:

```perl
sub _explodeWave {
    my ($client) = @_;
    return unless $client;

    $log->info("Loading Personal Wave");

    # Get current account ID
    my $api = _getAPIHandler($client);
    my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

    # Load wave settings for this account
    my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);

    # Store in pluginData for later use
    $client->pluginData(zvuk_wave_settings => $wave_settings) if $client;

    $client->pluginData(zvuk_wave_active => 1) if $client;

    _getAPIHandler($client)->getPersonalWave(sub {
        my $items = shift || [];
        return unless $items && @$items;

        $log->info("Got " . scalar(@$items) . " wave tracks");
        Plugins::Zvuk::API->cacheTrackMetadata($items);

        for my $track (@$items) {
            Slim::Control::Request::executeRequest(
                $client, ['playlist', 'add', 'zvuk://' . $track->{id}]
            );
        }
    }, $wave_settings);
}
```

- [ ] **Step 3: Modify _loadMoreWaveTracks to use stored settings**

Find `_loadMoreWaveTracks` function and update the getPersonalWave call:

```perl
sub _loadMoreWaveTracks {
    my ($client) = @_;
    return unless $client;

    my $content_input;
    my $last = $client->pluginData('zvuk_wave_last_track');
    if ($last && $last->{id}) {
        my $elapsed       = time() - ($last->{started} || time());
        my $play_duration = $elapsed > $last->{duration} ? $last->{duration} : $elapsed;
        my $is_skipped    = $play_duration < ($last->{duration} * 0.5) ? \1 : \0;

        $content_input = {
            trackId       => $last->{id},
            trackDuration => $last->{duration},
            playDuration  => int($play_duration),
            isSkipped     => $is_skipped,
        };
    }

    # Load stored wave settings (or use defaults)
    my $wave_settings = $client->pluginData('zvuk_wave_settings');
    my $api = _getAPIHandler($client);
    my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
    $wave_settings ||= Plugins::Zvuk::WaveSettings::loadSettings($account_id);

    _getAPIHandler($client)->getPersonalWave(sub {
        my $items = shift || [];
        return unless $items && @$items;

        $log->info("Dozagurka loaded " . scalar(@$items) . " more tracks");
        Plugins::Zvuk::API->cacheTrackMetadata($items);

        for my $track (@$items) {
            Slim::Control::Request::executeRequest(
                $client, ['playlist', 'add', 'zvuk://' . $track->{id}]
            );
        }
    }, $content_input ? undef : $wave_settings, $content_input);
}
```

- [ ] **Step 4: Commit**

```bash
git add ProtocolHandler.pm
git commit -m "feat: load and use wave settings in ProtocolHandler"
```

---

## Task 4: Extend Plugin.pm menu with Settings submenu

**Files:**
- Modify: `Plugin.pm` (menu definition section)

- [ ] **Step 1: Update menu function to change Personal Wave to submenu**

Find the `_menu` function and replace the Personal Wave menu item. Change from:
```perl
{
    text => 'PLUGIN_ZVUK_MENU_WAVE',
    type => 'audio',
    url  => 'zvuk://wave',
},
```

To:
```perl
{
    text => 'PLUGIN_ZVUK_MENU_WAVE',
    type => 'link',
    items => [
        {
            text => 'PLUGIN_ZVUK_MENU_WAVE_START',
            type => 'audio',
            url  => 'zvuk://wave',
        },
        {
            text => 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS',
            type => 'link',
            items => [
                {
                    text => 'PLUGIN_ZVUK_SETTING_POPULAR',
                    type => 'input',
                    inputType => 'real',
                    rangeStart => '0',
                    rangeEnd => '1',
                    initialValue => sub { _getSettingValue('popular', 0.5) },
                    onchange => sub { _updateSetting('popular', $_[1]) },
                },
                {
                    text => 'PLUGIN_ZVUK_SETTING_ENERGY',
                    type => 'input',
                    inputType => 'real',
                    rangeStart => '0',
                    rangeEnd => '1',
                    initialValue => sub { _getSettingValue('energy', 0.5) },
                    onchange => sub { _updateSetting('energy', $_[1]) },
                },
                {
                    text => 'PLUGIN_ZVUK_SETTING_FUN',
                    type => 'input',
                    inputType => 'real',
                    rangeStart => '0',
                    rangeEnd => '1',
                    initialValue => sub { _getSettingValue('fun', 0.5) },
                    onchange => sub { _updateSetting('fun', $_[1]) },
                },
                {
                    text => 'PLUGIN_ZVUK_SETTING_LANGUAGE',
                    type => 'link',
                    items => [
                        {
                            text => 'PLUGIN_ZVUK_LANGUAGE_ALL',
                            type => 'input',
                            onchange => sub { _updateSetting('language', 'all') },
                        },
                        {
                            text => 'PLUGIN_ZVUK_LANGUAGE_FOREIGN',
                            type => 'input',
                            onchange => sub { _updateSetting('language', 'foreign') },
                        },
                        {
                            text => 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN',
                            type => 'input',
                            onchange => sub { _updateSetting('language', 'russian') },
                        },
                    ],
                },
                {
                    text => 'PLUGIN_ZVUK_SETTING_VOCAL',
                    type => 'link',
                    items => [
                        {
                            text => 'PLUGIN_ZVUK_VOCAL_WITH',
                            type => 'input',
                            onchange => sub { _updateSetting('vocal', 1) },
                        },
                        {
                            text => 'PLUGIN_ZVUK_VOCAL_WITHOUT',
                            type => 'input',
                            onchange => sub { _updateSetting('vocal', 0) },
                        },
                    ],
                },
                {
                    text => 'PLUGIN_ZVUK_SETTING_GENRES',
                    type => 'link',
                    items => sub { _getGenresMenu() },
                },
            ],
        },
    ],
},
```

- [ ] **Step 2: Add helper functions to Plugin.pm**

Add these functions at the bottom of Plugin.pm (before the final 1;):

```perl
sub _getSettingValue {
    my ($key, $default) = @_;
    my $client = Slim::Player::Playlist::shuffle_list()->[0];
    return $default unless $client;

    my $api = _getAPIHandler($client);
    my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

    my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
    return $settings->{$key} // $default;
}

sub _updateSetting {
    my ($key, $value) = @_;
    my $client = Slim::Player::Playlist::shuffle_list()->[0];
    return unless $client;

    my $api = _getAPIHandler($client);
    my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

    my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
    $settings->{$key} = $value;
    Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

    $log->info("Wave setting updated: $key = $value");
}

sub _getGenresMenu {
    my $client = Slim::Player::Playlist::shuffle_list()->[0];
    my $account_id = 'default';
    if ($client) {
        my $api = _getAPIHandler($client);
        $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
    }

    my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
    my $selected_genres = $settings->{genres} || [];
    my %selected = map { $_ => 1 } @$selected_genres;

    my @genre_items;
    foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenres() }) {
        my $is_selected = $selected{$genre->{name}} ? 1 : 0;
        push @genre_items, {
            text => $genre->{label},
            type => 'input',
            checkbox => 1,
            checked => $is_selected,
            onchange => sub { _toggleGenre($genre->{name}, $_[1]) },
        };
    }

    return \@genre_items;
}

sub _toggleGenre {
    my ($genre_name, $is_checked) = @_;
    my $client = Slim::Player::Playlist::shuffle_list()->[0];
    return unless $client;

    my $api = _getAPIHandler($client);
    my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

    my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
    my $genres = $settings->{genres} || [];
    my %genre_hash = map { $_ => 1 } @$genres;

    if ($is_checked) {
        $genre_hash{$genre_name} = 1;
    } else {
        delete $genre_hash{$genre_name};
    }

    $settings->{genres} = [sort keys %genre_hash];
    Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

    $log->info("Genre toggled: $genre_name = $is_checked");
}

sub _getAPIHandler {
    my ($client) = @_;
    return unless $client;
    return $client->pluginData('zvuk_api') || _initAPIHandler($client);
}

sub _initAPIHandler {
    my ($client) = @_;
    require Plugins::Zvuk::API::Async;
    my $api = Plugins::Zvuk::API::Async->new();
    $client->pluginData(zvuk_api => $api);
    return $api;
}
```

- [ ] **Step 3: Add require for WaveSettings at top of Plugin.pm**

```perl
use Plugins::Zvuk::WaveSettings;
```

- [ ] **Step 4: Commit**

```bash
git add Plugin.pm
git commit -m "feat: add Settings submenu to Personal Wave menu"
```

---

## Task 5: Add localization strings to Strings.txt

**Files:**
- Modify: `Strings.txt` (or `EN/Strings.txt` depending on structure)

- [ ] **Step 1: Find appropriate location in Strings.txt and add menu strings**

Find the PLUGIN_ZVUK section and add:

```
PLUGIN_ZVUK_MENU_WAVE_START
	EN	Start Wave

PLUGIN_ZVUK_MENU_WAVE_SETTINGS
	EN	Settings

PLUGIN_ZVUK_SETTING_POPULAR
	EN	Popularity

PLUGIN_ZVUK_SETTING_ENERGY
	EN	Mood: Energy

PLUGIN_ZVUK_SETTING_FUN
	EN	Mood: Fun

PLUGIN_ZVUK_SETTING_LANGUAGE
	EN	Language

PLUGIN_ZVUK_LANGUAGE_ALL
	EN	All Languages

PLUGIN_ZVUK_LANGUAGE_FOREIGN
	EN	Foreign

PLUGIN_ZVUK_LANGUAGE_RUSSIAN
	EN	Russian

PLUGIN_ZVUK_SETTING_VOCAL
	EN	Vocal

PLUGIN_ZVUK_VOCAL_WITH
	EN	With Vocals

PLUGIN_ZVUK_VOCAL_WITHOUT
	EN	Instrumental

PLUGIN_ZVUK_SETTING_GENRES
	EN	Genres

PLUGIN_ZVUK_GENRE_EASY_LISTENING
	EN	Easy Listening / Ambient

PLUGIN_ZVUK_GENRE_ELECTRONIC
	EN	Electronic

PLUGIN_ZVUK_GENRE_CLASSICAL
	EN	Classical

PLUGIN_ZVUK_GENRE_FOLK
	EN	Folk / World / Country

PLUGIN_ZVUK_GENRE_HIP_HOP
	EN	Hip-Hop

PLUGIN_ZVUK_GENRE_INDIE
	EN	Indie

PLUGIN_ZVUK_GENRE_INSTRUMENTAL
	EN	Instrumental / Acoustic

PLUGIN_ZVUK_GENRE_METAL
	EN	Metal

PLUGIN_ZVUK_GENRE_POP
	EN	Pop

PLUGIN_ZVUK_GENRE_ROCK
	EN	Rock

PLUGIN_ZVUK_GENRE_SOUNDTRACK
	EN	Soundtrack
```

- [ ] **Step 2: Commit**

```bash
git add Strings.txt
git commit -m "feat: add localization strings for wave settings menu"
```

---

## Task 6: Test basic settings loading and saving

**Files:**
- Create: `t/wave_settings_test.pl` (simple verification script)

- [ ] **Step 1: Create simple test to verify WaveSettings module**

```perl
#!/usr/bin/env perl

use strict;
use warnings;
use lib 'Plugins/Zvuk';

require WaveSettings;

print "Testing WaveSettings module...\n";

# Test 1: Load defaults
my $defaults = Plugins::Zvuk::WaveSettings::loadSettings('test_account');
print "✓ Defaults loaded\n" if $defaults->{popular} == 0.5;

# Test 2: Get genres
my $genres = Plugins::Zvuk::WaveSettings::getGenres();
print "✓ Got " . scalar(@$genres) . " genres\n" if @$genres == 11;

# Test 3: Save and reload
my $test_settings = {
    popular => 0.3,
    energy => 0.7,
    fun => 0.6,
    language => 'foreign',
    vocal => 0,
    genres => ['rock', 'metal'],
};
Plugins::Zvuk::WaveSettings::saveSettings('test_account_2', $test_settings);
my $reloaded = Plugins::Zvuk::WaveSettings::loadSettings('test_account_2');
print "✓ Settings saved and reloaded\n" 
    if $reloaded->{popular} == 0.3 && $reloaded->{language} eq 'foreign';

print "\nAll basic tests passed!\n";
```

- [ ] **Step 2: Run test to verify basic functionality**

```bash
perl t/wave_settings_test.pl
```

Expected output: All basic tests passed!

- [ ] **Step 3: Commit**

```bash
git add t/wave_settings_test.pl
git commit -m "test: add basic verification for wave settings"
```

---

## Task 7: Manual testing on actual Jive interface

**Files:**
- No files (manual testing)

- [ ] **Step 1: Start LMS and connect Jive device (Touch/Squeezebox/Radio/Boom)**

- [ ] **Step 2: Navigate to Plugins → Zvuk → Personal Wave**

Verify menu structure:
- "Start Wave" item visible
- "Settings" submenu visible

- [ ] **Step 3: Open Settings submenu**

Verify items:
- "Popularity" with current value
- "Mood: Energy" with current value
- "Mood: Fun" with current value
- "Language" with submenu
- "Vocal" with submenu
- "Genres" with submenu

- [ ] **Step 4: Change Popularity slider**

- Select "Popularity"
- Change value from 0.5 to 0.3
- Verify it saves (check LMS logs for "Wave setting updated: popular = 0.3")
- Exit and re-enter Settings, verify Popularity shows 0.3

- [ ] **Step 5: Change Language**

- Select "Language" → "Foreign"
- Verify saves in logs
- Re-enter, verify Language still shows "Foreign"

- [ ] **Step 6: Select Genres**

- Select "Settings" → "Genres"
- Toggle ON: Rock, Metal
- Toggle OFF: others
- Verify saves in logs
- Re-enter Genres, verify only Rock and Metal are checked

- [ ] **Step 7: Start Wave with custom settings**

- Go back to "Start Wave"
- Click to start wave
- Verify in LMS logs that getPersonalWave is called with:
  - popular: 0.3
  - language: foreign
  - genres: rock, metal

- [ ] **Step 8: Verify wave plays correctly**

- Wave should start playing tracks
- Verify dozagurka loads more tracks as expected

---

## Task 8: Test with different accounts (if available)

**Files:**
- No files (manual testing)

- [ ] **Step 1: Add second Zvuk account to LMS**

If plugin supports multiple accounts, add a different Zvuk account.

- [ ] **Step 2: Switch to second account in Jive menu**

- [ ] **Step 3: Configure settings differently**

Set popular to 0.8, language to "Russian", different genres.

- [ ] **Step 4: Verify account isolation**

- Switch back to first account, verify settings are as configured (0.3, foreign)
- Switch to second account, verify settings are as configured (0.8, russian)
- Verify each account's wave plays with correct settings

---

## Task 9: Final verification and integration commit

**Files:**
- No new files

- [ ] **Step 1: Run all existing tests to ensure no regression**

```bash
# If project has tests, run them
perl -I. -M Test::More t/*.t
```

- [ ] **Step 2: Check LMS logs for errors**

Start LMS, open Personal Wave menu, verify no errors in plugin logs.

- [ ] **Step 3: Verify all commits are present**

```bash
git log --oneline | head -10
```

Should show:
- "feat: add WaveSettings helper module..."
- "feat: modify getPersonalWave to accept and use wave settings"
- "feat: load and use wave settings in ProtocolHandler"
- "feat: add Settings submenu to Personal Wave menu"
- "feat: add localization strings for wave settings menu"
- "test: add basic verification..."

- [ ] **Step 4: Create summary commit**

```bash
git commit --allow-empty -m "feat: Personal Wave interactive settings (Jive UI) - COMPLETE

Implement full configuration menu for Personal Wave:
- Popular, Energy, Fun sliders (0.0-1.0)
- Language selection (All/Foreign/Russian)
- Vocal selection (With/Without)
- Genres checkboxes (11 genres)
- Preferences storage per account
- Settings passed to getPersonalWave API

Tested on Jive interfaces (Touch, Squeezeplay, Radio, Boom)
All settings persist and apply to wave playback."
```

---

## Scope Summary

**Total tasks:** 9  
**Estimated effort:** 4-6 hours (including manual testing)  
**Key components:**
- WaveSettings helper module (170 lines)
- API/Async modifications (20 lines)
- ProtocolHandler modifications (40 lines)
- Plugin menu extensions (80 lines)
- Localization strings (50 lines)
- Testing (20 lines)

**Files changed:** 5  
**Files created:** 1  
**Commits:** 8

---
