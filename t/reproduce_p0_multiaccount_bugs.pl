#!/usr/bin/env perl
# Reproduction + regression harness for the two P0 multi-account bugs
# documented in COMPARISON_REPORT.md section 3.2.1:
#
#   P0.1 - _switchAccount doesn't reset $client->pluginData('zvuk_api'),
#          so Wave/streaming keep using the API handler for the OLD account.
#   P0.2 - handleWaveSettingsWebUI / handleSaveWaveSettingsWeb hardcode
#          account_id = 'default' instead of resolving the real player's
#          account, so Web UI slider changes are saved under the wrong key.
#
# Run: perl t/reproduce_p0_multiaccount_bugs.pl
# Exit code 0 = both fixed, 1 = at least one still broken.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

# Make `require Plugins::Zvuk::X` resolve to the real plugin files at the
# repo root via a throwaway symlink, without touching the repo layout.
my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::ProtocolHandler;
require Plugins::Zvuk::Settings;
require Plugins::Zvuk::WaveSettings;
require Plugins::Zvuk::WaveWizardUI;
require Plugins::Zvuk::WaveUI;
require Plugins::Zvuk::WebHandlers;

my $failures = 0;
sub ok {
    my ($cond, $desc) = @_;
    if ($cond) {
        print "ok - $desc\n";
    } else {
        print "NOT OK - $desc\n";
        $failures++;
    }
}

# ---------------------------------------------------------------------
# Fixtures: two accounts, one player.
# ---------------------------------------------------------------------
{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
        acctA => { token => 'tokA', name => 'Account A' },
        acctB => { token => 'tokB', name => 'Account B' },
    };
}

my $client = Test::FakeClient->new(id => 'player1');
$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';

# =======================================================================
# P0.1 - stale pluginData('zvuk_api') after switching account
# =======================================================================
print "\n--- P0.1: account switch must be seen by Wave/streaming ---\n";

my $api_before = Plugins::Zvuk::WaveUI::_getAPIHandler($client);
ok(defined $api_before && $api_before->accountId eq 'acctA',
    "WaveUI::_getAPIHandler resolves acctA before switch");

my $ph_api_before = Plugins::Zvuk::ProtocolHandler::_getAPIHandler($client);
ok(defined $ph_api_before && $ph_api_before->accountId eq 'acctA',
    "ProtocolHandler::_getAPIHandler resolves acctA before switch");

Plugins::Zvuk::Plugin::_switchAccount($client, sub { }, {}, 'acctB');

ok($Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} eq 'acctB',
    "_switchAccount updates the client's userId pref to acctB");

my $api_after = Plugins::Zvuk::WaveUI::_getAPIHandler($client);
ok(defined $api_after && $api_after->accountId eq 'acctB',
    "WaveUI::_getAPIHandler resolves acctB after switch (was stale acctA)");

my $ph_api_after = Plugins::Zvuk::ProtocolHandler::_getAPIHandler($client);
ok(defined $ph_api_after && $ph_api_after->accountId eq 'acctB',
    "ProtocolHandler::_getAPIHandler resolves acctB after switch (was stale acctA)");

# =======================================================================
# P0.2 - Web UI Wave Settings must save/load under the real account, not 'default'
# =======================================================================
print "\n--- P0.2: Web UI wave settings must use the real player's account ---\n";

# Second player pinned to acctA, to prove the fix picks the RIGHT account
# rather than merely picking "whichever one is not default".
my $client2 = Test::FakeClient->new(id => 'player2');
$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client2->id }{userId} = 'acctA';

my $payload = JSON::PP::encode_json({
    popular => 0.91, energy => 0.2, fun => 0.3,
    language => 'russian', vocal => 0, genres => ['rock', 'metal'],
});

my $request = Test::FakeRequest->new(
    query   => { player => $client2->id },
    content => $payload,
);
my $response = Test::FakeResponse->new($request);

Plugins::Zvuk::WebHandlers::handleSaveWaveSettingsWeb(undef, $response);

my $savedForRealAccount = Plugins::Zvuk::WaveSettings::loadSettings('acctA');
ok(abs(($savedForRealAccount->{popular} // -1) - 0.91) < 1e-9,
    "handleSaveWaveSettingsWeb saves under the real account (acctA) resolved from ?player=");

my $savedForDefault = Plugins::Zvuk::WaveSettings::loadSettings('default');
ok(abs(($savedForDefault->{popular} // -1) - 0.91) > 1e-9,
    "handleSaveWaveSettingsWeb does NOT also/instead save under the hardcoded 'default' key");

print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");
exit($failures ? 1 : 0);
