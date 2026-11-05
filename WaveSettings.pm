package Plugins::Zvuk::WaveSettings;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

# Default values
use constant DEFAULT_POPULAR => 0.5;
use constant DEFAULT_ENERGY  => 0.5;
use constant DEFAULT_FUN     => 0.5;
use constant DEFAULT_LANGUAGE => 'all';
use constant DEFAULT_VOCAL   => 1;

# Genre families shown as the first level of the wave genre menu.
# `slug`/`level` name the genre used when every genre of the family is selected:
# the whole family then travels to the API as this single entry instead of N slugs.
use constant GENRE_FAMILIES => [
    { id => 'rock',       label => 'PLUGIN_ZVUK_GENRE_FAMILY_ROCK',       slug => 'rock',       level => 'LVL1' },
    { id => 'electronic', label => 'PLUGIN_ZVUK_GENRE_FAMILY_ELECTRONIC', slug => 'electronic', level => 'LVL1' },
    { id => 'pop',        label => 'PLUGIN_ZVUK_GENRE_FAMILY_POP',        slug => 'pop',        level => 'LVL1' },
    { id => 'urban',      label => 'PLUGIN_ZVUK_GENRE_FAMILY_URBAN',      slug => 'hip_hop',    level => 'LVL1' },
    { id => 'jazz',       label => 'PLUGIN_ZVUK_GENRE_FAMILY_JAZZ',       slug => 'jazz',       level => 'LVL1' },
    { id => 'world',      label => 'PLUGIN_ZVUK_GENRE_FAMILY_WORLD',      slug => 'world',      level => 'LVL3' },
    { id => 'calm',       label => 'PLUGIN_ZVUK_GENRE_FAMILY_CALM',       slug => 'classical',  level => 'LVL1' },
];

# Each genre carries the recommender level (LVL1 broad, LVL2/LVL3 sub-genres).
# A wrong level is silently ignored by the API, so it must live next to the slug.
use constant GENRES => [
    { name => 'rock', label => 'PLUGIN_ZVUK_GENRE_ROCK', family => 'rock', level => 'LVL1' },
    { name => 'metal', label => 'PLUGIN_ZVUK_GENRE_METAL', family => 'rock', level => 'LVL1' },
    { name => 'indie', label => 'PLUGIN_ZVUK_GENRE_INDIE', family => 'rock', level => 'LVL1' },
    { name => 'alternative_metal', label => 'PLUGIN_ZVUK_GENRE_ALTERNATIVE_METAL', family => 'rock', level => 'LVL3' },
    { name => 'anatolian_rock', label => 'PLUGIN_ZVUK_GENRE_ANATOLIAN_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'art_rock', label => 'PLUGIN_ZVUK_GENRE_ART_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'christian_rock', label => 'PLUGIN_ZVUK_GENRE_CHRISTIAN_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'classic_rock', label => 'PLUGIN_ZVUK_GENRE_CLASSIC_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'death_metal', label => 'PLUGIN_ZVUK_GENRE_DEATH_METAL', family => 'rock', level => 'LVL3' },
    { name => 'deathcore', label => 'PLUGIN_ZVUK_GENRE_DEATHCORE', family => 'rock', level => 'LVL3' },
    { name => 'djent', label => 'PLUGIN_ZVUK_GENRE_DJENT', family => 'rock', level => 'LVL3' },
    { name => 'doom_metal', label => 'PLUGIN_ZVUK_GENRE_DOOM_METAL', family => 'rock', level => 'LVL3' },
    { name => 'folk_metal', label => 'PLUGIN_ZVUK_GENRE_FOLK_METAL', family => 'rock', level => 'LVL3' },
    { name => 'folk_rock', label => 'PLUGIN_ZVUK_GENRE_FOLK_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'funk_rock', label => 'PLUGIN_ZVUK_GENRE_FUNK_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'garage_rock', label => 'PLUGIN_ZVUK_GENRE_GARAGE_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'glam_metal', label => 'PLUGIN_ZVUK_GENRE_GLAM_METAL', family => 'rock', level => 'LVL3' },
    { name => 'gothic_metal', label => 'PLUGIN_ZVUK_GENRE_GOTHIC_METAL', family => 'rock', level => 'LVL3' },
    { name => 'gothic_rock', label => 'PLUGIN_ZVUK_GENRE_GOTHIC_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'grunge', label => 'PLUGIN_ZVUK_GENRE_GRUNGE', family => 'rock', level => 'LVL3' },
    { name => 'hard_rock', label => 'PLUGIN_ZVUK_GENRE_HARD_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'hardcore_punk', label => 'PLUGIN_ZVUK_GENRE_HARDCORE_PUNK', family => 'rock', level => 'LVL3' },
    { name => 'heavy_metal', label => 'PLUGIN_ZVUK_GENRE_HEAVY_METAL', family => 'rock', level => 'LVL3' },
    { name => 'indie_rock', label => 'PLUGIN_ZVUK_GENRE_INDIE_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'industrial_metal', label => 'PLUGIN_ZVUK_GENRE_INDUSTRIAL_METAL', family => 'rock', level => 'LVL3' },
    { name => 'industrial_rock', label => 'PLUGIN_ZVUK_GENRE_INDUSTRIAL_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'j_rock', label => 'PLUGIN_ZVUK_GENRE_J_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'melodic_metal', label => 'PLUGIN_ZVUK_GENRE_MELODIC_METAL', family => 'rock', level => 'LVL3' },
    { name => 'metalcore', label => 'PLUGIN_ZVUK_GENRE_METALCORE', family => 'rock', level => 'LVL3' },
    { name => 'pop_punk', label => 'PLUGIN_ZVUK_GENRE_POP_PUNK', family => 'rock', level => 'LVL3' },
    { name => 'pop_rock', label => 'PLUGIN_ZVUK_GENRE_POP_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'post_grunge', label => 'PLUGIN_ZVUK_GENRE_POST_GRUNGE', family => 'rock', level => 'LVL3' },
    { name => 'post_hardcore', label => 'PLUGIN_ZVUK_GENRE_POST_HARDCORE', family => 'rock', level => 'LVL3' },
    { name => 'post_punk', label => 'PLUGIN_ZVUK_GENRE_POST_PUNK', family => 'rock', level => 'LVL3' },
    { name => 'post_rock', label => 'PLUGIN_ZVUK_GENRE_POST_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'power_metal', label => 'PLUGIN_ZVUK_GENRE_POWER_METAL', family => 'rock', level => 'LVL3' },
    { name => 'prog_rock', label => 'PLUGIN_ZVUK_GENRE_PROG_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'progressive_metal', label => 'PLUGIN_ZVUK_GENRE_PROGRESSIVE_METAL', family => 'rock', level => 'LVL3' },
    { name => 'psychedelic_rock', label => 'PLUGIN_ZVUK_GENRE_PSYCHEDELIC_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'punk_rock', label => 'PLUGIN_ZVUK_GENRE_PUNK_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'russian_rock', label => 'PLUGIN_ZVUK_GENRE_RUSSIAN_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'shoegaze', label => 'PLUGIN_ZVUK_GENRE_SHOEGAZE', family => 'rock', level => 'LVL3' },
    { name => 'ska', label => 'PLUGIN_ZVUK_GENRE_SKA', family => 'rock', level => 'LVL3' },
    { name => 'ska_punk', label => 'PLUGIN_ZVUK_GENRE_SKA_PUNK', family => 'rock', level => 'LVL3' },
    { name => 'space_rock', label => 'PLUGIN_ZVUK_GENRE_SPACE_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'surf_rock', label => 'PLUGIN_ZVUK_GENRE_SURF_ROCK', family => 'rock', level => 'LVL3' },
    { name => 'symphonic_metal', label => 'PLUGIN_ZVUK_GENRE_SYMPHONIC_METAL', family => 'rock', level => 'LVL3' },
    { name => 'electronic', label => 'PLUGIN_ZVUK_GENRE_ELECTRONIC', family => 'electronic', level => 'LVL1' },
    { name => 'breakbeat_breaks', label => 'PLUGIN_ZVUK_GENRE_BREAKBEAT_BREAKS', family => 'electronic', level => 'LVL3' },
    { name => 'breakcore', label => 'PLUGIN_ZVUK_GENRE_BREAKCORE', family => 'electronic', level => 'LVL3' },
    { name => 'chillwave', label => 'PLUGIN_ZVUK_GENRE_CHILLWAVE', family => 'electronic', level => 'LVL3' },
    { name => 'darkwave', label => 'PLUGIN_ZVUK_GENRE_DARKWAVE', family => 'electronic', level => 'LVL3' },
    { name => 'digital_hardcore', label => 'PLUGIN_ZVUK_GENRE_DIGITAL_HARDCORE', family => 'electronic', level => 'LVL3' },
    { name => 'downtempo', label => 'PLUGIN_ZVUK_GENRE_DOWNTEMPO', family => 'electronic', level => 'LVL3' },
    { name => 'dubstep', label => 'PLUGIN_ZVUK_GENRE_DUBSTEP', family => 'electronic', level => 'LVL3' },
    { name => 'ebm', label => 'PLUGIN_ZVUK_GENRE_EBM', family => 'electronic', level => 'LVL3' },
    { name => 'edm', label => 'PLUGIN_ZVUK_GENRE_EDM', family => 'electronic', level => 'LVL3' },
    { name => 'electro', label => 'PLUGIN_ZVUK_GENRE_ELECTRO', family => 'electronic', level => 'LVL3' },
    { name => 'french_house', label => 'PLUGIN_ZVUK_GENRE_FRENCH_HOUSE', family => 'electronic', level => 'LVL3' },
    { name => 'future_bass', label => 'PLUGIN_ZVUK_GENRE_FUTURE_BASS', family => 'electronic', level => 'LVL3' },
    { name => 'future_funk', label => 'PLUGIN_ZVUK_GENRE_FUTURE_FUNK', family => 'electronic', level => 'LVL3' },
    { name => 'glitch', label => 'PLUGIN_ZVUK_GENRE_GLITCH', family => 'electronic', level => 'LVL3' },
    { name => 'hardbass', label => 'PLUGIN_ZVUK_GENRE_HARDBASS', family => 'electronic', level => 'LVL3' },
    { name => 'house', label => 'PLUGIN_ZVUK_GENRE_HOUSE', family => 'electronic', level => 'LVL2' },
    { name => 'idm', label => 'PLUGIN_ZVUK_GENRE_IDM', family => 'electronic', level => 'LVL3' },
    { name => 'industrial', label => 'PLUGIN_ZVUK_GENRE_INDUSTRIAL', family => 'electronic', level => 'LVL3' },
    { name => 'lo_fi_house', label => 'PLUGIN_ZVUK_GENRE_LO_FI_HOUSE', family => 'electronic', level => 'LVL3' },
    { name => 'neurofunk', label => 'PLUGIN_ZVUK_GENRE_NEUROFUNK', family => 'electronic', level => 'LVL3' },
    { name => 'progressive_house', label => 'PLUGIN_ZVUK_GENRE_PROGRESSIVE_HOUSE', family => 'electronic', level => 'LVL3' },
    { name => 'synthwave', label => 'PLUGIN_ZVUK_GENRE_SYNTHWAVE', family => 'electronic', level => 'LVL3' },
    { name => 'tech_house', label => 'PLUGIN_ZVUK_GENRE_TECH_HOUSE', family => 'electronic', level => 'LVL3' },
    { name => 'trance', label => 'PLUGIN_ZVUK_GENRE_TRANCE', family => 'electronic', level => 'LVL3' },
    { name => 'trip_hop', label => 'PLUGIN_ZVUK_GENRE_TRIP_HOP', family => 'electronic', level => 'LVL3' },
    { name => 'witch_house', label => 'PLUGIN_ZVUK_GENRE_WITCH_HOUSE', family => 'electronic', level => 'LVL3' },
    { name => 'pop', label => 'PLUGIN_ZVUK_GENRE_POP', family => 'pop', level => 'LVL1' },
    { name => 'alternative_pop', label => 'PLUGIN_ZVUK_GENRE_ALTERNATIVE_POP', family => 'pop', level => 'LVL3' },
    { name => 'art_pop', label => 'PLUGIN_ZVUK_GENRE_ART_POP', family => 'pop', level => 'LVL3' },
    { name => 'bedroom_pop', label => 'PLUGIN_ZVUK_GENRE_BEDROOM_POP', family => 'pop', level => 'LVL3' },
    { name => 'c_pop', label => 'PLUGIN_ZVUK_GENRE_C_POP', family => 'pop', level => 'LVL3' },
    { name => 'children', label => 'PLUGIN_ZVUK_GENRE_CHILDREN', family => 'pop', level => 'LVL3' },
    { name => 'city_pop', label => 'PLUGIN_ZVUK_GENRE_CITY_POP', family => 'pop', level => 'LVL3' },
    { name => 'disco', label => 'PLUGIN_ZVUK_GENRE_DISCO', family => 'pop', level => 'LVL2' },
    { name => 'electro_swing', label => 'PLUGIN_ZVUK_GENRE_ELECTRO_SWING', family => 'pop', level => 'LVL3' },
    { name => 'estrada', label => 'PLUGIN_ZVUK_GENRE_ESTRADA', family => 'pop', level => 'LVL3' },
    { name => 'eurodance', label => 'PLUGIN_ZVUK_GENRE_EURODANCE', family => 'pop', level => 'LVL3' },
    { name => 'italo_disco', label => 'PLUGIN_ZVUK_GENRE_ITALO_DISCO', family => 'pop', level => 'LVL3' },
    { name => 'j_pop', label => 'PLUGIN_ZVUK_GENRE_J_POP', family => 'pop', level => 'LVL3' },
    { name => 'new_wave', label => 'PLUGIN_ZVUK_GENRE_NEW_WAVE', family => 'pop', level => 'LVL3' },
    { name => 'nu_disco', label => 'PLUGIN_ZVUK_GENRE_NU_DISCO', family => 'pop', level => 'LVL3' },
    { name => 'synthpop', label => 'PLUGIN_ZVUK_GENRE_SYNTHPOP', family => 'pop', level => 'LVL3' },
    { name => 'hip_hop', label => 'PLUGIN_ZVUK_GENRE_HIP_HOP', family => 'urban', level => 'LVL1' },
    { name => 'brazilian_phonk', label => 'PLUGIN_ZVUK_GENRE_BRAZILIAN_PHONK', family => 'urban', level => 'LVL3' },
    { name => 'emo_rap', label => 'PLUGIN_ZVUK_GENRE_EMO_RAP', family => 'urban', level => 'LVL3' },
    { name => 'funk', label => 'PLUGIN_ZVUK_GENRE_FUNK', family => 'urban', level => 'LVL2' },
    { name => 'grime', label => 'PLUGIN_ZVUK_GENRE_GRIME', family => 'urban', level => 'LVL3' },
    { name => 'instrumental_hip_hop', label => 'PLUGIN_ZVUK_GENRE_INSTRUMENTAL_HIP_HOP', family => 'urban', level => 'LVL3' },
    { name => 'k_rap', label => 'PLUGIN_ZVUK_GENRE_K_RAP', family => 'urban', level => 'LVL3' },
    { name => 'lo_fi_hip_hop', label => 'PLUGIN_ZVUK_GENRE_LO_FI_HIP_HOP', family => 'urban', level => 'LVL3' },
    { name => 'neo_soul', label => 'PLUGIN_ZVUK_GENRE_NEO_SOUL', family => 'urban', level => 'LVL3' },
    { name => 'pop_rap', label => 'PLUGIN_ZVUK_GENRE_POP_RAP', family => 'urban', level => 'LVL3' },
    { name => 'rap_rock', label => 'PLUGIN_ZVUK_GENRE_RAP_ROCK', family => 'urban', level => 'LVL3' },
    { name => 'reggaeton', label => 'PLUGIN_ZVUK_GENRE_REGGAETON', family => 'urban', level => 'LVL3' },
    { name => 'rnb', label => 'PLUGIN_ZVUK_GENRE_RNB', family => 'urban', level => 'LVL3' },
    { name => 'soul', label => 'PLUGIN_ZVUK_GENRE_SOUL', family => 'urban', level => 'LVL3' },
    { name => 'trap', label => 'PLUGIN_ZVUK_GENRE_TRAP', family => 'urban', level => 'LVL3' },
    { name => 'underground_hip_hop', label => 'PLUGIN_ZVUK_GENRE_UNDERGROUND_HIP_HOP', family => 'urban', level => 'LVL3' },
    { name => 'jazz', label => 'PLUGIN_ZVUK_GENRE_JAZZ', family => 'jazz', level => 'LVL1' },
    { name => 'bebop', label => 'PLUGIN_ZVUK_GENRE_BEBOP', family => 'jazz', level => 'LVL3' },
    { name => 'gospel', label => 'PLUGIN_ZVUK_GENRE_GOSPEL', family => 'jazz', level => 'LVL3' },
    { name => 'jazz_fusion', label => 'PLUGIN_ZVUK_GENRE_JAZZ_FUSION', family => 'jazz', level => 'LVL3' },
    { name => 'smooth_jazz', label => 'PLUGIN_ZVUK_GENRE_SMOOTH_JAZZ', family => 'jazz', level => 'LVL3' },
    { name => 'swing', label => 'PLUGIN_ZVUK_GENRE_SWING', family => 'jazz', level => 'LVL3' },
    { name => 'latin', label => 'PLUGIN_ZVUK_GENRE_LATIN', family => 'world', level => 'LVL1' },
    { name => 'folk_world_country', label => 'PLUGIN_ZVUK_GENRE_FOLK_WORLD_COUNTRY', family => 'world', level => 'LVL1' },
    { name => 'afrobeat', label => 'PLUGIN_ZVUK_GENRE_AFROBEAT', family => 'world', level => 'LVL3' },
    { name => 'bollywood', label => 'PLUGIN_ZVUK_GENRE_BOLLYWOOD', family => 'world', level => 'LVL3' },
    { name => 'bossa_nova', label => 'PLUGIN_ZVUK_GENRE_BOSSA_NOVA', family => 'world', level => 'LVL3' },
    { name => 'chanson', label => 'PLUGIN_ZVUK_GENRE_CHANSON', family => 'world', level => 'LVL2' },
    { name => 'christian', label => 'PLUGIN_ZVUK_GENRE_CHRISTIAN', family => 'world', level => 'LVL3' },
    { name => 'dark_folk', label => 'PLUGIN_ZVUK_GENRE_DARK_FOLK', family => 'world', level => 'LVL3' },
    { name => 'folk', label => 'PLUGIN_ZVUK_GENRE_FOLK', family => 'world', level => 'LVL2' },
    { name => 'folk_pop', label => 'PLUGIN_ZVUK_GENRE_FOLK_POP', family => 'world', level => 'LVL3' },
    { name => 'mambo', label => 'PLUGIN_ZVUK_GENRE_MAMBO', family => 'world', level => 'LVL3' },
    { name => 'non_music', label => 'PLUGIN_ZVUK_GENRE_NON_MUSIC', family => 'world', level => 'LVL3' },
    { name => 'religion', label => 'PLUGIN_ZVUK_GENRE_RELIGION', family => 'world', level => 'LVL2' },
    { name => 'romance', label => 'PLUGIN_ZVUK_GENRE_ROMANCE', family => 'world', level => 'LVL3' },
    { name => 'rumba', label => 'PLUGIN_ZVUK_GENRE_RUMBA', family => 'world', level => 'LVL3' },
    { name => 'russian_bard', label => 'PLUGIN_ZVUK_GENRE_RUSSIAN_BARD', family => 'world', level => 'LVL3' },
    { name => 'salsa', label => 'PLUGIN_ZVUK_GENRE_SALSA', family => 'world', level => 'LVL3' },
    { name => 'samba', label => 'PLUGIN_ZVUK_GENRE_SAMBA', family => 'world', level => 'LVL3' },
    { name => 'singer_songwriter', label => 'PLUGIN_ZVUK_GENRE_SINGER_SONGWRITER', family => 'world', level => 'LVL2' },
    { name => 'soviet_music', label => 'PLUGIN_ZVUK_GENRE_SOVIET_MUSIC', family => 'world', level => 'LVL3' },
    { name => 'world', label => 'PLUGIN_ZVUK_GENRE_WORLD', family => 'world', level => 'LVL3' },
    { name => 'classical', label => 'PLUGIN_ZVUK_GENRE_CLASSICAL', family => 'calm', level => 'LVL1' },
    { name => 'easy_listening_ambient', label => 'PLUGIN_ZVUK_GENRE_EASY_LISTENING_AMBIENT', family => 'calm', level => 'LVL1' },
    { name => 'instrumental_acoustic', label => 'PLUGIN_ZVUK_GENRE_INSTRUMENTAL_ACOUSTIC', family => 'calm', level => 'LVL1' },
    { name => 'soundtrack', label => 'PLUGIN_ZVUK_GENRE_SOUNDTRACK', family => 'calm', level => 'LVL1' },
    { name => 'ambient', label => 'PLUGIN_ZVUK_GENRE_AMBIENT', family => 'calm', level => 'LVL3' },
    { name => 'easy_listening', label => 'PLUGIN_ZVUK_GENRE_EASY_LISTENING', family => 'calm', level => 'LVL2' },
    { name => 'lounge', label => 'PLUGIN_ZVUK_GENRE_LOUNGE', family => 'calm', level => 'LVL2' },
    { name => 'lullaby', label => 'PLUGIN_ZVUK_GENRE_LULLABY', family => 'calm', level => 'LVL3' },
    { name => 'neo_classical', label => 'PLUGIN_ZVUK_GENRE_NEO_CLASSICAL', family => 'calm', level => 'LVL3' },
    { name => 'new_age', label => 'PLUGIN_ZVUK_GENRE_NEW_AGE', family => 'calm', level => 'LVL3' },
    { name => 'symphony', label => 'PLUGIN_ZVUK_GENRE_SYMPHONY', family => 'calm', level => 'LVL3' },
];

# Lookup tables built once per process
my %GENRE_BY_NAME = map { $_->{name} => $_ } @{ GENRES() };
my %FAMILY_BY_ID  = map { $_->{id}   => $_ } @{ GENRE_FAMILIES() };

# Load settings for account from preferences
sub loadSettings {
    my ($account_id) = @_;
    return unless $account_id;

    my $key = "wave_settings_$account_id";
    my $settings = $prefs->get($key);

    # Return saved settings or defaults
    if ($settings && ref $settings eq 'HASH') {
        # Clean up invalid genres (e.g., template variables from old saves)
        my $saved_genres = $settings->{genres};
        my @cleaned_genres;

        if ($saved_genres && ref $saved_genres eq 'ARRAY') {
            foreach my $g (@$saved_genres) {
                # Keep only catalog slugs: this drops template variables from old
                # saves, unknown/obsolete genres, and anything a hand-edited pref
                # (or an older version of the catalog) left behind.
                push @cleaned_genres, $g if isKnownGenre($g);
            }
        }

        return {
            popular  => $settings->{popular} // DEFAULT_POPULAR,
            energy   => $settings->{energy} // DEFAULT_ENERGY,
            fun      => $settings->{fun} // DEFAULT_FUN,
            language => $settings->{language} // DEFAULT_LANGUAGE,
            vocal    => defined $settings->{vocal} ? $settings->{vocal} : DEFAULT_VOCAL,
            genres   => \@cleaned_genres,  # Return only selected genres, empty if none
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

# Get all families, in menu order
sub getFamilies {
    return GENRE_FAMILIES;
}

# Genres of one family, in catalog order; empty list for an unknown family
sub getGenresByFamily {
    my ($family) = @_;
    return [] unless defined $family && $FAMILY_BY_ID{$family};
    return [ grep { $_->{family} eq $family } @{ GENRES() } ];
}

# The single catalog payload every surface renders. Resolves each label with the
# client's locale when a client is given, otherwise with the server locale.
# Returns [{ name, label, family, family_label, level }, ...]
sub getCatalog {
    my ($client) = @_;

    my %family_label;
    foreach my $family (@{ GENRE_FAMILIES() }) {
        $family_label{ $family->{id} } = _resolve_label($family->{label}, $client);
    }

    return [
        map {
            {
                name         => $_->{name},
                label        => _resolve_label($_->{label}, $client),
                family       => $_->{family},
                family_label => $family_label{ $_->{family} },
                level        => $_->{level},
            }
        } @{ GENRES() }
    ];
}

# Families with their genres, for the two-level menu and the grouped web view.
# Returns [{ id, label, genres => [{ name, label, level, selected }] }, ...]
sub getCatalogByFamily {
    my ($client, $selected) = @_;

    my %selected = map { $_ => 1 } @{ $selected || [] };
    my @out;

    foreach my $family (@{ GENRE_FAMILIES() }) {
        my @genres = map {
            {
                name     => $_->{name},
                label    => _resolve_label($_->{label}, $client),
                level    => $_->{level},
                selected => $selected{ $_->{name} } ? 1 : 0,
            }
        } @{ getGenresByFamily($family->{id}) };
        next unless @genres;
        push @out, {
            id     => $family->{id},
            label  => _resolve_label($family->{label}, $client),
            genres => \@genres,
        };
    }

    return \@out;
}

sub _resolve_label {
    my ($label, $client) = @_;
    return $label unless defined $label;
    return $client ? cstring($client, $label) : string($label);
}

# Number of selected genres per family: { family_id => count }
sub countSelectedByFamily {
    my ($selected) = @_;
    my %count;
    foreach my $name (@{ $selected || [] }) {
        my $genre = $GENRE_BY_NAME{$name} or next;
        $count{ $genre->{family} }++;
    }
    return \%count;
}

# Get genre names (for API).
#
# A family whose every genre is selected travels as one entry (the family's
# representative slug and level) instead of N entries - the request stays small
# and reads the same way. Partially selected families send only the chosen
# genres. Levels always come from the catalog: a sub-genre sent as LVL1 is
# silently ignored by Zvuk.
sub getGenreNames {
    my ($genres_list) = @_;
    return [] unless $genres_list && ref $genres_list eq 'ARRAY';

    my %selected = map { $_ => 1 } @$genres_list;
    my %covered;   # family id => 1 once it has been replaced by its own slug

    my @genre_objects;
    foreach my $genre_name (@$genres_list) {
        my $genre = $GENRE_BY_NAME{$genre_name} or next;

        if (my $family = $FAMILY_BY_ID{ $genre->{family} }) {
            next if $covered{ $family->{id} };
            if (_familyFullySelected($family, \%selected)) {
                $covered{ $family->{id} } = 1;
                push @genre_objects, { name => $family->{slug}, type => $family->{level} };
                next;
            }
        }

        push @genre_objects, { name => $genre->{name}, type => $genre->{level} };
    }

    return \@genre_objects;
}

sub _familyFullySelected {
    my ($family, $selected) = @_;
    my $genres = getGenresByFamily($family->{id});
    return 0 unless @$genres;
    foreach my $genre (@$genres) {
        return 0 unless $selected->{ $genre->{name} };
    }
    return 1;
}

# Internal: find genre by name. The recommender level comes from the catalog:
# a sub-genre sent as LVL1 is silently ignored by Zvuk.
sub _findGenreByName {
    my ($name) = @_;
    my $genre = $GENRE_BY_NAME{$name} or return undef;
    return { name => $genre->{name}, type => $genre->{level} };
}

# True when the slug belongs to the catalog (used to sanitise saved settings)
sub isKnownGenre {
    my ($name) = @_;
    return defined $name && length $name && $GENRE_BY_NAME{$name} ? 1 : 0;
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
        genres   => [],  # No genres selected by default - user must choose
    };
}

1;
