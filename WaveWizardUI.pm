package Plugins::Zvuk::WaveWizardUI;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::Zvuk::WaveSettings;

my $log = logger('plugin.zvuk');

# =====================================================================
# WAVE SETTINGS WIZARD - NOT CURRENTLY USED
# =====================================================================
# The wizard interface below was originally designed for OPML menu navigation
# but has been replaced with a modal-based slider form (waveSliders.html) in
# the Web UI settings page for better user experience.
#
# The wizard code is preserved here for future experimentation and can be
# re-enabled if needed by modifying handleWaveSettingsRouter to route
# Web/Material UI clients to handleWaveWizardStart instead of the web UI.
#
# For OPML clients (Jive, SqueezePlay), use handleWaveSettings instead.
# =====================================================================

sub handleWaveWizardStart {
	my ($client, $callback, $args) = @_;
	my $state = {
		popular  => undef,
		energy   => undef,
		fun      => undef,
		language => undef,
		vocal    => undef,
		genres   => [],
	};
	$callback->(_getWizardStep($client, 1, $state));
}

sub _getWizardStep {
	my ($client, $step, $state) = @_;

	if ($step == 1) {
		return _getWizardPopularityStep($client, $state);
	} elsif ($step == 2) {
		return _getWizardEnergyStep($client, $state);
	} elsif ($step == 3) {
		return _getWizardFunStep($client, $state);
	} elsif ($step == 4) {
		return _getWizardVocalStep($client, $state);
	} elsif ($step == 5) {
		# Only show language step if vocal is selected (vocal=1)
		if ($state->{vocal} == 1) {
			return _getWizardLanguageStep($client, $state);
		} else {
			# Skip language, go to genres
			return _getWizardGenresStep($client, $state);
		}
	} elsif ($step == 6) {
		return _getWizardGenresStep($client, $state);
	} else {
		return _getWizardLaunch($client, $state);
	}
}

sub _getWizardStepLabel {
	my ($client, $step, $value) = @_;

	return unless defined $value;

	# Only show labels for exact values: 0.0, 0.5, 1.0
	if ($step == 1) {  # Popularity
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_POPULAR_UNKNOWN'); }
		elsif (abs($value - 0.5) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_POPULAR_POPULAR'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_POPULAR_FAVORITES'); }
	} elsif ($step == 2) {  # Energy
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_ENERGY_CALM'); }
		elsif (abs($value - 0.5) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_ENERGY_NEUTRAL'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_ENERGY_ENERGETIC'); }
	} elsif ($step == 3) {  # Fun
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_FUN_SAD'); }
		elsif (abs($value - 0.5) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_FUN_NEUTRAL'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_WIZARD_FUN_HAPPY'); }
	} elsif ($step == 4) {  # Vocal
		if (abs($value - 0.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_VOCAL_WITHOUT'); }
		elsif (abs($value - 1.0) < 0.01) { return cstring($client, 'PLUGIN_ZVUK_VOCAL_WITH'); }
	}

	return '';
}

sub _getWizardPopularityStep {
	my ($client, $state) = @_;
	my @items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $label = _getWizardStepLabel($client, 1, $val);
		my $name = sprintf("%.1f", $val);
		$name .= ' - ' . $label if $label;
		push @items, {
			name        => $name,
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 1, value => $val, state => $state }],
		};
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return { items => \@items };
}

sub _getWizardEnergyStep {
	my ($client, $state) = @_;
	my @items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $label = _getWizardStepLabel($client, 2, $val);
		my $name = sprintf("%.1f", $val);
		$name .= ' - ' . $label if $label;
		push @items, {
			name        => $name,
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 2, value => $val, state => $state }],
		};
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return { items => \@items };
}

sub _getWizardFunStep {
	my ($client, $state) = @_;
	my @items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $label = _getWizardStepLabel($client, 3, $val);
		my $name = sprintf("%.1f", $val);
		$name .= ' - ' . $label if $label;
		push @items, {
			name        => $name,
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 3, value => $val, state => $state }],
		};
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return { items => \@items };
}

sub _getWizardLanguageStep {
	my ($client, $state) = @_;
	my @lang_items = (
		{
			name        => cstring($client, 'PLUGIN_ZVUK_LANGUAGE_ALL'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 5, value => 'all', state => $state }],
		},
		{
			name        => cstring($client, 'PLUGIN_ZVUK_LANGUAGE_FOREIGN'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 5, value => 'foreign', state => $state }],
		},
		{
			name        => cstring($client, 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 5, value => 'russian', state => $state }],
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return { items => \@lang_items };
}

sub _getWizardVocalStep {
	my ($client, $state) = @_;
	my @vocal_items = (
		{
			name        => cstring($client, 'PLUGIN_ZVUK_VOCAL_WITH'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 4, value => 1, state => $state }],
		},
		{
			name        => cstring($client, 'PLUGIN_ZVUK_VOCAL_WITHOUT'),
			type        => 'link',
			url         => \&handleWizardStepSelect,
			passthrough => [{ step => 4, value => 0, state => $state }],
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return { items => \@vocal_items };
}

sub _getWizardGenresStep {
	my ($client, $state) = @_;
	my @genre_items;

	foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenres() }) {
		my $is_selected = grep { $_ eq $genre->{name} } @{$state->{genres}};
		my $checkbox_char = $is_selected ? '[x]' : '[ ]';
		push @genre_items, {
			name        => "$checkbox_char " . cstring($client, $genre->{label}),
			type        => 'link',
			url         => \&handleWizardGenreToggle,
			passthrough => [{ genre => $genre->{name}, state => $state }],
			nextWindow  => 'refresh',
		};
	}

	push @genre_items, (
		{
			name        => cstring($client, 'PLUGIN_ZVUK_WIZARD_NEXT'),
			type        => 'link',
			url         => \&handleWizardGenresDone,
			passthrough => [{ state => $state }],
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			nextWindow => 'parent',
		},
	);

	return { items => \@genre_items };
}

sub handleWizardStepSelect {
	my ($client, $callback, $args, $params) = @_;
	my $step = $params->{step};
	my $value = $params->{value};
	my $state = $params->{state};

	# Update state based on step
	if ($step == 1) { $state->{popular} = $value; }
	elsif ($step == 2) { $state->{energy} = $value; }
	elsif ($step == 3) { $state->{fun} = $value; }
	elsif ($step == 4) { $state->{vocal} = $value; }
	elsif ($step == 5) { $state->{language} = $value; }

	# Move to next step
	$callback->(_getWizardStep($client, $step + 1, $state));
}

sub handleWizardGenreToggle {
	my ($client, $callback, $args, $params) = @_;
	my $genre = $params->{genre};
	my $state = $params->{state};

	# Toggle genre
	my @genres = @{$state->{genres}};
	if (grep { $_ eq $genre } @genres) {
		@genres = grep { $_ ne $genre } @genres;
	} else {
		push @genres, $genre;
	}
	$state->{genres} = \@genres;

	# Refresh genres menu with updated checkmarks
	$callback->(_getWizardGenresStep($client, $state));
}

sub handleWizardGenresDone {
	my ($client, $callback, $args, $params) = @_;
	my $state = $params->{state};

	# Move to launch screen
	$callback->(_getWizardLaunch($client, $state));
}

sub _getWizardLaunch {
	my ($client, $state) = @_;

	# Save settings to prefs
	my $api = _getAPIHandler($client);
	my $account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';

	my $settings = {
		popular  => $state->{popular} // 0.5,
		energy   => $state->{energy} // 0.5,
		fun      => $state->{fun} // 0.5,
		language => $state->{language} // 'all',
		vocal    => defined $state->{vocal} ? $state->{vocal} : 1,
		genres   => $state->{genres} || [],
	};
	Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

	return {
		items => [
			{
				name => cstring($client, 'PLUGIN_ZVUK_WIZARD_LAUNCH'),
				type => 'audio',
				url  => 'zvuk://wave',
			},
			{
				name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
				type       => 'link',
				nextWindow => 'parent',
			},
		],
	};
}

sub _getAPIHandler {
	my ($client) = @_;
	return unless $client;
	return Plugins::Zvuk::Plugin::_get_api_client($client);
}

1;
