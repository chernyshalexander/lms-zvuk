#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
no warnings 'once';
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More tests => 22;

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::API;
require Plugins::Zvuk::API::Async;
require Plugins::Zvuk::Settings;

# Clean up prefs store
%Slim::Utils::Prefs::STORE = ();
%Slim::Utils::Prefs::CLIENT_STORE = ();

my $prefs = Slim::Utils::Prefs::preferences('plugin.zvuk');

# -------------------------------------------------------------------------
# Test 1: Single account configured, client with stale non-existent userId
# (The exact bug reported by user where player had userId='1153008481'
# while account was '777701291')
# -------------------------------------------------------------------------
{
    $prefs->set('accounts', {
        '777701291' => {
            name  => 'Александр Николаевич Черныш',
            token => '06ad5eb30f0c471e80001d52901ab35c',
        }
    });
    $prefs->set('defaultUserId', '777701291');

    my $staleClient = Test::FakeClient->new(id => '00:50:56:c0:00:08');
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{'00:50:56:c0:00:08'}{userId} = '1153008481';

    # 1. _getUserIdForClient must discard stale '1153008481' and return '777701291'
    my $resolvedUserId = Plugins::Zvuk::Plugin::_getUserIdForClient($staleClient);
    is($resolvedUserId, '777701291', 'T1: Discarded stale client userId and resolved to valid account');

    # 2. Client pref must be self-healed to '777701291'
    is($prefs->client($staleClient)->get('userId'), '777701291',
        'T1: Client preference auto-healed to valid account');

    # 3. _get_api_client must succeed
    my $api = Plugins::Zvuk::Plugin::_get_api_client($staleClient);
    ok($api, 'T1: _get_api_client succeeded for previously-stale client');
    is($api->accountId, '777701291', 'T1: API client bound to correct userId');

    # 4. handleFeed must render root menu, NOT the "PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN" error
    my $feedResult;
    Plugins::Zvuk::Plugin::handleFeed($staleClient, sub { $feedResult = shift; });
    ok($feedResult, 'T1: handleFeed returned result');
    ok(ref($feedResult) eq 'HASH' && $feedResult->{items}, 'T1: handleFeed returned root menu hash with items');
    is(ref($feedResult), 'HASH', 'T1: Root menu is HASH with items');
    my $firstItemName = ref($feedResult) eq 'HASH' ? $feedResult->{items}[0]{name} : $feedResult->[0]{name};
    isnt($firstItemName, 'PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN',
        'T1: Error "PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN" is NOT displayed');
}

# -------------------------------------------------------------------------
# Test 2: Client with no userId pref set at all
# -------------------------------------------------------------------------
{
    my $newClient = Test::FakeClient->new(id => '76:44:71:8d:06:60');
    my $resolvedUserId = Plugins::Zvuk::Plugin::_getUserIdForClient($newClient);
    is($resolvedUserId, '777701291', 'T2: Fresh client auto-assigned defaultUserId');
    is($prefs->client($newClient)->get('userId'), '777701291', 'T2: Fresh client pref saved');
}

# -------------------------------------------------------------------------
# Test 3: Multiple accounts, explicit selection and fallback on delete
# -------------------------------------------------------------------------
{
    $prefs->set('accounts', {
        'acct1' => { name => 'User One', token => 'token111111111111111111111111111' },
        'acct2' => { name => 'User Two', token => 'token222222222222222222222222222' },
    });
    $prefs->set('defaultUserId', 'acct1');

    my $client2 = Test::FakeClient->new(id => 'client_two');
    $prefs->client($client2)->set('userId', 'acct2');

    # Should retain acct2 because acct2 exists and is valid
    is(Plugins::Zvuk::Plugin::_getUserIdForClient($client2), 'acct2', 'T3: Valid non-default account retained');

    # Now simulate acct2 being deleted in Settings.pm
    my $settingsParams = { delete_acct2 => 1 };
    Plugins::Zvuk::Settings->handler(undef, $settingsParams, sub {});

    ok(!exists $prefs->get('accounts')->{acct2}, 'T3: acct2 deleted from accounts');

    # client2 should now self-heal to defaultUserId (acct1)
    is(Plugins::Zvuk::Plugin::_getUserIdForClient($client2), 'acct1', 'T3: Client auto-healed after account deletion');
    is($prefs->client($client2)->get('userId'), 'acct1', 'T3: Client pref updated to acct1');
}

# -------------------------------------------------------------------------
# Test 4: Plugins::Zvuk::API->getSomeUserId() scenarios
# -------------------------------------------------------------------------
{
    # 4a. defaultUserId valid
    $prefs->set('accounts', {
        'userA' => { name => 'A', token => 'tokA' },
        'userB' => { name => 'B', token => 'tokB' },
    });
    $prefs->set('defaultUserId', 'userB');
    is(Plugins::Zvuk::API->getSomeUserId(), 'userB', 'T4a: getSomeUserId returned defaultUserId');

    # 4b. defaultUserId points to non-existent account -> falls back to userA
    $prefs->set('defaultUserId', 'non_existent');
    is(Plugins::Zvuk::API->getSomeUserId(), 'userA', 'T4b: getSomeUserId fell back to valid account');

    # 4c. Account with empty token is ignored
    $prefs->set('accounts', {
        'emptyTok' => { name => 'Empty', token => '' },
        'validTok' => { name => 'Valid', token => 'tokValid' },
    });
    $prefs->remove('defaultUserId');
    is(Plugins::Zvuk::API->getSomeUserId(), 'validTok', 'T4c: getSomeUserId skipped account without token');

    # 4d. No accounts -> returns undef
    $prefs->set('accounts', {});
    is(Plugins::Zvuk::API->getSomeUserId(), undef, 'T4d: getSomeUserId returned undef when no accounts');

    # 4e. Client when no accounts -> _get_api_client returns undef, handleFeed displays not logged in
    my $c = Test::FakeClient->new(id => 'c_none');
    is(Plugins::Zvuk::Plugin::_get_api_client($c), undef, 'T4e: _get_api_client undef when no accounts');
    my $feedNone;
    Plugins::Zvuk::Plugin::handleFeed($c, sub { $feedNone = shift; });
    is($feedNone->[0]{name}, 'PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN',
        'T4e: handleFeed displays PLUGIN_ZVUK_ERROR_NOT_LOGGED_IN when truly no accounts');
}

# -------------------------------------------------------------------------
# Test 5: Plugins::Zvuk::API->getToken() fallback
# -------------------------------------------------------------------------
{
    $prefs->set('accounts', {
        'myUser' => { name => 'Me', token => 'tokenSecret123' },
    });
    $prefs->set('defaultUserId', 'myUser');

    is(Plugins::Zvuk::API->getToken('myUser'), 'tokenSecret123', 'T5: getToken with explicit userId');
    is(Plugins::Zvuk::API->getToken(), 'tokenSecret123', 'T5: getToken without args uses default/active account');
}
