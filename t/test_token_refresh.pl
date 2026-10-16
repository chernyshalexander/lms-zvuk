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

my $userId = 'user_refresh_123';
my $oldToken = '11111111111111111111111111111111';
my $refreshedToken = '22222222222222222222222222222222';

sub reset_state {
    Plugins::Zvuk::API::Async->_resetThrottlerForTesting();
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
        $userId => {
            token => $oldToken,
            name  => 'Refresh Tester',
            stale => 0,
        }
    };
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = ();
    @Slim::Networking::SimpleAsyncHTTP::PENDING_CALLS = ();
    @Slim::Utils::Timers::SCHEDULED = ();
}

# =========================================================================
# Scenario 1: Direct refreshToken call with successful token rotation
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 200,
            content => encode_json({
                result => {
                    token => $refreshedToken,
                }
            })
        }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($received_token, $received_err);

    $api->refreshToken(sub {
        ($received_token, $received_err) = @_;
    });

    is($received_token, $refreshedToken, 'Scenario 1: refreshToken callback received new token');
    is($received_err, undef, 'Scenario 1: no error');

    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{token}, $refreshedToken, 'Scenario 1: account token updated in prefs');
    is($accounts->{$userId}{stale}, 0, 'Scenario 1: account stale is 0');

    # Inspect HTTP request
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 1, 'Scenario 1: exactly 1 HTTP POST sent');
    my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0];
    is($req->{args}[0], Plugins::Zvuk::API->REFRESH_URL, 'Scenario 1: POST target is REFRESH_URL');

    my %headers = @{ $req->{args} }[1 .. $#{$req->{args}} - 1];
    is($headers{'x-auth-token'}, $oldToken, 'Scenario 1: old token sent in x-auth-token header');
    is($headers{'x-c-p'}, 'Q', 'Scenario 1: x-c-p header is Q');
}

# =========================================================================
# Scenario 2: Concurrent refreshToken calls are coalesced into 1 HTTP POST
# =========================================================================
{
    reset_state();

    # We provide a deferred response to keep the refresh in flight while other callers join
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 200,
            defer   => 1,
            content => encode_json({
                token => $refreshedToken,
            })
        }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($cb1_tok, $cb2_tok, $cb3_tok);

    # Simulate 3 concurrent callers asking to refresh for the same user
    $api->refreshToken(sub { $cb1_tok = shift });
    $api->refreshToken(sub { $cb2_tok = shift });
    $api->refreshToken(sub { $cb3_tok = shift });

    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 1, 'Scenario 2: only 1 HTTP POST sent');
    is(scalar @Slim::Networking::SimpleAsyncHTTP::PENDING_CALLS, 1, 'Scenario 2: 1 HTTP call is pending in flight');

    # Now fire the in-flight HTTP response
    (shift @Slim::Networking::SimpleAsyncHTTP::PENDING_CALLS)->();

    is($cb1_tok, $refreshedToken, 'Scenario 2: caller 1 got refreshed token');
    is($cb2_tok, $refreshedToken, 'Scenario 2: caller 2 got refreshed token');
    is($cb3_tok, $refreshedToken, 'Scenario 2: caller 3 got refreshed token');
}

# =========================================================================
# Scenario 3: Failed refreshToken marks account as stale
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 401,
            message => 'Unauthorized'
        }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($received_token, $received_err);

    $api->refreshToken(sub {
        ($received_token, $received_err) = @_;
    });

    is($received_token, undef, 'Scenario 3: token is undef on failed refresh');
    ok(defined $received_err, 'Scenario 3: error reported');

    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{stale}, 1, 'Scenario 3: account marked as stale in prefs');
}

# =========================================================================
# Scenario 4: _graphql automatic 401 interception, refresh, and retry
# =========================================================================
{
    reset_state();

    # Sequence of responses:
    # 1. GraphQL query -> returns HTTP 401
    # 2. Refresh call  -> returns 200 with new token
    # 3. Retried GraphQL query -> returns 200 with data
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 401,
            message => 'Unauthorized'
        },
        {
            code    => 200,
            content => encode_json({
                result => { token => $refreshedToken }
            })
        },
        {
            code    => 200,
            content => encode_json({
                data => {
                    userCollection => { tracksCount => 42 }
                }
            })
        }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my $final_res;

    $api->_graphql(
        sub { $final_res = shift },
        'getUserCollection',
        'query getUserCollection { userCollection { tracksCount } }',
        {}
    );

    ok($final_res && !$final_res->{error}, 'Scenario 4: GraphQL succeeded after automatic refresh');
    is($final_res->{userCollection}{tracksCount}, 42, 'Scenario 4: payload correctly retrieved');

    # Verify requests sent: 1st GraphQL, then Refresh, then 2nd GraphQL
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 3, 'Scenario 4: exactly 3 HTTP POSTs made');

    # 1st request: GraphQL with old token
    my %headers1 = @{ $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args} }[1 .. $#{ $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args} } - 1];
    is($headers1{'x-auth-token'}, $oldToken, 'Scenario 4: attempt 1 used old token');

    # 2nd request: Refresh POST
    is($Slim::Networking::SimpleAsyncHTTP::POST_LOG[1]{args}[0], Plugins::Zvuk::API->REFRESH_URL, 'Scenario 4: attempt 2 was refresh');

    # 3rd request: GraphQL with NEW token
    my %headers3 = @{ $Slim::Networking::SimpleAsyncHTTP::POST_LOG[2]{args} }[1 .. $#{ $Slim::Networking::SimpleAsyncHTTP::POST_LOG[2]{args} } - 1];
    is($headers3{'x-auth-token'}, $refreshedToken, 'Scenario 4: attempt 3 used NEW token');

    # Verify prefs updated
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{$userId}{token}, $refreshedToken, 'Scenario 4: prefs updated with new token');
    is($accounts->{$userId}{stale}, 0, 'Scenario 4: account is not stale');
}

# =========================================================================
# Scenario 5: _graphql handles GraphQL-level UNAUTHENTICATED error on HTTP 200
# =========================================================================
{
    reset_state();

    # Sequence of responses:
    # 1. GraphQL query returns HTTP 200 but errors with UNAUTHENTICATED
    # 2. Refresh call returns 200 with new token
    # 3. Retried GraphQL query returns 200 with data
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 200,
            content => encode_json({
                errors => [
                    {
                        message => 'Token expired',
                        extensions => { code => 'UNAUTHENTICATED' }
                    }
                ]
            })
        },
        {
            code    => 200,
            content => encode_json({
                result => { token => $refreshedToken }
            })
        },
        {
            code    => 200,
            content => encode_json({
                data => {
                    userCollection => { tracksCount => 99 }
                }
            })
        }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my $final_res;

    $api->_graphql(
        sub { $final_res = shift },
        'getUserCollection',
        'query getUserCollection { userCollection { tracksCount } }',
        {},
        { ttl => 0 }
    );

    ok($final_res && !$final_res->{error}, 'Scenario 5: GraphQL succeeded after UNAUTHENTICATED refresh');
    is($final_res->{userCollection}{tracksCount}, 99, 'Scenario 5: payload retrieved');
}

# =========================================================================
# Scenario 6: _http_get automatic 401 interception, refresh, and retry
# =========================================================================
{
    reset_state();

    # Sequence of responses:
    # 1. REST GET -> returns HTTP 401
    # 2. Refresh POST -> returns 200 with new token
    # 3. Retried REST GET -> returns 200 with data
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 401,
            message => 'Unauthorized'
        },
        {
            code    => 200,
            content => encode_json({
                result => { token => $refreshedToken }
            })
        },
        {
            code    => 200,
            content => encode_json({
                result => {
                    id => 12345,
                    name => 'Refreshed User'
                }
            })
        }
    );

    my $api = Plugins::Zvuk::API::Async->new({ userId => $userId });
    my ($data_res, $err_res);

    $api->_http_get(
        'https://zvuk.com/api/tiny/profile',
        undef,
        sub {
            ($data_res, $err_res) = @_;
        }
    );

    ok(defined $data_res, 'Scenario 6: _http_get succeeded after refresh');
    is($data_res->{result}{name}, 'Refreshed User', 'Scenario 6: data retrieved from retried GET');
    is($err_res, undef, 'Scenario 6: no error reported');
}

done_testing();
