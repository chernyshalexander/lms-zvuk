package Plugins::Zvuk::Session;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.zvuk');
my $prefs = preferences('plugin.zvuk');

# Return all configured accounts as hashref { userId => { token => ..., name => ... } }
sub getAccounts {
	my ($class) = @_;
	my $accounts = $prefs->get('accounts');
	return (ref $accounts eq 'HASH') ? $accounts : {};
}

# Return true if at least one valid account with a token exists
sub hasAccounts {
	my ($class) = @_;
	my $accounts = $class->getAccounts();
	foreach my $id (keys %$accounts) {
		return 1 if $accounts->{$id} && $accounts->{$id}{token};
	}
	return 0;
}

# Return userId of the active or default configured account
sub getSomeUserId {
	my ($class) = @_;
	my $accounts = $class->getAccounts();
	return unless keys %$accounts;

	my $defaultUserId = $prefs->get('defaultUserId');
	if (defined $defaultUserId && length($defaultUserId) && $accounts->{$defaultUserId} && $accounts->{$defaultUserId}{token}) {
		return $defaultUserId;
	}

	# Otherwise return the first account with a valid token
	foreach my $id (sort keys %$accounts) {
		if ($accounts->{$id} && $accounts->{$id}{token}) {
			return $id;
		}
	}
	return;
}

# Return account data for a given userId
sub getUserdata {
	my ($class, $userId);
	if (@_ <= 1) {
		$class = __PACKAGE__;
		$userId = $_[0] if @_ == 1 && $_[0] ne __PACKAGE__;
	} else {
		($class, $userId) = @_;
	}
	$userId ||= $class->getSomeUserId();
	return unless defined $userId && length($userId);

	my $accounts = $class->getAccounts();
	return $accounts->{$userId};
}

# Return the token for a given userId
sub getToken {
	my ($class, $userId);
	if (@_ <= 1) {
		$class = __PACKAGE__;
		$userId = $_[0] if @_ == 1 && $_[0] ne __PACKAGE__;
	} else {
		($class, $userId) = @_;
	}
	$userId ||= $class->getSomeUserId();
	return unless defined $userId && length($userId);

	my $data = $class->getUserdata($userId);
	return unless $data;
	return $data->{token};
}

# Resolve userId for a player client, with auto-healing
sub getUserIdForClient {
	my ($class, $client);
	if (@_ == 1) {
		$class = __PACKAGE__;
		$client = $_[0];
	} else {
		($class, $client) = @_;
	}

	my $accounts = $class->getAccounts();
	my $userId = $client ? $prefs->client($client)->get('userId') : undef;

	# If client has a valid, existing account with a token, use it
	if (defined $userId && length($userId) && $accounts->{$userId} && $accounts->{$userId}{token}) {
		return $userId;
	}

	# Stale or non-existent client userId (or client has none set):
	# Fall back to defaultUserId or any valid configured account
	my $fallbackUserId = $class->getSomeUserId();

	# Self-heal: update client's preference to valid account
	if ($client && defined $fallbackUserId && length($fallbackUserId)) {
		eval {
			$prefs->client($client)->set('userId', $fallbackUserId);
		};
		my $clientId = (ref $client && $client->can('id')) ? $client->id : "$client";
		$log->info("Zvuk: Auto-healed client $clientId userId: " . (defined $userId ? $userId : 'undef') . " -> $fallbackUserId");
	}

	return $fallbackUserId;
}

# Extract human-readable account display name from profile object
sub extractAccountName {
	my ($class, $profile, $userId) = @_;
	my $accountName = "Account " . ($userId || '');

	if ($profile && ref($profile) eq 'HASH') {
		if ($profile->{external_profile} && ref($profile->{external_profile}) eq 'HASH') {
			my $extProf = $profile->{external_profile};
			my @nameParts;
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
	}
	return $accountName;
}

# Save or update an account
sub saveAccount {
	my ($class, $userId, $accountData) = @_;
	return unless defined $userId && length($userId);
	return unless ref $accountData eq 'HASH';

	my $accounts = $class->getAccounts();
	$accounts->{$userId} = $accountData;
	$prefs->set('accounts', $accounts);

	# If defaultUserId is unset or invalid, set it to this userId
	my $currDefault = $prefs->get('defaultUserId');
	if (!$currDefault || !exists $accounts->{$currDefault} || !$accounts->{$currDefault}{token}) {
		$prefs->set('defaultUserId', $userId);
	}

	return 1;
}

# Delete an account
sub deleteAccount {
	my ($class, $userId) = @_;
	return unless defined $userId && length($userId);

	my $accounts = $class->getAccounts();
	if (exists $accounts->{$userId}) {
		delete $accounts->{$userId};
		$prefs->set('accounts', $accounts);

		# If deleted account was default, heal to another account
		my $currDefault = $prefs->get('defaultUserId');
		if ($currDefault && $currDefault eq $userId) {
			my $newDefault = $class->getSomeUserId();
			$prefs->set('defaultUserId', $newDefault);
		}
		return 1;
	}
	return 0;
}

1;
