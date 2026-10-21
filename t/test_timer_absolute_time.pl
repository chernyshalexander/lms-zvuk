#!/usr/bin/env perl
# Regression test: Slim::Utils::Timers::setTimer's $when parameter is an
# ABSOLUTE epoch time (Slim/Utils/Timers.pm:66-95, fired via
# EV::timer($when - $now, ...)), not a relative delay. Throttle.pm and
# Retry.pm used to pass the bare relative delay straight through, which
# made EV::timer's interval hugely negative (epoch ~1.7e9 minus a delay of
# ~0.5) and fire almost immediately instead of actually waiting -- silently
# defeating both rate limiting and retry backoff.
#
# Run: perl t/test_timer_absolute_time.pl
use strict;
use warnings;
use FindBin qw($Bin);
use Time::HiRes qw(time);

require "$Bin/slim_mocks.pl";

require "$Bin/../Throttle.pm";
require "$Bin/../Retry.pm";

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
# Throttle.pm::acquire -- once the rate limit is hit, the scheduled $when
# must be close to time()+period, not a small raw delay like ~1.0.
# ---------------------------------------------------------------------
{
    @Slim::Utils::Timers::SCHEDULED = ();
    my $throttle = Plugins::Zvuk::Throttle->new(1, 1.0);  # 1 req/sec

    my @delays;
    $throttle->acquire(sub { push @delays, shift });  # immediate, fills the 1 slot
    $throttle->acquire(sub { push @delays, shift });  # must be scheduled

    ok(scalar(@delays) == 1, "second acquire() is deferred, not immediate");
    ok(scalar(@Slim::Utils::Timers::SCHEDULED) == 1, "exactly one timer was scheduled");

    my $when = $Slim::Utils::Timers::SCHEDULED[0]{when};
    my $now  = time();
    ok($when > $now + 0.5, "scheduled \$when is an absolute future epoch time (was: bare relative delay ~1.0, now: ~$now + delay)");
    ok($when < $now + 5, "scheduled \$when is not absurdly far in the future either");

    Slim::Utils::Timers::fireAll();
    ok(scalar(@delays) == 2, "firing the timer runs the deferred acquire callback");
}

# ---------------------------------------------------------------------
# Retry.pm::execute -- backoff retry must also schedule an absolute time.
# ---------------------------------------------------------------------
{
    @Slim::Utils::Timers::SCHEDULED = ();
    my $retry = Plugins::Zvuk::Retry->new(2, 0.5);  # 2 attempts, 0.5s initial backoff

    my $attempt = 0;
    my $final;
    $retry->execute(
        sub { $final = shift },
        sub {
            my $cb = shift;
            $attempt++;
            if ($attempt == 1) {
                $cb->({ error => 'Service Unavailable', code => 503 });  # retryable
            } else {
                $cb->({ data => 'ok' });
            }
        },
    );

    ok(scalar(@Slim::Utils::Timers::SCHEDULED) == 1, "retryable error schedules exactly one backoff timer");

    my $when = $Slim::Utils::Timers::SCHEDULED[0]{when};
    my $now  = time();
    ok($when > $now + 0.1, "backoff \$when is an absolute future epoch time (was: bare relative delay ~0.5)");
    ok($when < $now + 60, "backoff \$when is not absurdly far in the future either");

    ok(!defined $final, "on_success_cb has not fired yet -- still waiting on the (correctly deferred) backoff timer");

    Slim::Utils::Timers::fireAll();
    ok($attempt == 2, "firing the timer retries the operation");
    ok(defined $final && $final->{data} eq 'ok', "retry eventually succeeds and reports the final result");
}

print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");
exit($failures ? 1 : 0);
