package Plugins::Zvuk::WaveUI;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use Plugins::Zvuk::WaveSettings;

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
	my ($client, $callback) = @_;
	$callback->(_getGenresMenu($client));
}

sub _getGenresMenu {
	my ($client) = @_;
	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

	my $settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);
	my $selected_genres = $settings->{genres} || [];
	my %selected = map { $_ => 1 } @$selected_genres;

	my @genre_items;
	foreach my $genre (@{ Plugins::Zvuk::WaveSettings::getGenres() }) {
		my $is_selected = $selected{$genre->{name}} ? 1 : 0;
		my $checkbox_char = $is_selected ? '[x]' : '[ ]';
		push @genre_items, {
			name       => "$checkbox_char " . cstring($client, $genre->{label}),
			type       => 'link',
			url        => \&handleGenreToggle,
			passthrough => [{ genre => $genre->{name} }],
			nextWindow => 'refresh',
		};
	}

	push @genre_items, {
		name       => cstring($client, 'PLUGIN_ZVUK_BACK'),
		type       => 'link',
		nextWindow => 'parent',
	};

	return \@genre_items;
}

sub handleGenreToggle {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $genre_name = $params->{genre};

	my $api = _getAPIHandler($client);
	my $account_id = $api ? $api->accountId() : 'default';

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

	# Вернуть в меню жанров
	$callback->(_getGenresMenu($client));
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
	$callback->(_getSliderItems($client, $key));
}

sub _getWaveMenuItems {
	my ($client) = @_;
	my @items;

	push @items, {
		name => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_START'),
		type => 'audio',
		url  => 'zvuk://wave',
	};

		# Detect client type and return appropriate item directly
		my $isWeb = $client && Slim::Utils::Misc::isWebBrowser($client);
		my $canWeblink = $client && Slim::Utils::Misc::canFollowWeblinks($client);
		
		if ($canWeblink) {
			# For Web/Material UI: direct weblink to wave settings page
			push @items, {
				name    => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
				type    => 'link',
				weblink => '/plugins/zvuk/waveSettings?player=' . ($client ? $client->id : ''),
				image   => 'plugins/zvuk/html/images/playlists.png',
			};
		} else {
			# For Jive/SqueezePlay: link to router that shows native UI
			push @items, {
				name  => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
				type  => 'link',
				url   => \&handleWaveSettingsRouter,
				jive  => { actions => { go => { player => 0, cmd => ['zvuk', 'wavecontrols'] } } },
			};
		}

	return \@items;
}

sub handleWaveSettingsRouter {
	my ($client, $callback, $args) = @_;

	$log->info("=== Wave Settings Router Decision ===");
	$log->info("Args received: " . (defined $args ? "YES" : "UNDEF"));

	my $isWeb = $args && $args->{isWeb} ? 1 : 0;
	my $isControl = $args && defined $args->{isControl} ? $args->{isControl} : undef;
	my $quantity = $args && defined $args->{quantity} ? $args->{quantity} : undef;

	$log->info("  isWeb=$isWeb");
	$log->info("  isControl=" . (defined $isControl ? $isControl : 'undef'));
	$log->info("  quantity=" . (defined $quantity ? $quantity : 'undef'));

	if ($args) {
		foreach my $key (sort keys %$args) {
			next if $key =~ /^(isWeb|isControl|quantity)$/;
			my $val = $args->{$key};
			if (ref $val) {
				$log->info("  $key => [" . ref($val) . "]");
			} else {
				$log->info("  $key => " . ($val // 'undef'));
			}
		}
	}

	my $useWebUI = 0;
	my $reason = '';

	if ($isWeb) {
		$useWebUI = 1;
		$reason = 'isWeb=1 - show web sliders';
	} elsif (!defined $isControl) {
		$useWebUI = 1;
		$reason = 'isControl undefined - web-like client';
	} elsif ($isControl && (!defined $quantity || $quantity > 5000)) {
		$useWebUI = 1;
		$reason = 'isControl=1 AND (quantity undef OR quantity > 5000) - Material UI';
	} else {
		$reason = 'isControl=1 AND quantity <= 5000 - Jive/SqueezePlay';
	}

	$log->info("Decision: useWebUI=$useWebUI (Reason: $reason)");
	$log->info("=== End Router Decision ===");

		if ($useWebUI) {
			# For Web/Material UI: Provide direct link to wave settings web page via weblink (iframe modal)
			$callback->([{
				name    => cstring($client, 'PLUGIN_ZVUK_MENU_WAVE_SETTINGS'),
				type    => 'link',
				weblink => '/plugins/zvuk/waveSettings?player=' . ($client ? $client->id : ''),
				image   => 'plugins/zvuk/html/images/playlists.png',
			}]);
		} else {
		# For Jive/SqueezePlay: show standard list settings
		handleWaveSettings($client, $callback, $args);
	}
}

sub handleWaveSettings {
	my ($client, $callback, $args) = @_;
	$callback->({ items => _getWaveSettingsItems($client) });
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
		nextWindow => 'parent',
	};

	return \@slider_items;
}

# Handle actual slider value selection
sub handleSliderValue {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $key = $params->{key};
	my $value = $params->{value};

	_updateSetting($client, $key, $value);
	$callback->(_getSliderItems($client, $key));
}

# Handle language selection
sub handleLanguageSelect {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $language = $params->{language};
	_updateSetting($client, 'language', $language);
	$callback->(_getLanguageMenu($client));
}

# Handle vocal selection
sub handleVocalSelect {
	my ($client, $callback, $args, $params) = @_;
	return unless $params;

	my $vocal = $params->{vocal};
	_updateSetting($client, 'vocal', $vocal);
	$callback->(_getVocalMenu($client));
}

# Generate language selection menu handler
sub handleLanguageMenu {
	my ($client, $callback) = @_;
	$callback->(_getLanguageMenu($client));
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
			nextWindow => 'parent',
		},
	);

	return \@lang_items;
}

# Generate vocal selection menu handler
sub handleVocalMenu {
	my ($client, $callback) = @_;
	$callback->(_getVocalMenu($client));
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
			nextWindow => 'parent',
		},
	);

	return \@vocal_items;
}

1;
