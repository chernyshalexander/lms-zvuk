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

# -------------------------------------------------------------------------
# Test 1: extractAccountName helper priority checks
# -------------------------------------------------------------------------
{
    my $prof1 = {
        id => 101,
        external_profile => {
            first_name  => 'Иван',
            middle_name => 'Иванович',
            last_name   => 'Иванов'
        }
    };
    is(Plugins::Zvuk::API->extractAccountName($prof1, 101), 'Иван Иванович Иванов',
        'extractAccountName: external_profile full name extracted');

    my $prof2 = {
        id => 102,
        name => 'Simple Name',
        username => 'username102'
    };
    is(Plugins::Zvuk::API->extractAccountName($prof2, 102), 'Simple Name',
        'extractAccountName: simple name prioritized over username');

    my $prof3 = {
        id => 103,
        username => 'user_only'
    };
    is(Plugins::Zvuk::API->extractAccountName($prof3, 103), 'user_only',
        'extractAccountName: username used when name missing');

    my $prof4 = { id => 104 };
    is(Plugins::Zvuk::API->extractAccountName($prof4, 104), 'Account 104',
        'extractAccountName: fallback to Account <id>');
}

# -------------------------------------------------------------------------
# Test 2: Invalid token format rejected immediately
# -------------------------------------------------------------------------
{
    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req = Test::FakeHTTPRequest->new('{"token":"invalid-short"}');
    my $httpConn = Test::FakeHTTPConnection->new($req);
    my $resp = Test::FakeHTTPHandlerResponse->new($req);

    Plugins::Zvuk::WebHandlers::handleSaveOAuthToken($httpConn, $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Invalid token: response sent');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, 'Invalid token: HTTP 400');
    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 0, 'Invalid token: success = 0');
    like($body->{error}, qr/Invalid token format/, 'Invalid token: correct error message');
}

# -------------------------------------------------------------------------
# Test 3: Successful token save with real userId and cleanup of legacy temp
# -------------------------------------------------------------------------
{
    my $validToken = '0123456789abcdef0123456789abcdef';
    my $legacyTempId = substr($validToken, 0, 16); # '0123456789abcdef'

    # Setup pre-existing state with legacy temp account
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = {
        $legacyTempId => {
            token => $validToken,
            name  => "Account $legacyTempId"
        }
    };
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{defaultUserId} = $legacyTempId;

    my $fakeClient = Test::FakeClient->new(id => 'player_test_1');
    $Slim::Player::Client::CLIENTS{'player_test_1'} = $fakeClient;
    $Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{'player_test_1'}{userId} = $legacyTempId;

    # Mock SimpleAsyncHTTP to return profile for getProfile
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code => 200,
            content => encode_json({
                result => {
                    id => 778899,
                    name => 'Тестовый Пользователь',
                    email => 'test@zvuk.com'
                }
            })
        }
    );

    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req = Test::FakeHTTPRequest->new(encode_json({ token => $validToken }));
    my $httpConn = Test::FakeHTTPConnection->new($req);
    my $resp = Test::FakeHTTPHandlerResponse->new($req);

    Plugins::Zvuk::WebHandlers::handleSaveOAuthToken($httpConn, $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Valid token: async response sent');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 200, 'Valid token: HTTP 200');

    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 1, 'Valid token: success = 1');
    is($body->{account}{userId}, 778899, 'Valid token: returned real userId 778899');
    is($body->{account}{name}, 'Тестовый Пользователь', 'Valid token: returned real name');

    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    ok(exists $accounts->{778899}, 'Real userId stored in accounts pref');
    is($accounts->{778899}{token}, $validToken, 'Token correctly stored under real userId');
    is($accounts->{778899}{name}, 'Тестовый Пользователь', 'Name correctly stored under real userId');

    ok(!exists $accounts->{$legacyTempId}, 'Legacy temp account cleanly removed from accounts pref');
    is($Slim::Utils::Prefs::STORE{'plugin.zvuk'}{defaultUserId}, 778899, 'defaultUserId migrated to real userId');
    is($Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{'player_test_1'}{userId}, 778899,
        'Connected player userId migrated from legacy temp to real userId');
}

# -------------------------------------------------------------------------
# Test 4: Profile fetch failure returns HTTP 400 and preserves existing prefs
# -------------------------------------------------------------------------
{
    my $badToken = 'fedcba9876543210fedcba9876543210';

    # Mock SimpleAsyncHTTP error (e.g. 401 Unauthorized from zvuk.com)
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code => 401,
            message => 'Unauthorized'
        }
    );

    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $badReq = Test::FakeHTTPRequest->new(encode_json({ token => $badToken }));
    my $httpConn = Test::FakeHTTPConnection->new($badReq);
    my $resp = Test::FakeHTTPHandlerResponse->new($badReq);

    Plugins::Zvuk::WebHandlers::handleSaveOAuthToken($httpConn, $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Failed profile: error response sent');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 400, 'Failed profile: HTTP 400');
    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 0, 'Failed profile: success = 0');
    ok($body->{error}, 'Failed profile: error description returned');

    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    ok(!exists $accounts->{substr($badToken, 0, 16)}, 'Bad token temp account was NOT created in accounts');
}

# -------------------------------------------------------------------------
# Test 5: Full nested JSON profile payload passed directly
# -------------------------------------------------------------------------
{
    my $fullProfileJson = '{"result":{"token":"aabbccddeeff00112233445566778899","id":112233,"name":"JSON User"}}';

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code => 200,
            content => encode_json({
                result => {
                    id => 112233,
                    name => 'JSON User'
                }
            })
        }
    );

    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req = Test::FakeHTTPRequest->new($fullProfileJson);
    my $httpConn = Test::FakeHTTPConnection->new($req);
    my $resp = Test::FakeHTTPHandlerResponse->new($req);

    Plugins::Zvuk::WebHandlers::handleSaveOAuthToken($httpConn, $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Full JSON: response sent');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 200, 'Full JSON: HTTP 200');
    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 1, 'Full JSON: success = 1');
    is($body->{account}{userId}, 112233, 'Full JSON: extracted userId');

    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{112233}{token}, 'aabbccddeeff00112233445566778899', 'Full JSON: token correctly extracted');
}

# -------------------------------------------------------------------------
# Test 6: Raw dirty text string with whitespace or key-value format
# -------------------------------------------------------------------------
{
    my $dirtyTokenPayload = encode_json({ token => "   token: 99887766554433221100ffeeddccbbaa  \n" });

    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        {
            code => 200,
            content => encode_json({
                result => {
                    id => 445566,
                    name => 'Regex User'
                }
            })
        }
    );

    @Slim::Web::HTTP::CAPTURED_RESPONSES = ();
    my $req = Test::FakeHTTPRequest->new($dirtyTokenPayload);
    my $httpConn = Test::FakeHTTPConnection->new($req);
    my $resp = Test::FakeHTTPHandlerResponse->new($req);

    Plugins::Zvuk::WebHandlers::handleSaveOAuthToken($httpConn, $resp);

    is(scalar @Slim::Web::HTTP::CAPTURED_RESPONSES, 1, 'Dirty token: response sent');
    is($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{response}->code, 200, 'Dirty token: HTTP 200');
    my $body = decode_json($Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body});
    is($body->{success}, 1, 'Dirty token: success = 1');
    is($body->{account}{userId}, 445566, 'Dirty token: extracted userId');

    my $accounts = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts};
    is($accounts->{445566}{token}, '99887766554433221100ffeeddccbbaa', 'Dirty token: clean 32-hex extracted');
}

done_testing();
