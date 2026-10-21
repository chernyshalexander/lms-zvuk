#!/usr/bin/env perl
# Regression test: API/Async.pm::_graphql's HTTP error handler must use the
# real numeric HTTP status code, not pattern-match the error string.
#
# Root cause this guards against: Slim::Networking::Async::HTTP routes ANY
# non-2xx/3xx response to the error callback as soon as headers are read,
# BEFORE the body is fetched (Async/HTTP.pm:432-434) -- so the response
# body (e.g. a GraphQL error message) is never available for error
# responses, only the status code. The error handler used to derive $code
# by regex-matching the error string against 429/502/503/504/timeout and
# defaulted anything else (including 400/401/404/409) to code=>0, which
# Retry.pm::is_retryable treats as a retryable timeout -- so a definitively
# non-retryable 400 (bad query/variables) got retried 5 times with growing
# exponential backoff before finally giving up, ~24s wasted for nothing.
#
# Run: perl t/test_graphql_error_classification.pl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

require "$Bin/slim_mocks.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

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

# A valid-enough token so _graphql doesn't short-circuit before hitting the
# HTTP layer.
{
    no warnings 'once';
    $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
}

my $api = Plugins::Zvuk::API::Async->new({ userId => 'acctA' });

# ---------------------------------------------------------------------
# HTTP 400 (client/query error) must NOT be retried -- it's in Retry.pm's
# explicit non-retryable list, but only takes effect if $code is actually
# 400 and not the old code=>0 fallback.
# ---------------------------------------------------------------------
{
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = ({ code => 400 });

    my $result;
    $api->_graphql(sub { $result = shift }, 'testOp400', 'query{}', {}, { ttl => 0 });
    drain(\$result);

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 1,
        "HTTP 400 makes exactly one attempt -- not retried");
    ok(defined $result && $result->{error}, "callback receives an error result for HTTP 400");
}

# ---------------------------------------------------------------------
# HTTP 503 (retryable server error) must actually retry and can succeed.
# ---------------------------------------------------------------------
{
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { code => 503 },
        { code => 200, content => '{"data":{"ok":1}}' },
    );

    my $result;
    $api->_graphql(sub { $result = shift }, 'testOp503', 'query{}', {}, { ttl => 0 });
    drain(\$result);

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 2,
        "HTTP 503 is retried -- second attempt is made");
    ok(defined $result && !$result->{error} && $result->{ok} == 1,
        "retry succeeds and returns the second attempt's data");
}

# ---------------------------------------------------------------------
# A genuine network failure (no HTTP response at all) must still be
# treated as retryable, same as before this fix.
# ---------------------------------------------------------------------
{
    @Slim::Utils::Timers::SCHEDULED = ();
    @Slim::Networking::SimpleAsyncHTTP::POST_LOG = ();
    @Slim::Networking::SimpleAsyncHTTP::RESPONSES = (
        { network_error => 'Connection refused' },
        { code => 200, content => '{"data":{"ok":1}}' },
    );

    my $result;
    $api->_graphql(sub { $result = shift }, 'testOpNetErr', 'query{}', {}, { ttl => 0 });
    drain(\$result);

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::POST_LOG), 2,
        "a genuine network error (no HTTP response) is still retried");
    ok(defined $result && !$result->{error}, "retry succeeds after the transient network error");
}

done_testing();
