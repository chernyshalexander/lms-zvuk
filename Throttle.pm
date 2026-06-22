package Plugins::Zvuk::Throttle;

use strict;
use warnings;
use Time::HiRes qw(time);

=head1 NAME

Throttle - Rate limiter for API requests (5 req/sec max)

=head1 SYNOPSIS

    my $throttle = Throttle->new(5, 1.0);

    $throttle->acquire(sub {
        my $delay = shift;  # Time blocked (0 if immediate)
        # Perform API request here
    });

=head1 DESCRIPTION

Enforces rate limiting by tracking request timestamps and scheduling
callbacks to ensure no more than 5 requests per second are made.

=cut

sub new {
    my ($class, $rate_limit, $period) = @_;

    # Validate inputs
    die "rate_limit must be positive integer" unless $rate_limit && $rate_limit > 0;
    die "period must be positive number" unless $period && $period > 0;

    my $self = {
        rate_limit => $rate_limit,
        period     => $period,
        _task_logs => [],
    };

    return bless $self, $class;
}

=head2 acquire($callback)

Acquires a request slot. If available immediately, calls the callback
with delay=0. Otherwise, schedules the callback for when a slot becomes
available.

The callback receives the actual delay time (in seconds) as its first argument.

=cut

sub acquire {
    my ($self, $callback) = @_;

    require Slim::Utils::Timers;

    $self->_flush();

    my $now = time();

    if (@{$self->{_task_logs}} < $self->{rate_limit}) {
        # Slot available immediately
        push @{$self->{_task_logs}}, $now;
        $callback->(0);
    } else {
        # Slot full, schedule for later
        my $oldest_time = $self->{_task_logs}[0];
        my $delay_until = $oldest_time + $self->{period} - $now;

        # Add timestamp before scheduling the timer, not in the callback
        push @{$self->{_task_logs}}, $now;

        Slim::Utils::Timers::setTimer(
            undef,
            $delay_until,
            sub {
                $callback->($delay_until);
            }
        );
    }
}

=head2 _flush()

Removes timestamps older than the period from the task log.

=cut

sub _flush {
    my ($self) = @_;

    my $now = time();
    my $cutoff = $now - $self->{period};

    # Remove timestamps older than cutoff
    @{$self->{_task_logs}} = grep { $_ > $cutoff } @{$self->{_task_logs}};
}

1;

__END__

=head1 LICENSE

This module is part of the LMS Zvuk Plugin and is licensed under the GPL v2.

=cut
