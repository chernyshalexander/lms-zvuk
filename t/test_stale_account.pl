#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
no warnings 'once';

use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;
use JSON::PP;

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
require Plugins::Zvuk::ProtocolHandler;

my $userId = 'user_stale_test';
my $testToken = '11111111111111111111111111111111';

sub reset_state {
    Plugins::Zvuk::API::Async->_resetThrottlerForTesting();
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
        $userId => {
            token => $testToken,
            name  => 'Stale Tester',
            stale => 0,
        }
    };
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = ();
    @Slim::Networking::SimpleAsyncHTTP::PENDING_CALLS = ();
    @Slim::Utils::Timers::SCHEDULED = ();
}

# =========================================================================
# Scenario 1: _graphql receives HTTP 401 -> marks stale = 1
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 401, message => 'Unauthorized' }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    ok($err || ($res && $res->{error}), 'Scenario 1: 401 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 1, 'Scenario 1: account marked as stale in prefs on HTTP 401');
}

# =========================================================================
# Scenario 2: _graphql receives HTTP 422 -> marks stale = 1
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 422, message => 'Unprocessable Entity' }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    ok($err || ($res && $res->{error}), 'Scenario 2: 422 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 1, 'Scenario 2: account marked as stale in prefs on HTTP 422');
}

# =========================================================================
# Scenario 3: _graphql receives HTTP 403 -> marks stale = 1
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 403, message => 'Forbidden' }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    ok($err || ($res && $res->{error}), 'Scenario 3: 403 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 1, 'Scenario 3: account marked as stale in prefs on HTTP 403');
}

# =========================================================================
# Scenario 4: _graphql receives HTTP 400 -> marks stale = 1
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 400, message => 'Bad Request' }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    ok($err || ($res && $res->{error}), 'Scenario 4: 400 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 1, 'Scenario 4: account marked as stale in prefs on HTTP 400');
}

# =========================================================================
# Scenario 5: _graphql receives HTTP 500 -> does NOT mark stale
# =========================================================================
{
    reset_state();

    # 500 errors may be retried until attempts exhausted
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = map { { code => 500, message => 'Internal Server Error' } } (1 .. 6);

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    while (@Slim::Utils::Timers::SCHEDULED) {
        Slim::Utils::Timers::fireAll();
    }

    ok($err || ($res && $res->{error}), 'Scenario 5: 500 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 0, 'Scenario 5: account is NOT stale after HTTP 500 server error');
}

# =========================================================================
# Scenario 6: _graphql receives network failure (code 0) -> does NOT mark stale
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = map { { code => 0, error => 'Connection timed out' } } (1 .. 6);

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    while (@Slim::Utils::Timers::SCHEDULED) {
        Slim::Utils::Timers::fireAll();
    }

    ok($err || ($res && $res->{error}), 'Scenario 6: network failure returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 0, 'Scenario 6: account is NOT stale after network failure / timeout');
}

# =========================================================================
# Scenario 7: _graphql receives HTTP 429 (rate limit) -> does NOT mark stale
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = map { { code => 429, message => 'Too Many Requests' } } (1 .. 6);

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    while (@Slim::Utils::Timers::SCHEDULED) {
        Slim::Utils::Timers::fireAll();
    }

    ok($err || ($res && $res->{error}), 'Scenario 7: 429 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 0, 'Scenario 7: account is NOT stale after HTTP 429 rate limit');
}

# =========================================================================
# Scenario 8: Fast-path stale check in _graphql -> aborts without HTTP call
# =========================================================================
{
    reset_state();
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}{$userId}{stale} = 1;

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($res, $err);
    $api->_graphql(sub { ($res, $err) = @_ }, 'getProfile', 'query { profile { id } }');

    ok($err || ($res && $res->{error}), 'Scenario 8: stale account returned error');
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 0, 'Scenario 8: no HTTP requests sent when stale = 1');
}

# =========================================================================
# Scenario 9: _http_get receives HTTP 401 -> marks stale = 1
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 401, message => 'Unauthorized' }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($data, $err);
    $api->_http_get('https://zvuk.com/api/tiny/profile', undef, sub { ($data, $err) = @_ });

    ok($err || ($data && $data->{error}), 'Scenario 9: 401 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 1, 'Scenario 9: account marked stale in prefs on _http_get 401');
}

# =========================================================================
# Scenario 10: _http_get receives HTTP 404 -> marks stale = 1
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 404, message => 'Not Found' }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($data, $err);
    $api->_http_get('https://zvuk.com/api/tiny/profile', undef, sub { ($data, $err) = @_ });

    ok($err || ($data && $data->{error}), 'Scenario 10: 404 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 1, 'Scenario 10: account marked stale in prefs on _http_get 404');
}

# =========================================================================
# Scenario 11: _http_get receives HTTP 502 -> does NOT mark stale
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = map { { code => 502, message => 'Bad Gateway' } } (1 .. 6);

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($data, $err);
    $api->_http_get('https://zvuk.com/api/tiny/profile', undef, sub { ($data, $err) = @_ });

    while (@Slim::Utils::Timers::SCHEDULED) {
        Slim::Utils::Timers::fireAll();
    }

    ok($err || ($data && $data->{error}), 'Scenario 11: 502 returned error');
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 0, 'Scenario 11: account is NOT stale after HTTP 502');
}

# =========================================================================
# Scenario 12: Fast-path stale check in _http_get -> aborts without HTTP call
# =========================================================================
{
    reset_state();
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}{$userId}{stale} = 1;

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($data, $err);
    $api->_http_get('https://zvuk.com/api/tiny/profile', undef, sub { ($data, $err) = @_ });

    ok($err || ($data && $data->{error}), 'Scenario 12: stale account returned error');
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 0, 'Scenario 12: no HTTP requests sent when stale = 1');
}

# =========================================================================
# Scenario 13: ProtocolHandler::getNextTrack reports auth expired when stale
# =========================================================================
{
    reset_state();
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}{$userId}{stale} = 1;

    my $client = Test::FakeClient->new(id => 'stale_player_1');
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = $userId;

    my ($next_track, $error_msg);
    my $track_url = 'zvuk://12345';
    my $song = Test::FakeSong->new(url => $track_url, client => $client);

    Plugins::Zvuk::ProtocolHandler->getNextTrack(
        $song,
        sub { $next_track = shift; },
        sub { $error_msg = shift; }
    );

    is($next_track, undef, 'Scenario 13: next track is undef when account is stale');
    is($error_msg, 'PLUGIN_ZVUK_AUTH_EXPIRED', 'Scenario 13: reported PLUGIN_ZVUK_AUTH_EXPIRED to errorCb');
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 0, 'Scenario 13: no HTTP calls made for stale playback');
    ok(defined $client->{last_show_briefly}, 'Scenario 13: triggered showBriefly on player client');
}

# =========================================================================
# Scenario 14: Option A1 - handleFeed returns blocking screen for stale account
# =========================================================================
{
    reset_state();
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}{$userId}{stale} = 1;

    my $client = Test::FakeClient->new(id => 'stale_feed_player');
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = $userId;

    my $feed_items;
    Plugins::Zvuk::Plugin::handleFeed($client, sub { $feed_items = shift });

    ok(ref $feed_items eq 'ARRAY', 'Scenario 14: handleFeed returned array of items');
    is(scalar @$feed_items, 2, 'Scenario 14: exactly 2 items in blocking screen (title + desc)');
    is($feed_items->[0]{type}, 'text', 'Scenario 14: item 0 is text type');
    is($feed_items->[0]{name}, 'PLUGIN_ZVUK_AUTH_EXPIRED_TITLE', 'Scenario 14: item 0 is auth expired title');
    is($feed_items->[1]{type}, 'text', 'Scenario 14: item 1 is text type');
    is($feed_items->[1]{weblink}, undef, 'Scenario 14: item 1 has no weblink');
    is($feed_items->[1]{name}, 'PLUGIN_ZVUK_AUTH_EXPIRED_DESC', 'Scenario 14: item 1 is auth expired desc');
}

# =========================================================================
# Scenario 15: Option B - notifyAuthExpired sends showBriefly to client
# =========================================================================
{
    reset_state();
    my $client = Test::FakeClient->new(id => 'notify_player');
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = $userId;

    Plugins::Zvuk::Plugin->notifyAuthExpired($userId);

    ok(defined $client->{last_show_briefly}, 'Scenario 15: showBriefly called on bound client');
    my $lines = $client->{last_show_briefly}{line};
    is($lines->[0], 'PLUGIN_ZVUK_AUTH_EXPIRED_TITLE', 'Scenario 15: showBriefly line 0 is title');
    is($lines->[1], 'PLUGIN_ZVUK_AUTH_EXPIRED', 'Scenario 15: showBriefly line 1 is auth expired text');
}

# =========================================================================
# Scenario 16: Option D - Settings::beforeRender sets has_stale_accounts
# =========================================================================
{
    reset_state();
    require Plugins::Zvuk::Settings;

    # Case 1: stale = 0 -> has_stale_accounts is 0
    my $params1 = {};
    Plugins::Zvuk::Settings->beforeRender($params1);
    is($params1->{has_stale_accounts}, 0, 'Scenario 16: has_stale_accounts is 0 when all accounts active');
    is(scalar @{ $params1->{stale_accounts} }, 0, 'Scenario 16: stale_accounts list is empty');

    # Case 2: stale = 1 -> has_stale_accounts is 1
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}{$userId}{stale} = 1;
    my $params2 = {};
    Plugins::Zvuk::Settings->beforeRender($params2);
    is($params2->{has_stale_accounts}, 1, 'Scenario 16: has_stale_accounts is 1 when account is stale');
    is(scalar @{ $params2->{stale_accounts} }, 1, 'Scenario 16: stale_accounts contains 1 account');
    is($params2->{stale_accounts}[0]{userId}, $userId, 'Scenario 16: stale account userId matches');
    is($params2->{accounts}[0]{stale}, 1, 'Scenario 16: account in list has stale=1 flag');
}

# =========================================================================
# Scenario 17: Simulation endpoint - handleSimulateStale marks stale and restores
# =========================================================================
{
    reset_state();
    require Plugins::Zvuk::WebHandlers;

    my $client = Test::FakeClient->new(id => 'sim_player');
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = $userId;

    # 1. Simulate stale
    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req1 = Test::FakeRequest->new(
        client => $client,
        query  => { userId => $userId }
    );
    my $resp1 = Test::FakeResponse->new($req1);
    Plugins::Zvuk::WebHandlers::handleSimulateStale('dummy_conn', $resp1);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Scenario 17: response sent for simulate');
    my $body1 = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body1->{success}, 1, 'Scenario 17: simulate success = 1');
    is($body1->{stale}, 1, 'Scenario 17: simulate response stale = 1');
    is($Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}{$userId}{stale}, 1, 'Scenario 17: account marked stale in prefs');
    ok(defined $client->{last_show_briefly}, 'Scenario 17: showBriefly fired on player during simulation');

    # 2. Restore account
    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req2 = Test::FakeRequest->new(
        client => $client,
        query  => { userId => $userId, restore => '1' }
    );
    my $resp2 = Test::FakeResponse->new($req2);
    Plugins::Zvuk::WebHandlers::handleSimulateStale('dummy_conn', $resp2);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Scenario 17: response sent for restore');
    my $body2 = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body2->{success}, 1, 'Scenario 17: restore success = 1');
    is($body2->{stale}, 0, 'Scenario 17: restore response stale = 0');
    is($Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}{$userId}{stale}, 0, 'Scenario 17: account restored in prefs (stale=0)');
}

done_testing();
