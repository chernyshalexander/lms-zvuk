#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;
use Time::HiRes qw(time sleep);

# Mock Slim::Utils::Timers BEFORE loading Retry
BEGIN {
    no strict 'refs';
    $INC{'Slim/Utils/Timers.pm'} = 1;
    *{'Slim::Utils::Timers::setTimer'} = sub {
        my ($obj, $delay, $callback, @args) = @_;
        # Immediately call the callback after the specified delay
        # For testing, we'll use sleep but in real code it would be async
        sleep($delay) if $delay > 0;
        $callback->(@args);
    };
}

use Retry;

# Test 1: Constructor sets max_attempts and initial_backoff correctly
my $retry = Retry->new(5, 0.5);
ok(defined $retry, 'Constructor returns a defined object');
is($retry->{max_attempts}, 5, 'max_attempts is set to 5');
is($retry->{initial_backoff}, 0.5, 'initial_backoff is set to 0.5');

# Test 2: Constructor with default values
my $retry_default = Retry->new();
is($retry_default->{max_attempts}, 5, 'max_attempts defaults to 5');
is($retry_default->{initial_backoff}, 0.5, 'initial_backoff defaults to 0.5');

# Test 3: Constructor validates inputs
my $invalid_attempts = 0;
eval {
    Retry->new(0, 0.5);
};
ok($@, 'Constructor dies on zero max_attempts');

eval {
    Retry->new(-1, 0.5);
};
ok($@, 'Constructor dies on negative max_attempts');

eval {
    Retry->new(5, 0);
};
ok($@, 'Constructor dies on zero initial_backoff');

eval {
    Retry->new(5, -0.5);
};
ok($@, 'Constructor dies on negative initial_backoff');

# Test 4: is_retryable() identifies HTTP 429 (rate limit) as retryable
my $is_429 = $retry->is_retryable(429, 'Rate limited');
ok($is_429, 'HTTP 429 is retryable');

# Test 5: is_retryable() identifies HTTP 502, 503, 504 as retryable
my $is_502 = $retry->is_retryable(502, 'Bad Gateway');
ok($is_502, 'HTTP 502 is retryable');

my $is_503 = $retry->is_retryable(503, 'Service Unavailable');
ok($is_503, 'HTTP 503 is retryable');

my $is_504 = $retry->is_retryable(504, 'Gateway Timeout');
ok($is_504, 'HTTP 504 is retryable');

# Test 6: is_retryable() identifies HTTP 0 (timeout) as retryable
my $is_timeout = $retry->is_retryable(0, 'timeout');
ok($is_timeout, 'HTTP 0 (timeout) is retryable');

# Test 7: is_retryable() identifies "timeout" string as retryable
my $timeout_str = $retry->is_retryable(999, 'timeout');
ok($timeout_str, '"timeout" string is retryable');

# Test 8: is_retryable() identifies network errors as retryable
my $conn_error = $retry->is_retryable(0, 'connection refused');
ok($conn_error, 'Connection refused is retryable');

my $conn_reset = $retry->is_retryable(0, 'connection reset');
ok($conn_reset, 'Connection reset is retryable');

# Test 9: is_retryable() identifies HTTP 400, 401, 404, 409 as NOT retryable
my $is_400 = $retry->is_retryable(400, 'Bad Request');
ok(!$is_400, 'HTTP 400 is NOT retryable');

my $is_401 = $retry->is_retryable(401, 'Unauthorized');
ok(!$is_401, 'HTTP 401 is NOT retryable');

my $is_404 = $retry->is_retryable(404, 'Not Found');
ok(!$is_404, 'HTTP 404 is NOT retryable');

my $is_409 = $retry->is_retryable(409, 'Conflict');
ok(!$is_409, 'HTTP 409 is NOT retryable');

# Test 10: is_retryable() identifies GraphQL validation errors as NOT retryable
my $graphql_error = $retry->is_retryable(0, 'GraphQL validation error');
ok(!$graphql_error, 'GraphQL validation error is NOT retryable');

# Test 11: _calculate_backoff() produces exponential sequence
my $b0 = $retry->_calculate_backoff(0);
my $b1 = $retry->_calculate_backoff(1);
my $b2 = $retry->_calculate_backoff(2);
my $b3 = $retry->_calculate_backoff(3);
my $b4 = $retry->_calculate_backoff(4);

# Base values (without jitter) would be: 0.5, 1.0, 2.0, 4.0, 8.0
# With ±25% jitter: 0.5*(0.75-1.25), 1.0*(0.75-1.25), etc.
# So:
# b0: [0.375, 0.625]
# b1: [0.75, 1.25]
# b2: [1.5, 2.5]
# b3: [3.0, 5.0]
# b4: [6.0, 10.0]

ok($b0 >= 0.375 && $b0 <= 0.625, "Backoff 0 is in range [0.375, 0.625], got $b0");
ok($b1 >= 0.75 && $b1 <= 1.25, "Backoff 1 is in range [0.75, 1.25], got $b1");
ok($b2 >= 1.5 && $b2 <= 2.5, "Backoff 2 is in range [1.5, 2.5], got $b2");
ok($b3 >= 3.0 && $b3 <= 5.0, "Backoff 3 is in range [3.0, 5.0], got $b3");
ok($b4 >= 6.0 && $b4 <= 10.0, "Backoff 4 is in range [6.0, 10.0], got $b4");

# Test 12: Backoff respects MAX_BACKOFF cap (120s)
my $large_backoff = $retry->_calculate_backoff(20);
ok($large_backoff <= 120, "Large backoff capped at 120s, got $large_backoff");

# Test 13: execute() succeeds on first attempt
my $retry_test = Retry->new(5, 0.5);
my $success_result = undef;

$retry_test->execute(
    sub {
        my $result = shift;
        $success_result = $result;
    },
    sub {
        my $cb = shift;
        $cb->({ data => 'success', error => undef, code => 200 });
    }
);

is($success_result->{data}, 'success', 'execute() calls on_success with result');
is($success_result->{code}, 200, 'execute() preserves HTTP code');

# Test 14: execute() retries on retryable error
my $retry_count = 0;
my $retry_result = undef;
my $retry_test2 = Retry->new(3, 0.01);

$retry_test2->execute(
    sub {
        my $result = shift;
        $retry_result = $result;
    },
    sub {
        my $cb = shift;
        $retry_count++;
        if ($retry_count < 3) {
            # Simulate retryable error (503)
            $cb->({ error => 'Service Unavailable', code => 503 });
        } else {
            # Success on third attempt
            $cb->({ data => 'success', error => undef, code => 200 });
        }
    }
);

is($retry_count, 3, 'execute() retried 3 times before success');
is($retry_result->{data}, 'success', 'execute() returns final success after retries');

# Test 15: execute() stops on non-retryable error
my $no_retry_count = 0;
my $no_retry_result = undef;
my $retry_test3 = Retry->new(5, 0.01);

$retry_test3->execute(
    sub {
        my $result = shift;
        $no_retry_result = $result;
    },
    sub {
        my $cb = shift;
        $no_retry_count++;
        # Simulate non-retryable error (404)
        $cb->({ error => 'Not Found', code => 404 });
    }
);

is($no_retry_count, 1, 'execute() did not retry on non-retryable error');
is($no_retry_result->{code}, 404, 'execute() returns non-retryable error');

# Test 16: execute() exhausts max_attempts and returns error
my $exhausted_count = 0;
my $exhausted_result = undef;
my $retry_test4 = Retry->new(2, 0.01);

$retry_test4->execute(
    sub {
        my $result = shift;
        $exhausted_result = $result;
    },
    sub {
        my $cb = shift;
        $exhausted_count++;
        # Always return retryable error
        $cb->({ error => 'Service Unavailable', code => 503 });
    }
);

is($exhausted_count, 2, 'execute() exhausted max_attempts (2)');
is($exhausted_result->{code}, 503, 'execute() returns final error after exhaustion');

done_testing();
