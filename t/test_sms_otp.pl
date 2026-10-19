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
require Plugins::Zvuk::WebHandlers;

package Test::FakeHTTPRequest {
    sub new {
        my ($class, $body) = @_;
        return bless { body => $body }, $class;
    }
    sub content     { return $_[0]->{body}; }
    sub content_ref { return \$_[0]->{body}; }
}

package Test::FakeHTTPConnection {
    sub new {
        my ($class, $req) = @_;
        return bless { request => $req }, $class;
    }
    sub request { return $_[0]->{request}; }
}

package Test::FakeHTTPHandlerResponse {
    sub new {
        my ($class, $req) = @_;
        return bless { code => 200, headers => {}, request => $req }, $class;
    }
    sub request { return $_[0]->{request}; }
    sub code {
        my ($self, $val) = @_;
        $self->{code} = $val if defined $val;
        return $self->{code};
    }
    sub content_type {
        my ($self, $val) = @_;
        $self->{content_type} = $val if defined $val;
        return $self->{content_type};
    }
    sub content_length {
        my ($self, $val) = @_;
        $self->{content_length} = $val if defined $val;
        return $self->{content_length};
    }
}

sub reset_state {
    Plugins::Zvuk::API::Async->_resetThrottlerForTesting();
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {};
    delete $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{defaultUserId};
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = ();
    @Slim::Networking::SimpleAsyncHTTP::PENDING_CALLS = ();
    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
}

# =========================================================================
# Scenario 1: handleRequestSmsCode validations
# =========================================================================
{
    reset_state();

    # 1a. Missing phone
    my $req1 = Test::FakeHTTPRequest->new('{}');
    my $resp1 = Test::FakeHTTPHandlerResponse->new($req1);
    Plugins::Zvuk::WebHandlers::handleRequestSmsCode(Test::FakeHTTPConnection->new($req1), $resp1);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, '1a: response captured');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, '1a: missing phone returns HTTP 400');
    my $body1 = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body1->{success}, 0, '1a: success = 0');
    like($body1->{error}, qr/Missing phone/, '1a: correct error message');

    # 1b. Invalid phone format
    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req2 = Test::FakeHTTPRequest->new('{"phone":"abc123"}');
    my $resp2 = Test::FakeHTTPHandlerResponse->new($req2);
    Plugins::Zvuk::WebHandlers::handleRequestSmsCode(Test::FakeHTTPConnection->new($req2), $resp2);

    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, '1b: invalid phone returns HTTP 400');
    my $body2 = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body2->{success}, 0, '1b: success = 0');
    like($body2->{error}, qr/Invalid phone number format/, '1b: correct error message');
}

# =========================================================================
# Scenario 2: handleRequestSmsCode success with phone normalization
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 200,
            content => encode_json({ result => { authorization_type => 'otp' } })
        },
        {
            code    => 200,
            content => encode_json({ result => { success => 1 } })
        }
    );

    # Russian number starting with 8 and containing formatting
    my $rawPhone = '8 (999) 123-45-67';
    my $req = Test::FakeHTTPRequest->new(encode_json({ phone => $rawPhone }));
    my $resp = Test::FakeHTTPHandlerResponse->new($req);

    Plugins::Zvuk::WebHandlers::handleRequestSmsCode(Test::FakeHTTPConnection->new($req), $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Scenario 2: response captured');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 200, 'Scenario 2: HTTP 200');
    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 1, 'Scenario 2: success = 1');
    is($body->{phone}, '+79991234567', 'Scenario 2: phone normalized to +79991234567');

    # Inspect HTTP calls to Zvuk: 1st route-authorization-type, 2nd get-mcode
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 2, 'Scenario 2: 2 HTTP POSTs sent (route + mcode)');
    my $postRoute = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0];
    like($postRoute->{args}[0], qr/\Qhttps:\/\/zvuk.com\/api\/tiny\/route-authorization-type\E/, 'Scenario 2: target 1 is route-authorization-type');
    like($postRoute->{args}[0], qr/phone=%2B79991234567/, 'Scenario 2: route query contains phone');

    my $postMcode = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[1];
    like($postMcode->{args}[0], qr/\Qhttps:\/\/zvuk.com\/api\/tiny\/get-mcode\E/, 'Scenario 2: target 2 is get-mcode');
    like($postMcode->{args}[0], qr/phone=%2B79991234567/, 'Scenario 2: mcode query contains phone');
    like($postMcode->{args}[0], qr/type=login/, 'Scenario 2: query contains type=login');
    like($postMcode->{args}[0], qr/length=4/, 'Scenario 2: query contains length=4');

    my %headers = @{ $postMcode->{args} }[1 .. $#{$postMcode->{args}} - 1];
    is($headers{'x-c-p'}, 'Q', 'Scenario 2: header X-C-P is Q');
    is($headers{'x-app-version'}, '4.116.0rs', 'Scenario 2: header X-App-Version is 4.116.0rs');
    is($headers{'x-app-build'}, '511600228', 'Scenario 2: header X-App-Build is 511600228');
}

# =========================================================================
# Scenario 2b: handleRequestSmsCode routed to login_hint (SberID/password)
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 200,
            content => encode_json({ result => { authorization_type => 'login_hint' } })
        }
    );

    my $req = Test::FakeHTTPRequest->new(encode_json({ phone => '+79859911562' }));
    my $resp = Test::FakeHTTPHandlerResponse->new($req);

    Plugins::Zvuk::WebHandlers::handleRequestSmsCode(Test::FakeHTTPConnection->new($req), $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Scenario 2b: response captured');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, 'Scenario 2b: HTTP 400 for login_hint');
    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 0, 'Scenario 2b: success = 0');
    is($body->{auth_type}, 'login_hint', 'Scenario 2b: auth_type = login_hint');
    like($body->{error}, qr/PLUGIN_ZVUK_PHONE_LOGIN_HINT|Сбер ID|парол/, 'Scenario 2b: informative error message returned');

    # Only 1 request sent (route-authorization-type); get-mcode must NOT be called
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 1, 'Scenario 2b: only 1 request sent (no get-mcode)');
}

# =========================================================================
# Scenario 3: handleVerifySmsCode validations
# =========================================================================
{
    reset_state();

    # 3a. Missing code
    my $req1 = Test::FakeHTTPRequest->new('{"phone":"+79991234567"}');
    my $resp1 = Test::FakeHTTPHandlerResponse->new($req1);
    Plugins::Zvuk::WebHandlers::handleVerifySmsCode(Test::FakeHTTPConnection->new($req1), $resp1);

    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, '3a: missing code returns HTTP 400');
    my $body1 = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body1->{success}, 0, '3a: success = 0');

    # 3b. Code too short
    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req2 = Test::FakeHTTPRequest->new('{"phone":"+79991234567","code":"12"}');
    my $resp2 = Test::FakeHTTPHandlerResponse->new($req2);
    Plugins::Zvuk::WebHandlers::handleVerifySmsCode(Test::FakeHTTPConnection->new($req2), $resp2);

    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, '3b: short code returns HTTP 400');
    my $body2 = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body2->{success}, 0, '3b: success = 0');
}

# =========================================================================
# Scenario 4: handleVerifySmsCode failure from Zvuk API
# =========================================================================
{
    reset_state();

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 400,
            content => encode_json({ error => 'Wrong SMS code' })
        }
    );

    my $req = Test::FakeHTTPRequest->new('{"phone":"+79991234567","code":"0000"}');
    my $resp = Test::FakeHTTPHandlerResponse->new($req);
    Plugins::Zvuk::WebHandlers::handleVerifySmsCode(Test::FakeHTTPConnection->new($req), $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Scenario 4: response captured');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, 'Scenario 4: HTTP 400 on wrong code');
    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 0, 'Scenario 4: success = 0');
    like($body->{error}, qr/Wrong SMS code/, 'Scenario 4: error message returned to client');

    is_deeply($Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts}, {}, 'Scenario 4: no account created in prefs');
}

# =========================================================================
# Scenario 5: handleVerifySmsCode success, profile fetch and account save
# =========================================================================
{
    reset_state();

    my $newAuthToken = '33333333333333333333333333333333';
    my $testUserId = 998877;

    # 1. login/otp response
    # 2. getProfile response (via _http_get)
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code    => 200,
            content => encode_json({
                result => {
                    token => $newAuthToken,
                    id    => $testUserId,
                }
            })
        },
        {
            code    => 200,
            content => encode_json({
                result => {
                    id => $testUserId,
                    external_profile => {
                        first_name => 'Александр',
                        last_name  => 'Тестов',
                    }
                }
            })
        }
    );

    my $phone = '+79991234567';
    my $req = Test::FakeHTTPRequest->new(encode_json({ phone => $phone, code => '4321' }));
    my $resp = Test::FakeHTTPHandlerResponse->new($req);

    Plugins::Zvuk::WebHandlers::handleVerifySmsCode(Test::FakeHTTPConnection->new($req), $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Scenario 5: response captured');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 200, 'Scenario 5: HTTP 200 on login success');

    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 1, 'Scenario 5: success = 1');
    is($body->{account}{userId}, $testUserId, 'Scenario 5: returned real userId');
    is($body->{account}{name}, 'Александр Тестов', 'Scenario 5: returned formatted name');

    # Inspect HTTP requests: 1st is login/otp, 2nd is getProfile
    is(scalar @Slim::Networking::SimpleAsyncHTTP::POST_LOG, 2, 'Scenario 5: 2 HTTP requests made (login/otp + getProfile)');
    my $post = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0];
    is($post->{args}[0], Plugins::Zvuk::API->LOGIN_OTP_URL, 'Scenario 5: target is LOGIN_OTP_URL');

    my %headers = @{ $post->{args} }[1 .. $#{$post->{args}} - 1];
    is($headers{'x-c-p'}, 'Q', 'Scenario 5: header X-C-P is Q');
    is($headers{'content-type'}, 'application/x-www-form-urlencoded', 'Scenario 5: content-type is form-urlencoded');

    my $formBody = $post->{args}[-1];
    like($formBody, qr/phone=%2B79991234567/, 'Scenario 5: form body contains escaped phone');
    like($formBody, qr/code=4321/, 'Scenario 5: form body contains code');

    my $profileReq = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[1];
    is($profileReq->{args}[0], Plugins::Zvuk::API->PROFILE_URL, 'Scenario 5: second request is getProfile');

    # Verify account saved in preferences
    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    ok(exists $accounts->{$testUserId}, 'Scenario 5: account created in prefs under real userId');
    is($accounts->{$testUserId}{token}, $newAuthToken, 'Scenario 5: token saved');
    is($accounts->{$testUserId}{name}, 'Александр Тестов', 'Scenario 5: name saved');
    is($accounts->{$testUserId}{phone}, $phone, 'Scenario 5: phone saved');
    is($accounts->{$testUserId}{stale}, 0, 'Scenario 5: stale is 0');
    is($Slim::Utils::Prefs::STORE{'plugin.zvuk'}{defaultUserId}, $testUserId, 'Scenario 5: defaultUserId set');
}

done_testing();
