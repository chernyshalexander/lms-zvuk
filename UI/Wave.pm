package Plugins::Zvuk::UI::Wave;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

use Plugins::Zvuk::WaveSettings;
use Plugins::Zvuk::UI::Common;

my $log = logger('plugin.zvuk');

# --- Wave Settings ---

sub _getWaveSettingsItems {
	my ($client) = @_;
	my @items;

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_POPULAR') . ': ' . _getSliderLabel($client, 'popular'),
		type => 'link',
		url  => \&handleSlider,
		passthrough => [{ key => 'popular' }],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_ENERGY') . ': ' . _getSliderLabel($client, 'energy'),
		type => 'link',
		url  => \&handleSlider,
		passthrough => [{ key => 'energy' }],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_FUN') . ': ' . _getSliderLabel($client, 'fun'),
		type => 'link',
		url  => \&handleSlider,
		passthrough => [{ key => 'fun' }],
	};

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_VOCAL') . ': ' . _getVocalLabel($client),
		type => 'link',
		url  => \&handleVocalMenu,
	};

	# Only show language if vocal=1 (with vocals)
	my $vocal = _getSettingValue($client, 'vocal', 1);
	if ($vocal == 1) {
		push @items, {
			name => cstring($client, 'PLUGIN_ZVUK_SETTING_LANGUAGE') . ': ' . _getLangLabel($client),
			type => 'link',
			url  => \&handleLanguageMenu,
		};
	}

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
		type => 'link',
		url  => \&handleGenresMenu,
	};

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		url        => \&handleWaveMenu,
		nextWindow => 'parent',
	};

	return \@items;
}

sub _getSliderLabel {
	my ($client, $key) = @_;
	return sprintf('%.1f', _getSettingValue($client, $key, 0.5));
}

sub _getLangLabel {
	my ($client) = @_;
	my $val = _getSettingValue($client, 'language', 'all');
	my %map = (
		all     => 'PLUGIN_ZVUK_LANGUAGE_ALL',
		foreign => 'PLUGIN_ZVUK_LANGUAGE_FOREIGN',
		russian => 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN',
	);
	return cstring($client, $map{$val} || $map{all});
}

sub _getVocalLabel {
	my ($client) = @_;
	my $val = _getSettingValue($client, 'vocal', 1);
	return cstring($client, $val ? 'PLUGIN_ZVUK_VOCAL_WITH' : 'PLUGIN_ZVUK_VOCAL_WITHOUT');
}

sub _getSettingValue {
	my ($client, $key, $default) = @_;
	return $default unless $client;

	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	return $settings->{$key} // $default;
}

sub _updateSetting {
	my ($client, $key, $value) = @_;
	return unless $client;

	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	$settings->{$key} = $value;
	Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

	$log->info("Wave setting updated: $key = $value");
}

sub handleGenresMenu {
	my ($client, $callback, $args) = @_;
	$callback->({
		name  => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
		title => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
		items => _getFamilyMenu($client, $args),
	});
}

# First level: genre families, each with a count of selected genres inside so the
# state is visible without opening it.
sub _getFamilyMenu {
	my ($client, $args) = @_;

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings(_accountIdFor($client));
	my $counts = Plugins::Zvuk::WaveSettings::countSelectedByFamily($settings->{genres});

	my @items;
	foreach my $family (@{ Plugins::Zvuk::WaveSettings::getFamilies() }) {
		my $count = $counts->{ $family->{id} } || 0;
		my $name = $count
			? sprintf('[x] %s (%d)', cstring($client, $family->{label}), $count)
			: sprintf('[ ] %s', cstring($client, $family->{label}));

		my $item = {
			name        => $name,
			type        => 'link',
			url         => \&handleGenreFamily,
			passthrough => [{ family => $family->{id} }],
		};
		# No nextWindow here on purpose: this item NAVIGATES into the family.
		# With nextWindow => 'refresh' Jive/SqueezePlay re-requested the current
		# window instead of opening the returned child feed, so tapping a family
		# appeared to do nothing. 'refresh' is only for in-place checkbox updates.
		push @items, $item;
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		url        => \&handleWaveSettings,
		nextWindow => 'parent',
	};

	return \@items;
}

# Second level: genres of one family, as checkboxes.
sub handleGenreFamily {
	my ($client, $callback, $args, $params) = @_;
	my $family_id = $params && $params->{family};

	my $family;
	foreach my $f (@{ Plugins::Zvuk::WaveSettings::getFamilies() }) {
		$family = $f if $f->{id} eq ($family_id // '');
	}

	# Unknown family (stale menu) - fall back to the family list instead of an empty screen
	if (!$family) {
		$callback->({
			name  => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
			title => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
			items => _getFamilyMenu($client, $args),
		});
		return;
	}

	$callback->({
		name  => cstring($client, $family->{label}),
		title => cstring($client, $family->{label}),
		items => _getFamilyGenresMenu($client, $args, $family_id),
	});
}

sub _getFamilyGenresMenu {
	my ($client, $args, $family_id) = @_;

	my $kind = _uiKind($client, $args);
	my $is_buttons = ($kind eq 'player_buttons');

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings(_accountIdFor($client));
	my %selected = map { $_ => 1 } @{ $settings->{genres} || [] };

	my @items;
	foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenresByFamily($family_id) }) {
		my $checkbox_char = $selected{ $genre->{name} } ? '[x]' : '[ ]';
		my $item = {
			name        => "$checkbox_char " . cstring($client, $genre->{label}),
			type        => 'link',
			url         => \&handleGenreToggle,
			passthrough => [{ genre => $genre->{name}, family => $family_id }],
		};
		$item->{nextWindow} = 'refresh' unless $is_buttons;
		push @items, $item;
	}

	push @items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		url        => \&handleGenresMenu,
		nextWindow => 'parent',
	};

	return \@items;
}

sub _accountIdFor {
	my ($client) = @_;
	my $api = _getAPIHandler($client);
	return $api ? $api->accountId() : 'default';
}

sub handleGenreToggle {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $genre_name = $params->{genre};
	my $family_id  = $params->{family};

	my $account_id = _accountIdFor($client);

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $genres = $settings->{genres} || [];
	my %genre_hash = map { $_ => 1 } @$genres;

	# Toggle
	if ($genre_hash{$genre_name}) {
		delete $genre_hash{$genre_name};
	} else {
		$genre_hash{$genre_name} = 1;
	}

	$settings->{genres} = [sort keys %genre_hash];
	Plugins::Zvuk::WaveSettings::saveSettings($account_id, $settings);

	$log->info("Genre toggled: $genre_name, new genres: " . join(',', @{$settings->{genres}}));

	# Return into the same family the user came from, not to the family list.
	my $items = defined $family_id
		? _getFamilyGenresMenu($client, $args, $family_id)
		: _getGenresMenu($client, $args);

	my $title = defined $family_id ? _familyLabel($client, $family_id) : undef;

	$callback->({
		name  => cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
		title => $title || cstring($client, 'PLUGIN_ZVUK_SETTING_GENRES'),
		items => $items,
	});
}

sub _familyLabel {
	my ($client, $family_id) = @_;
	foreach my $f (@{ Plugins::Zvuk::WaveSettings::getFamilies() }) {
		return cstring($client, $f->{label}) if $f->{id} eq $family_id;
	}
	return undef;
}

# Legacy flat list, kept for callers that want every genre at once.
sub _getGenresMenu {
	my ($client, $args) = @_;

	my $kind = _uiKind($client, $args);
	my $is_buttons = ($kind eq 'player_buttons');

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings(_accountIdFor($client));
	my %selected = map { $_ => 1 } @{ $settings->{genres} || [] };

	my @genre_items;
	foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenres() }) {
		my $checkbox_char = $selected{ $genre->{name} } ? '[x]' : '[ ]';
		my $item = {
			name        => "$checkbox_char " . cstring($client, $genre->{label}),
			type        => 'link',
			url         => \&handleGenreToggle,
			passthrough => [{ genre => $genre->{name} }],
		};
		$item->{nextWindow} = 'refresh' unless $is_buttons;
		push @genre_items, $item;
	}

	push @genre_items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		url        => \&handleWaveSettings,
		nextWindow => 'parent',
	};

	return \@genre_items;
}

sub _getAPIHandler {
	my ($client) = @_;
	return unless $client;
	# Always resolve fresh from the client's current userId pref (same path
	# as _get_api_client) instead of caching the API object in pluginData:
	# a cached object silently kept pointing at the account that was active
	# when it was first created, surviving _switchAccount indefinitely.
	return Plugins::Zvuk::Plugin::_get_api_client($client);
}

# Handle slider changes (Popular, Energy, Fun)
sub handleSlider {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;
	my $key = $params->{key};
	$callback->({
		name  => cstring($client, 'PLUGIN_ZVUK_SETTING_' . uc($key)),
		title => cstring($client, 'PLUGIN_ZVUK_SETTING_' . uc($key)),
		items => _getSliderItems($client, $key),
	});
}

sub _uiKind {
	return Plugins::Zvuk::UI::Common::uiKind(@_);
}

sub handleStartWave {
	my ($client, $callback, $args) = @_;
	return unless $client;

	$log->info("Starting Wave playback via menu item for client " . ($client->name || ref($client) || ''));

	# On button VFD players (Squeezebox Boom/Classic/Transporter), onRight pushes a temporary
	# xmlbrowser mode stack level before calling the url handler.
	# We pop that temporary mode level first so the stack returns to the parent menu level,
	# preventing an empty screen flicker and stack underflow when pressing BACK.
	if (_uiKind($client, $args) eq 'player_buttons') {
		Plugins::Zvuk::UI::Common::popVfdMode($client);
	}

	$client->execute(['playlist', 'play', 'zvuk://wave', cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_START')]);

	if (defined &Slim::Buttons::Common::pushModeLeft) {
		if ((Slim::Buttons::Common::mode($client) || '') ne 'playlist') {
			Slim::Buttons::Common::pushModeLeft($client, 'playlist');
		}
	}
}

sub _getWaveMenuItems {
	my ($client, $args) = @_;
	my @items;

	my $kind = _uiKind($client, $args);
	my $is_buttons = ($kind eq 'player_buttons');

	push @items, {
		name      => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_START'),
		type      => 'audio',
		url       => $is_buttons ? \&handleStartWave : 'zvuk://wave',
		play      => 'zvuk://wave',
		on_select => 'play',
		image     => 'plugins/zvuk/html/images/radio.png',
	};

	my $useWebUI = ($kind eq 'classic_web' || $kind eq 'weblink_capable') ? 1 : 0;

	if ($log->is_debug) {
		$log->debug("=== ZVUK DEBUG _getWaveMenuItems ===");
		$log->debug("  Client: " . ($client ? ($client->name || ref($client)) : 'undef') . " (ref: " . ref($client) . ")");
		$log->debug("  UI Kind: $kind");
		if ($args) {
			$log->debug("  Args present: isWeb=" . ($args->{isWeb} // 'undef') . ", isButton=" . ($args->{isButton} // 'undef') . ", isControl=" . ($args->{isControl} // 'undef') . ", quantity=" . ($args->{quantity} // 'undef'));
		} else {
			$log->debug("  Args NOT present");
		}
		$log->debug("  Decision: useWebUI=$useWebUI");
	}

	if ($useWebUI) {
		# For Web/Material UI: direct link to standalone wave settings page
		my $pref_mode = preferences('plugin.zvuk')->get('material_settings_mode') || 'iframe';
		my $ext = ($pref_mode eq 'iframe') ? '.html' : '';
		push @items, {
			name    => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			type    => 'link',
			weblink => '/plugins/zvuk/waveStandalone' . $ext . '?player=' . ($client ? $client->id : ''),
			image   => 'plugins/zvuk/html/images/settings.png',
		};
	} else {
		# For Jive/SqueezePlay: link to router that shows native UI
		push @items, {
			name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			type  => 'link',
			url   => \&handleWaveSettingsRouter,
			image => 'plugins/zvuk/html/images/settings.png',
		};
	}

	return \@items;
}

sub handleWaveSettingsRouter {
	my ($client, $callback, $args) = @_;

	my $kind = _uiKind($client, $args);
	my $useWebUI = ($kind eq 'classic_web' || $kind eq 'weblink_capable') ? 1 : 0;

	if ($log->is_debug) {
		$log->debug("=== ZVUK DEBUG handleWaveSettingsRouter ===");
		$log->debug("  Client: " . ($client ? ($client->name || ref($client)) : 'undef') . " (ref: " . ref($client) . ")");
		$log->debug("  UI Kind: $kind");
		if ($args) {
			$log->debug("  Args present: isWeb=" . ($args->{isWeb} // 'undef') . ", isButton=" . ($args->{isButton} // 'undef') . ", isControl=" . ($args->{isControl} // 'undef') . ", quantity=" . ($args->{quantity} // 'undef'));
		} else {
			$log->debug("  Args NOT present");
		}
		$log->debug("  Decision: useWebUI=$useWebUI");
	}

	if ($useWebUI) {
		# For Web/Material UI: Provide direct link to wave settings web page via weblink (iframe modal)
		my $pref_mode = preferences('plugin.zvuk')->get('material_settings_mode') || 'iframe';
		my $ext = ($pref_mode eq 'iframe') ? '.html' : '';
		$callback->([{
			name    => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			type    => 'link',
			weblink => '/plugins/zvuk/waveStandalone' . $ext . '?player=' . ($client ? $client->id : ''),
			image   => 'plugins/zvuk/html/images/settings.png',
		}]);
	} else {
		# For Jive/SqueezePlay: show standard list settings
		handleWaveSettings($client, $callback, $args);
	}
}

sub handleWaveSettings {
	my ($client, $callback, $args) = @_;
	$callback->({
		name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
		title => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
		items => _getWaveSettingsItems($client),
	});
}

sub _getSliderItems {
	my ($client, $key) = @_;
	my $current_value = _getSettingValue($client, $key, 0.5);

	my @slider_items;
	for (my $i = 0; $i <= 10; $i++) {
		my $val = $i / 10;
		my $marker = abs($val - $current_value) < 0.01 ? '[x]' : '[ ]';
		push @slider_items, {
			name       => sprintf("$marker %.1f", $val),
			type       => 'link',
			url        => \&handleSliderValue,
			passthrough => [{ key => $key, value => $val }],
			nextWindow => 'parent',
		};
	}

	push @slider_items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		url        => \&handleWaveSettings,
		nextWindow => 'parent',
	};

	return \@slider_items;
}

sub _shouldGoBackToSettings {
	my ($client, $args) = @_;
	return _uiKind($client, $args) eq 'player_buttons';
}

# Handle actual slider value selection
sub handleSliderValue {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $key = $params->{key};
	my $value = $params->{value};

	_updateSetting($client, $key, $value);

	if (_shouldGoBackToSettings($client, $args)) {
		$callback->({
			name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			title => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			items => _getWaveSettingsItems($client),
		});
	} else {
		$callback->({
			name  => cstring($client, 'PLUGIN_ZVUK_SETTING_' . uc($key)),
			title => cstring($client, 'PLUGIN_ZVUK_SETTING_' . uc($key)),
			items => _getSliderItems($client, $key),
		});
	}
}

# Handle language selection
sub handleLanguageSelect {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $language = $params->{language};
	_updateSetting($client, 'language', $language);

	if (_shouldGoBackToSettings($client, $args)) {
		$callback->({
			name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			title => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			items => _getWaveSettingsItems($client),
		});
	} else {
		$callback->({
			name  => cstring($client, 'PLUGIN_ZVUK_SETTING_LANGUAGE'),
			title => cstring($client, 'PLUGIN_ZVUK_SETTING_LANGUAGE'),
			items => _getLanguageMenu($client),
		});
	}
}

# Handle vocal selection
sub handleVocalSelect {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $vocal = $params->{vocal};
	_updateSetting($client, 'vocal', $vocal);

	if (_shouldGoBackToSettings($client, $args)) {
		$callback->({
			name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			title => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
			items => _getWaveSettingsItems($client),
		});
	} else {
		$callback->({
			name  => cstring($client, 'PLUGIN_ZVUK_SETTING_VOCAL'),
			title => cstring($client, 'PLUGIN_ZVUK_SETTING_VOCAL'),
			items => _getVocalMenu($client),
		});
	}
}

# Generate language selection menu handler
sub handleLanguageMenu {
	my ($client, $callback) = @_;
	$callback->({
		name  => cstring($client, 'PLUGIN_ZVUK_SETTING_LANGUAGE'),
		title => cstring($client, 'PLUGIN_ZVUK_SETTING_LANGUAGE'),
		items => _getLanguageMenu($client),
	});
}

# Return language menu items
sub _getLanguageMenu {
	my ($client) = @_;
	my $account_id = 'default';
	if ($client) {
		my $api = _getAPIHandler($client);
		$account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
	}

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $current_lang = $settings->{language} || 'all';

	my @lang_items = (
		{
			name       => ($current_lang eq 'all' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_ALL'),
			type       => 'link',
			url        => \&handleLanguageSelect,
			passthrough => [{ language => 'all' }],
			nextWindow => 'parent',
		},
		{
			name       => ($current_lang eq 'foreign' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_FOREIGN'),
			type       => 'link',
			url        => \&handleLanguageSelect,
			passthrough => [{ language => 'foreign' }],
			nextWindow => 'parent',
		},
		{
			name       => ($current_lang eq 'russian' ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_LANGUAGE_RUSSIAN'),
			type       => 'link',
			url        => \&handleLanguageSelect,
			passthrough => [{ language => 'russian' }],
			nextWindow => 'parent',
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			url        => \&handleWaveSettings,
			nextWindow => 'parent',
		},
	);

	return \@lang_items;
}

# Generate vocal selection menu handler
sub handleVocalMenu {
	my ($client, $callback) = @_;
	$callback->({
		name  => cstring($client, 'PLUGIN_ZVUK_SETTING_VOCAL'),
		title => cstring($client, 'PLUGIN_ZVUK_SETTING_VOCAL'),
		items => _getVocalMenu($client),
	});
}

# Return vocal menu items
sub _getVocalMenu {
	my ($client) = @_;
	my $account_id = 'default';
	if ($client) {
		my $api = _getAPIHandler($client);
		$account_id = $api && $api->can('accountId') ? $api->accountId() : 'default';
	}

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $current_vocal = $settings->{vocal} // 1;

	my @vocal_items = (
		{
			name       => ($current_vocal == 1 ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_VOCAL_WITH'),
			type       => 'link',
			url        => \&handleVocalSelect,
			passthrough => [{ vocal => 1 }],
			nextWindow => 'parent',
		},
		{
			name       => ($current_vocal == 0 ? '[x]' : '[ ]') . ' ' . cstring($client, 'PLUGIN_ZVUK_VOCAL_WITHOUT'),
			type       => 'link',
			url        => \&handleVocalSelect,
			passthrough => [{ vocal => 0 }],
			nextWindow => 'parent',
		},
		{
			name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
			type       => 'link',
			url        => \&handleWaveSettings,
			nextWindow => 'parent',
		},
	);

	return \@vocal_items;
}

sub handleWaveMenu {
	my ($client, $callback, $args) = @_;
	$callback->({ items => _getWaveMenuItems($client, $args) });
}

1;
