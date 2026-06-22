#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More;
use Time::HiRes qw(time sleep);

# Mock Slim::Utils::Timers BEFORE loading Throttle
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

use Plugins::Zvuk::Throttle;

# Test 1: Constructor sets rate_limit and period correctly
my $throttle = Plugins::Zvuk::Throttle->new(5, 1.0);
ok(defined $throttle, 'Constructor returns a defined object');
is($throttle->{rate_limit}, 5, 'rate_limit is set to 5');
is($throttle->{period}, 1.0, 'period is set to 1.0');

# Test 2: Constructor initializes _task_logs as empty array
is(ref($throttle->{_task_logs}), 'ARRAY', '_task_logs is an array');
is(scalar(@{$throttle->{_task_logs}}), 0, '_task_logs starts empty');

# Test 3: acquire() calls callback immediately when under limit
my @test3_results = ();
for my $i (1..3) {
    $throttle->acquire(sub {
        my $delay = shift;
        push @test3_results, $delay;
    });
}
is(scalar(@test3_results), 3, 'All 3 callbacks were called immediately');
my $all_zero = 1;
$all_zero = 0 if grep { $_ != 0 } @test3_results;
ok($all_zero, 'All delays were 0 when under limit');

# Test 4: acquire() schedules callback when at limit
my $throttle2 = Plugins::Zvuk::Throttle->new(2, 1.0);
my @test4_results = ();

for my $i (1..3) {
    $throttle2->acquire(sub {
        my $delay = shift;
        push @test4_results, $delay;
    });
}
is(scalar(@test4_results), 3, 'All 3 callbacks were called (some scheduled)');

# Test 5: Backoff delay is reasonable (>= period)
my $throttle3 = Plugins::Zvuk::Throttle->new(1, 1.0);
my @test5_delays = ();

# First call should be immediate
$throttle3->acquire(sub {
    my $delay = shift;
    push @test5_delays, $delay;
});

# Second call should be scheduled with delay >= period
my $before = time();
$throttle3->acquire(sub {
    my $delay = shift;
    push @test5_delays, $delay;
});
my $after = time();

is(scalar(@test5_delays), 2, 'Both callbacks were called');
is($test5_delays[0], 0, 'First callback had 0 delay');
ok($test5_delays[1] >= 0.99, "Second callback had delay >= 0.99 (got $test5_delays[1])");

done_testing();
