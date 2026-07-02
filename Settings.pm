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
	return ($prefs, qw(quality gigamix_autoplay));
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

						# Extract account name with priority:
						# 1. external_profile with first_name, middle_name, last_name
						# 2. Simple name field
						# 3. username
						# 4. fallback to Account ID
						my $accountName = "Account $userId";

						if ($profile->{external_profile} && $profile->{external_profile}->{first_name}) {
							my $extProf = $profile->{external_profile};
							my @nameParts = ();
							push @nameParts, $extProf->{first_name} if $extProf->{first_name};
							push @nameParts, $extProf->{middle_name} if $extProf->{middle_name};
							push @nameParts, $extProf->{last_name} if $extProf->{last_name};
							$accountName = join(' ', @nameParts) if @nameParts;
						}
						elsif ($profile->{name}) {
							$accountName = $profile->{name};
						}
						elsif ($profile->{username}) {
							$accountName = $profile->{username};
						}

						my $accounts = $prefs->get('accounts') || {};
						$accounts->{$userId} = {
							token => $newToken,
							name  => $accountName,
						};
						$prefs->set('accounts', $accounts);
						$log->info("Zvuk Settings: Account added: userId=$userId, name=$accountName");
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

	$class->beforeRender($params);
	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params) = @_;

	# Build accounts list for template
	my $accounts = $prefs->get('accounts') || {};
	my @accounts_list;
	foreach my $userId (sort keys %$accounts) {
		my $acc = $accounts->{$userId};
		push @accounts_list, {
			userId => $userId,
			name   => $acc->{name} || $userId,
		};
	}
	$params->{accounts} = \@accounts_list;

	# Add wave settings for modal sliders
	require Plugins::Zvuk::WaveSettings;

	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings('default');
	my $genres = Plugins::Zvuk::WaveSettings::getGenres();
	my @genre_list;
	my %genre_labels;
	foreach my $genre (@$genres) {
		push @genre_list, { name => $genre->{name} };
		my $label = Slim::Utils::Strings::string($genre->{label});
		# Ensure UTF-8 encoded string for JSON
		$label = decode_utf8($label) unless Encode::is_utf8($label);
		$genre_labels{$genre->{name}} = $label;
	}

	# Cleanup invalid genres from old preferences - filter out template variables
	my @valid_genres;
	if ($wave_settings->{genres} && ref $wave_settings->{genres} eq 'ARRAY') {
		foreach my $g (@{$wave_settings->{genres}}) {
			# Only keep valid genre names (not template variables like '${genre.name}')
			if ($g && $g !~ /^\$\{/ && length($g) > 0) {
				push @valid_genres, $g;
			}
		}
	}

	# Use valid genres if we have any, otherwise empty array (will use defaults later)
	my $selected_genres = @valid_genres > 0 ? \@valid_genres : [];

	# Use Unicode escape sequences for proper browser rendering
	my $json = JSON::XS->new->utf8(0)->canonical(1);
	my $genres_json = $json->encode(\@genre_list);
	my $genres_labels_json = $json->encode(\%genre_labels);
	my $selected_genres_json = $json->encode($selected_genres);

	$log->debug("Wave Settings - Loaded genres: " . join(',', @{$selected_genres || []}));
	$log->debug("Wave Settings - Genre Labels JSON: $genres_labels_json");

	$params->{wave_settings} = $wave_settings;
	$params->{genres_json} = $genres_json;
	$params->{genres_labels_json} = $genres_labels_json;
	$params->{selected_genres_json} = $selected_genres_json;
}

1;
