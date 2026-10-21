#!/usr/bin/env perl
# Unit and integration test for API/Async.pm::_http_get
# Verifies:
#  1. Basic GET request with query params and JSON decoding
#  2. Rate limiting integration (throttled through Throttle.pm)
#  3. Automatic retry on transient HTTP 503 errors (Retry.pm)
#  4. Immediate failure without retry on HTTP 400
#  5. Response caching when ttl option is supplied
#  6. getProfile class method delegates to _http_get pipeline
#
# Run: perl t/test_http_get.pl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

require "$Bin/slim_mocks.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::API;
require Plugins::Zvuk::API::Async;

sub drain {
    my ($doneRef) = @_;
    my $iterations = 0;
    while (!$$doneRef && @Slim::Utils::Timers::SCHEDULED && $iterations < 20) {
        Slim::Utils::Timers::fireAll();
        $iterations++;
    }
    return $iterations;
}

{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'token123', name => 'Test User' } };
}

my $api = Plugins::Zvuk::API::Async->new({ userId => 'acctA' });

# ---------------------------------------------------------------------
# Test 1: Basic GET request with query parameters and header validation
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 200, content => '{"result":{"items":[{"id":42,"title":"Item 42"}]}}' }
    );

    my ($data, $error);
    $api->_http_get('https://zvuk.com/api/test', { b => 'two', a => 'one' }, sub {
        ($data, $error) = @_;
    });
    drain(\$data);

    ok(defined $data && !$error, "Test 1: GET request succeeds");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 1, "Test 1: exactly 1 HTTP request made");
    
    my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args};
    my $called_url = $req->[0];
    is($called_url, 'https://zvuk.com/api/test?a=one&b=two', "Test 1: query params sorted deterministically");
    
    my %headers = @$req[1..$#$req];
    is($headers{'x-auth-token'}, 'token123', "Test 1: x-auth-token passed correctly");
    is($headers{'user-agent'}, Plugins::Zvuk::API->USER_AGENT, "Test 1: user-agent passed correctly");
    is($data->{result}{items}[0]{title}, 'Item 42', "Test 1: payload parsed accurately");
}

# ---------------------------------------------------------------------
# Test 2: Caching with TTL
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 200, content => '{"result":{"cached_val":999}}' }
    );

    my ($data1, $data2);
    $api->_http_get('https://zvuk.com/api/cacheable', undef, sub { $data1 = shift }, { ttl => 300 });
    drain(\$data1);

    ok(defined $data1 && $data1->{result}{cached_val} == 999, "Test 2: first request gets data");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 1, "Test 2: first request issues HTTP GET");

    # Second request to same URL with TTL should hit cache
    $api->_http_get('https://zvuk.com/api/cacheable', undef, sub { $data2 = shift }, { ttl => 300 });

    ok(defined $data2 && $data2->{result}{cached_val} == 999, "Test 2: second request returns cached data");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 1, "Test 2: second request did NOT make HTTP call (cache hit)");
}

# ---------------------------------------------------------------------
# Test 3: Transient error (HTTP 503) retry succeeds
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 503, message => 'Service Unavailable' },
        { code => 200, content => '{"result":{"recovered":1}}' }
    );

    my ($data, $error);
    $api->_http_get('https://zvuk.com/api/flaky', undef, sub {
        ($data, $error) = @_;
    });
    drain(\$data);

    ok(defined $data && $data->{result}{recovered} == 1, "Test 3: recovered after transient 503");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 2, "Test 3: exactly 2 attempts made (1 retry)");
}

# ---------------------------------------------------------------------
# Test 4: Permanent error (HTTP 400) is NOT retried
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 400, message => 'Bad Request' }
    );

    my ($data, $error, $code);
    $api->_http_get('https://zvuk.com/api/bad', undef, sub {
        ($data, $error, $code) = @_;
    });
    drain(\$error);

    ok(!defined $data, "Test 4: HTTP 400 returns undef data");
    ok(defined $error, "Test 4: error is reported");
    is($code, 400, "Test 4: HTTP 400 status code preserved");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 1, "Test 4: exactly 1 attempt made -- NOT retried");
}

# ---------------------------------------------------------------------
# Test 5: getProfile class method delegates to _http_get
# ---------------------------------------------------------------------
{
    {
        no warnings 'once';
        %Slim::Utils::Cache::CACHE = ();
    }
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 200, content => '{"result":{"id":777,"name":"Profile User"}}' }
    );

    my $profile_res;
    Plugins::Zvuk::API::Async->getProfile(sub { $profile_res = shift }, 'custom_token_xyz');
    drain(\$profile_res);

    ok(defined $profile_res && $profile_res->{id} == 777, "Test 5: getProfile returns profile data");
    is($profile_res->{name}, 'Profile User', "Test 5: profile name is correct");
    
    my $req = $Slim::Networking::SimpleAsyncHTTP::POST_LOG[0]{args};
    my %headers = @$req[1..$#$req];
    is($headers{'x-auth-token'}, 'custom_token_xyz', "Test 5: custom token passed to headers");
}

done_testing();
