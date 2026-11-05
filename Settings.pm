package Plugins::Zvuk::Settings;

use strict;
use utf8;
use base qw(Slim::Web::Settings);

use Encode qw(decode_utf8 encode_utf8);
use JSON::XS;
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

sub name {
	return 'PLUGIN_ZVUK';
}

sub page {
	return 'plugins/zvuk/settings/basic.html';
}

sub prefs {
	return ($prefs, qw(quality gigamix_autoplay material_settings_mode));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	# Handle account deletion
	foreach my $key (keys %$params) {
		if ($key =~ /^delete_(.+)$/) {
			my $userId   = $1;
			my $accounts = $prefs->get('accounts') || {};
			if (exists $accounts->{$userId}) {
				delete $accounts->{$userId};
				$prefs->set('accounts', $accounts);
				$log->info("Zvuk Settings: Deleted account userId=$userId");

				# If deleted account was defaultUserId, reassign or clear
				if ($prefs->get('defaultUserId') && $prefs->get('defaultUserId') eq $userId) {
					my $newDefault = Plugins::Zvuk::API->getSomeUserId();
					if ($newDefault) {
						$prefs->set('defaultUserId', $newDefault);
					} else {
						$prefs->remove('defaultUserId');
					}
				}

				# Clear cached API clients
				Plugins::Zvuk::Plugin::_clear_api_client($userId);
				require Plugins::Zvuk::API::Async;
				Plugins::Zvuk::API::Async->clearClient($userId);
				require Plugins::Zvuk::API::Atlas;
				Plugins::Zvuk::API::Atlas->clearClient($userId);
			}
		}
	}

	if ($params->{saveSettings}) {
		# Handle adding a new account via token field
		my $newToken = $params->{new_account_token};
		if ($newToken && $newToken =~ /^[0-9a-f]{32}$/i) {
			$log->info("Zvuk Settings: Adding new account, validating token...");

			require Plugins::Zvuk::API::Async;
			Plugins::Zvuk::API::Async->getProfile(
				sub {
					my $profile = shift;

					if ($profile && $profile->{id} && !$profile->{error}) {
						my $userId = $profile->{id};

						my $accountName = Plugins::Zvuk::API->extractAccountName($profile, $userId);

						my $accounts = $prefs->get('accounts') || {};
						$accounts->{$userId} = {
							token => $newToken,
							name  => $accountName,
						};
						$prefs->set('accounts', $accounts);
						$log->info("Zvuk Settings: Account added: userId=$userId, name=$accountName");

						# Ensure defaultUserId is set
						my $currDefault = $prefs->get('defaultUserId');
						if (!$currDefault || !exists $accounts->{$currDefault} || !$accounts->{$currDefault}{token}) {
							$prefs->set('defaultUserId', $userId);
						}

						Plugins::Zvuk::Plugin::_init_api_client($userId);
					}
					else {
						$log->error("Zvuk Settings: Token validation failed.");
						$params->{warning} = string('PLUGIN_ZVUK_AUTH_FAILED');
					}

					$class->beforeRender($params);
					my $body = $class->SUPER::handler($client, $params);
					$callback->($client, $params, $body, @args);
				},
				$newToken
			);
			return;  # Wait for async callback
		}
	}

	$class->beforeRender($params, $client);
	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params, $client) = @_;

	# Resolve the real per-account Wave settings for whichever player is
	# currently selected in the web UI, instead of the hardcoded 'default'
	# key (which never matched the key Wave/ProtocolHandler actually read
	# from during playback).
	my $account_id = $client ? Plugins::Zvuk::Plugin::_getUserIdForClient($client) : 'default';

	# Build accounts list for template
	my $accounts = $prefs->get('accounts') || {};
	my @accounts_list;
	my @stale_accounts;
	foreach my $userId (sort keys %$accounts) {
		my $acc = $accounts->{$userId};
		my $is_stale = $acc->{stale} ? 1 : 0;
		my $entry = {
			userId => $userId,
			name   => $acc->{name} || $userId,
			stale  => $is_stale,
		};
		push @accounts_list, $entry;
		push @stale_accounts, $entry if $is_stale;
	}
	$params->{accounts} = \@accounts_list;
	$params->{has_stale_accounts} = scalar(@stale_accounts) > 0 ? 1 : 0;
	$params->{stale_accounts} = \@stale_accounts;

	# Add wave settings for modal sliders
	require Plugins::Zvuk::WaveSettings;

	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings($account_id);

	# One catalog payload for every surface (family + level included)
	my $catalog = Plugins::Zvuk::WaveSettings::getCatalog();
	my @genre_list;
	foreach my $genre (@$catalog) {
		my $label = $genre->{label};
		# Ensure UTF-8 encoded string for JSON
		$label = decode_utf8($label) unless Encode::is_utf8($label);
		push @genre_list, {
			name         => $genre->{name},
			label        => $label,
			family       => $genre->{family},
			family_label => $genre->{family_label},
			level        => $genre->{level},
		};
	}

	# loadSettings already drops anything outside the catalog
	my $selected_genres = $wave_settings->{genres} || [];

	# Use Unicode escape sequences for proper browser rendering
	my $json = JSON::XS->new->utf8(0)->canonical(1);
	my $genres_json = $json->encode(\@genre_list);
	my $selected_genres_json = $json->encode($selected_genres);

	$log->debug("Wave Settings - Loaded genres: " . join(',', @{$selected_genres || []}));

	$params->{wave_settings} = $wave_settings;
	$params->{genres_json} = $genres_json;
	$params->{selected_genres_json} = $selected_genres_json;
}

1;
