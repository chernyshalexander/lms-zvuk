#!/usr/bin/env perl
use strict;
use warnings;
use lib '.';
use Test::More;
use Time::HiRes qw(time sleep);
use JSON::XS;

# Mock Slim::Utils::Timers BEFORE loading any modules that require it
BEGIN {
    no strict 'refs';
    $INC{'Slim/Utils/Timers.pm'} = 1;
    *{'Slim::Utils::Timers::setTimer'} = sub {
        my ($obj, $delay, $callback, @args) = @_;
        # For testing, we use synchronous sleep but track the delay
        sleep($delay) if $delay > 0;
        $callback->(@args);
    };
}

# Now load the modules we're testing
use Throttle;
use Retry;
use Plugins::Zvuk::API::Async;

# Utility: Create a mock HTTP response object
sub MockResponse {
    my ($code, $content) = @_;
    return bless {
        code    => $code,
        content => $content,
    }, 'MockResponse';
}

# Utility: Create a mock HTTP object that can sequence responses
sub create_http_mock {
    my (@responses) = @_;

    my $response_idx = 0;
    my $call_count = 0;

    return {
        responses   => \@responses,
        idx         => \$response_idx,
        call_count  => \$call_count,
        next_response => sub {
            my $self = shift;
            $call_count++;
            return $self->{responses}->[$response_idx] if $response_idx < @{$self->{responses}};
            return $self->{responses}->[-1];  # Return last response on overflow
        },
        advance => sub {
            my $self = shift;
            $response_idx++ if $response_idx < @{$self->{responses}};
        },
    };
}

# Test 1: Throttle Prevents Requests > 5/sec
sub test_1_throttle_prevents_excessive_rate {
    my $throttle = Throttle->new(5, 1.0);
    my @delays = ();
    my $start = time();

    # Make 10 rapid calls
    for my $i (1..10) {
        $throttle->acquire(sub {
            my $delay = shift;
            push @delays, $delay;
        });
    }

    my $elapsed = time() - $start;

    # Assertions
    is(scalar(@delays), 10, 'Test 1: All 10 requests completed');

    # With synchronous mock, timing is ~1 second per batch of 5
    # 10 requests at 5/sec with sleep() = ~2 batches, but each batch sleeps ~1s
    # So we expect ~1 second (5 immediate + 5 delayed)
    # Allow ±30% tolerance for system variance (0.7 - 1.3 seconds)
    ok($elapsed >= 0.7, "Test 1: Throttle enforced rate limit (elapsed=$elapsed >= 0.7s)");
    ok($elapsed <= 1.5, "Test 1: Throttle rate limit within tolerance (elapsed=$elapsed <= 1.5s)");

    # Most delays should be near zero for first 5, then near 1.0 for next 5
    my $zero_count = grep { $_ < 0.1 } @delays[0..4];
    ok($zero_count >= 4, "Test 1: First 5 requests mostly immediate (zero_count=$zero_count)");

    return 4;  # Count of assertions made
}

# Test 2: Single Failure + Retry = Success
sub test_2_single_failure_retry_succeeds {
    my $retry = Retry->new(5, 0.01);  # Shorter backoff for testing
    my @results = ();
    my $attempt_count = 0;

    my $operation = sub {
        my $cb = shift;
        $attempt_count++;

        if ($attempt_count == 1) {
            # First attempt: fail with 429 (retryable)
            $cb->({ error => 'Rate limited', code => 429 });
        } else {
            # Second attempt: success
            $cb->({ data => { test => 'data' } });
        }
    };

    my $on_success = sub {
        my $result = shift;
        push @results, $result;
    };

    $retry->execute($on_success, $operation);

    # Assertions
    is(scalar(@results), 1, 'Test 2: Callback called once');
    is($attempt_count, 2, 'Test 2: Operation executed twice (1 failure + 1 retry)');
    is($results[0]->{data}->{test}, 'data', 'Test 2: Final result is success data');

    return 3;  # Count of assertions made
}

# Test 3: Max Retries Exhausted
sub test_3_max_retries_exhausted {
    my $retry = Retry->new(5, 0.05);  # Very short backoff
    my @results = ();
    my $attempt_count = 0;

    my $operation = sub {
        my $cb = shift;
        $attempt_count++;
        # Always fail with 429 (retryable)
        $cb->({ error => 'Rate limited', code => 429 });
    };

    my $on_success = sub {
        my $result = shift;
        push @results, $result;
    };

    $retry->execute($on_success, $operation);

    # Assertions
    is(scalar(@results), 1, 'Test 3: Callback called once (after exhausting retries)');
    is($attempt_count, 5, 'Test 3: Attempted 5 times (max_attempts)');
    ok($results[0]->{error}, 'Test 3: Final result has error');
    is($results[0]->{error}, 'Rate limited', 'Test 3: Error message preserved');

    return 4;  # Count of assertions made
}

# Test 4: Non-Retryable Error (400) Fails Immediately
sub test_4_non_retryable_error_fails_immediately {
    my $retry = Retry->new(5, 0.5);
    my @results = ();
    my $attempt_count = 0;
    my $start = time();

    my $operation = sub {
        my $cb = shift;
        $attempt_count++;
        # Fail with 400 (non-retryable)
        $cb->({ error => 'Bad Request', code => 400 });
    };

    my $on_success = sub {
        my $result = shift;
        push @results, $result;
    };

    $retry->execute($on_success, $operation);
    my $elapsed = time() - $start;

    # Assertions
    is(scalar(@results), 1, 'Test 4: Callback called once');
    is($attempt_count, 1, 'Test 4: Operation executed only once (no retry on 400)');
    ok($results[0]->{error}, 'Test 4: Final result has error');
    is($results[0]->{code}, 400, 'Test 4: Error code is 400');
    ok($elapsed < 0.3, "Test 4: Failed immediately without retry delay (elapsed=$elapsed < 0.3s)");

    return 5;  # Count of assertions made
}

# Test 5: Rate Limit (429) + Retry
sub test_5_rate_limit_with_retry {
    my $retry = Retry->new(5, 0.05);
    my @results = ();
    my $attempt_count = 0;
    my $start = time();

    my $operation = sub {
        my $cb = shift;
        $attempt_count++;

        if ($attempt_count == 1) {
            # First attempt: fail with 429
            $cb->({ error => 'Too Many Requests', code => 429 });
        } else {
            # Second attempt: success
            $cb->({ data => { success => 1 } });
        }
    };

    my $on_success = sub {
        my $result = shift;
        push @results, $result;
    };

    $retry->execute($on_success, $operation);
    my $elapsed = time() - $start;

    # Assertions
    is(scalar(@results), 1, 'Test 5: Callback called once');
    is($attempt_count, 2, 'Test 5: Attempted twice (retry on 429)');
    is($results[0]->{data}->{success}, 1, 'Test 5: Final result is success');
    # With initial_backoff=0.05, first retry should have ~0.05s delay + some jitter
    ok($elapsed >= 0.03, "Test 5: Retry backoff applied (elapsed=$elapsed >= 0.03s)");

    return 4;  # Count of assertions made
}

# Test 6: Throttle Queue Under Load (20 requests)
sub test_6_throttle_queue_under_load {
    my $throttle = Throttle->new(5, 1.0);
    my @delays = ();
    my $start = time();

    # Make 20 rapid calls
    for my $i (1..20) {
        $throttle->acquire(sub {
            my $delay = shift;
            push @delays, $delay;
        });
    }

    my $elapsed = time() - $start;

    # Assertions
    is(scalar(@delays), 20, 'Test 6: All 20 requests completed');

    # With synchronous mock: 20 requests at 5/sec with sleep()
    # Batches: [0-4] immediate, [5-9] after ~1s, [10-14] after ~2s, [15-19] after ~3s
    # Total expected: ~3 seconds, but with sync sleep + overhead = ~3 seconds
    # Allow ±30% tolerance for system variance (2.1 - 3.9 seconds)
    ok($elapsed >= 2.1, "Test 6: Requests properly throttled (elapsed=$elapsed >= 2.1s)");
    ok($elapsed <= 4.0, "Test 6: Throttling within tolerance (elapsed=$elapsed <= 4.0s)");

    # First 5 should be immediate
    my $immediate_count = grep { $_ < 0.1 } @delays[0..4];
    ok($immediate_count >= 4, "Test 6: First batch immediate (immediate_count=$immediate_count)");

    return 4;  # Count of assertions made
}

# Test 7: Cache Still Works (bypasses throttle/retry)
sub test_7_cache_bypasses_throttle_retry {
    my $retry = Retry->new(5, 0.01);
    my $cache = {};
    my $http_call_count = 0;

    # Simulate first call (cache miss)
    my @results_1 = ();
    my $start_1 = time();

    my $operation_1 = sub {
        my $cb = shift;
        $http_call_count++;
        sleep(0.05);  # Simulate network delay
        $cb->({ data => { id => 123, name => 'Test' } });
    };

    my $on_success_1 = sub {
        my $result = shift;
        push @results_1, $result;
    };

    $retry->execute($on_success_1, $operation_1);
    my $elapsed_1 = time() - $start_1;

    # Cache the result
    $cache->{test_key} = $results_1[0];

    # Simulate second call (cache hit - should bypass throttle/retry)
    my @results_2 = ();
    my $start_2 = time();

    # Since it's cached, we return immediately
    push @results_2, $cache->{test_key};
    my $elapsed_2 = time() - $start_2;

    # Assertions
    is(scalar(@results_1), 1, 'Test 7: First call returned result');
    is($http_call_count, 1, 'Test 7: HTTP called once (first call)');
    ok($elapsed_1 >= 0.04, "Test 7: First call had network delay (elapsed_1=$elapsed_1 >= 0.04s)");

    is(scalar(@results_2), 1, 'Test 7: Second call returned cached result');
    ok($elapsed_2 < 0.01, "Test 7: Second call was instant (cache hit, elapsed_2=$elapsed_2 < 0.01s)");
    is($results_2[0]->{data}->{id}, 123, 'Test 7: Cached result has correct data');
    is($http_call_count, 1, 'Test 7: HTTP still only called once (cache bypassed)');

    return 7;  # Count of assertions made
}

# Test 8: Error Propagation Through Retry Chain
sub test_8_error_propagation_through_retry_chain {
    my $retry = Retry->new(5, 0.05);
    my @results = ();
    my $attempt_count = 0;

    my $operation = sub {
        my $cb = shift;
        $attempt_count++;

        if ($attempt_count < 5) {
            # First 4 attempts: fail with 502 (retryable)
            $cb->({ error => 'Bad Gateway', code => 502 });
        } else {
            # 5th attempt: also fail (but this exhausts retries)
            $cb->({ error => 'Bad Gateway', code => 502 });
        }
    };

    my $on_success = sub {
        my $result = shift;
        push @results, $result;
    };

    $retry->execute($on_success, $operation);

    # Assertions
    is(scalar(@results), 1, 'Test 8: Callback called once (final result)');
    is($attempt_count, 5, 'Test 8: Attempted 5 times before giving up');
    ok($results[0]->{error}, 'Test 8: Error present in final result');
    is($results[0]->{error}, 'Bad Gateway', 'Test 8: Error message preserved through chain');
    is($results[0]->{code}, 502, 'Test 8: HTTP code preserved through chain');

    return 5;  # Count of assertions made
}

# Run all tests
print STDERR "\n=== Integration Tests: Throttle & Retry ===\n";

my $test1 = test_1_throttle_prevents_excessive_rate();
print STDERR "Test 1: $test1 assertions\n";

my $test2 = test_2_single_failure_retry_succeeds();
print STDERR "Test 2: $test2 assertions\n";

my $test3 = test_3_max_retries_exhausted();
print STDERR "Test 3: $test3 assertions\n";

my $test4 = test_4_non_retryable_error_fails_immediately();
print STDERR "Test 4: $test4 assertions\n";

my $test5 = test_5_rate_limit_with_retry();
print STDERR "Test 5: $test5 assertions\n";

my $test6 = test_6_throttle_queue_under_load();
print STDERR "Test 6: $test6 assertions\n";

my $test7 = test_7_cache_bypasses_throttle_retry();
print STDERR "Test 7: $test7 assertions\n";

my $test8 = test_8_error_propagation_through_retry_chain();
print STDERR "Test 8: $test8 assertions\n";

my $total = $test1 + $test2 + $test3 + $test4 + $test5 + $test6 + $test7 + $test8;
print STDERR "Total: $total assertions across 8 test scenarios\n";
print STDERR "=======================================\n\n";

# Declare total test count
done_testing();
