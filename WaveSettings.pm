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
