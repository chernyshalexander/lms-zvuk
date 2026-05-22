package Plugins::Zvuk::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use JSON::XS;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

sub name {
	return 'PLUGIN_ZVUK';
}

sub page {
	my ($class, $client, $params) = @_;

	# Check if this is a request for wave settings
	if ($params && $params->{wave}) {
		return 'plugins/zvuk/settings/wave.html';
	}

	return 'plugins/zvuk/settings/basic.html';
}

sub prefs {
	return ($prefs, qw(quality));
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
						my $accounts = $prefs->get('accounts') || {};
						$accounts->{$userId} = {
							token => $newToken,
							name  => "Account $userId",
						};
						$prefs->set('accounts', $accounts);
						$log->info("Zvuk Settings: Account added: userId=$userId");
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

	# Load wave settings for current account (default for web UI)
	require Plugins::Zvuk::WaveSettings;
	my $wave_settings = Plugins::Zvuk::WaveSettings::loadSettings('default');
	$params->{wave_settings} = $wave_settings;

	# Build genres list for JavaScript
	my $genres = Plugins::Zvuk::WaveSettings::getGenres();
	my @genre_list;
	my %genre_labels;
	foreach my $genre (@$genres) {
		push @genre_list, { name => $genre->{name} };
		$genre_labels{$genre->{name}} = string($genre->{label});
	}

	$params->{genres_json} = encode_json(\@genre_list);
	$params->{genres_labels_json} = encode_json(\%genre_labels);
	$params->{selected_genres_json} = encode_json($wave_settings->{genres} || []);
}

1;
