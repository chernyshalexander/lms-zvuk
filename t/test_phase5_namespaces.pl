#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';
binmode Test::More->builder->output, ':utf8';
binmode Test::More->builder->failure_output, ':utf8';
binmode Test::More->builder->todo_output, ':utf8';

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Session;
require Plugins::Zvuk::API;
require Plugins::Zvuk::UI::Common;
require Plugins::Zvuk::UI::Wave;
require Plugins::Zvuk::UI::Atlas;
require Plugins::Zvuk::UI::GigaMix;
require Plugins::Zvuk::UI::InfoMenu;
require Plugins::Zvuk::WaveUI;
require Plugins::Zvuk::AtlasUI;
require Plugins::Zvuk::GigaMix;
require Plugins::Zvuk::Browse::InfoMenu;

subtest 'Plugins::Zvuk::Session account lifecycle & auto-healing' => sub {
	my $prefs = Slim::Utils::Prefs::preferences('plugin.zvuk');
	$prefs->set('accounts', {});
	$prefs->set('defaultUserId', undef);

	ok(!Plugins::Zvuk::Session->hasAccounts(), 'hasAccounts is false when empty');
	is(Plugins::Zvuk::Session->getSomeUserId(), undef, 'getSomeUserId returns undef when empty');

	# Save account 1
	Plugins::Zvuk::Session->saveAccount('user_100', {
		token => 'token_100_abcdef',
		name  => 'User One Hundred',
	});

	ok(Plugins::Zvuk::Session->hasAccounts(), 'hasAccounts is true after saving account');
	is(Plugins::Zvuk::Session->getSomeUserId(), 'user_100', 'getSomeUserId returns user_100 as default');
	is(Plugins::Zvuk::Session->getToken('user_100'), 'token_100_abcdef', 'getToken returns correct token');
	is(Plugins::Zvuk::Session->getUserdata('user_100')->{name}, 'User One Hundred', 'getUserdata returns correct name');

	# Save account 2
	Plugins::Zvuk::Session->saveAccount('user_200', {
		token => 'token_200_xyz',
		name  => 'User Two Hundred',
	});

	# Player binding and auto-healing
	my $client = Test::FakeClient->new(id => 'test_client_session');
	$prefs->client($client)->set('userId', 'user_200');
	is(Plugins::Zvuk::Session->getUserIdForClient($client), 'user_200', 'client gets assigned user_200');

	# Stale client userId auto-healing
	$prefs->client($client)->set('userId', 'non_existent_user');
	my $healed_id = Plugins::Zvuk::Session->getUserIdForClient($client);
	is($healed_id, 'user_100', 'stale client userId heals to defaultUserId user_100');
	is($prefs->client($client)->get('userId'), 'user_100', 'client preference updated in storage');

	# Delete account
	ok(Plugins::Zvuk::Session->deleteAccount('user_100'), 'deleteAccount user_100 succeeded');
	is(Plugins::Zvuk::Session->getSomeUserId(), 'user_200', 'new default healed to remaining account user_200');
};

subtest 'Plugins::Zvuk::API delegation to Session and unified getClient' => sub {
	my $prefs = Slim::Utils::Prefs::preferences('plugin.zvuk');
	$prefs->set('accounts', {
		user_test => {
			token => 'token_test_123',
			name  => 'Tester',
		}
	});
	$prefs->set('defaultUserId', 'user_test');

	# Backward compatible API delegates
	is(Plugins::Zvuk::API->getSomeUserId(), 'user_test', 'API->getSomeUserId delegates to Session');
	is(Plugins::Zvuk::API->getToken('user_test'), 'token_test_123', 'API->getToken delegates to Session');
	is(Plugins::Zvuk::API->getUserdata('user_test')->{name}, 'Tester', 'API->getUserdata delegates to Session');
	ok(Plugins::Zvuk::API->hasAccounts(), 'API->hasAccounts delegates to Session');

	my $client = Test::FakeClient->new(id => 'facade_client');
	my $api = Plugins::Zvuk::API->getClient($client);
	ok($api, 'getClient($client) returns API instance');
	is($api->accountId, 'user_test', 'API client has resolved accountId');
	is($api->{userId}, 'user_test', 'API client has resolved userId');
};

subtest 'UI Namespaces & Backward-Compatible Shims' => sub {
	# Wave
	is(\&Plugins::Zvuk::WaveUI::handleStartWave, \&Plugins::Zvuk::UI::Wave::handleStartWave,
		'WaveUI::handleStartWave aliased to UI::Wave::handleStartWave');
	is(\&Plugins::Zvuk::WaveUI::_getWaveMenuItems, \&Plugins::Zvuk::UI::Wave::_getWaveMenuItems,
		'WaveUI::_getWaveMenuItems aliased to UI::Wave::_getWaveMenuItems');

	# Atlas
	is(\&Plugins::Zvuk::AtlasUI::handleAtlasMenu, \&Plugins::Zvuk::UI::Atlas::handleAtlasMenu,
		'AtlasUI::handleAtlasMenu aliased to UI::Atlas::handleAtlasMenu');
	is(\&Plugins::Zvuk::AtlasUI::handleAllIslands, \&Plugins::Zvuk::UI::Atlas::handleAllIslands,
		'AtlasUI::handleAllIslands aliased to UI::Atlas::handleAllIslands');
	is(\&Plugins::Zvuk::AtlasUI::handleStartIslandWave, \&Plugins::Zvuk::UI::Atlas::handleStartIslandWave,
		'AtlasUI::handleStartIslandWave aliased to UI::Atlas::handleStartIslandWave');

	# GigaMix
	is(\&Plugins::Zvuk::GigaMix::handleGigaMix, \&Plugins::Zvuk::UI::GigaMix::handleGigaMix,
		'GigaMix::handleGigaMix aliased to UI::GigaMix::handleGigaMix');
	is(\&Plugins::Zvuk::GigaMix::_renderGigaMixPlaylist, \&Plugins::Zvuk::UI::GigaMix::_renderGigaMixPlaylist,
		'GigaMix::_renderGigaMixPlaylist aliased to UI::GigaMix::_renderGigaMixPlaylist');

	# InfoMenu
	is(\&Plugins::Zvuk::Browse::InfoMenu::trackInfoMenu, \&Plugins::Zvuk::UI::InfoMenu::trackInfoMenu,
		'Browse::InfoMenu::trackInfoMenu aliased to UI::InfoMenu::trackInfoMenu');
	is(\&Plugins::Zvuk::Browse::InfoMenu::albumInfoMenu, \&Plugins::Zvuk::UI::InfoMenu::albumInfoMenu,
		'Browse::InfoMenu::albumInfoMenu aliased to UI::InfoMenu::albumInfoMenu');
	is(\&Plugins::Zvuk::Browse::InfoMenu::artistInfoMenu, \&Plugins::Zvuk::UI::InfoMenu::artistInfoMenu,
		'Browse::InfoMenu::artistInfoMenu aliased to UI::InfoMenu::artistInfoMenu');
};

done_testing();
