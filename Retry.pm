package Retry;

use strict;
use warnings;
use Time::HiRes qw(time sleep);

=head1 NAME

Retry - Retry manager with exponential backoff

=head1 SYNOPSIS

    my $retry = Retry->new(5, 0.5);

    $retry->execute(
        sub {
            my $result = shift;
            # on_success callback: receives final result or error
        },
        sub {
            my $cb = shift;
            # operation callback: execute operation, call $cb->($result_hash)
            # $result_hash = { data => ..., error => "...", code => HTTP_CODE }
        }
    );

=head1 DESCRIPTION

Handles transient API errors with exponential backoff and jitter.
Automatically retries on transient errors (429, 502, 503, 504, timeouts)
and gives up immediately on permanent errors (400, 401, 404, 409).

=cut

use constant MAX_BACKOFF => 120;  # seconds

sub new {
    my ($class, $max_attempts, $initial_backoff) = @_;

    # Set defaults
    $max_attempts //= 5;
    $initial_backoff //= 0.5;

    # Validate inputs
    die "max_attempts must be positive integer" unless $max_attempts && $max_attempts > 0;
    die "initial_backoff must be positive number" unless $initial_backoff && $initial_backoff > 0;

    my $self = {
        max_attempts    => $max_attempts,
        initial_backoff => $initial_backoff,
    };

    return bless $self, $class;
}

=head2 execute($on_success_cb, $operation_cb)

Execute an operation with retry logic.

$on_success_cb receives the final result (success or error after all retries)
$operation_cb executes the operation and calls its callback with result hash

=cut

sub execute {
    my ($self, $on_success_cb, $operation_cb) = @_;

    require Slim::Utils::Timers;

    my $attempt = 0;

    my $run_operation;
    $run_operation = sub {
        $operation_cb->(sub {
            my $result = shift;

            # Success case: no error
            if (!$result->{error}) {
                $on_success_cb->($result);
                return;
            }

            # Error case: check if retryable
            if (!$self->is_retryable($result->{code}, $result->{error})) {
                # Non-retryable error, stop immediately
                $on_success_cb->($result);
                return;
            }

            # Retryable error: check if we can retry
            $attempt++;
            if ($attempt >= $self->{max_attempts}) {
                # Max attempts exhausted, give up
                $on_success_cb->($result);
                return;
            }

            # Calculate backoff and retry
            my $backoff = $self->_calculate_backoff($attempt - 1);
            Slim::Utils::Timers::setTimer(
                undef,
                $backoff,
                $run_operation
            );
        });
    };

    $run_operation->();
}

=head2 is_retryable($code, $error)

Determine if an error is retryable based on HTTP code and error message.

Returns true (retryable) for:
  - HTTP 429 (rate limit)
  - HTTP 502, 503, 504 (server errors)
  - HTTP 0 or "timeout" string (timeout)
  - Network errors: connection refused, connection reset, etc.

Returns false (NOT retryable) for:
  - HTTP 400, 401, 404, 409 (client errors)
  - GraphQL validation errors

=cut

sub is_retryable {
    my ($self, $code, $error) = @_;

    $code //= 0;
    $error //= '';

    # Check HTTP code first
    if ($code == 429 || $code == 502 || $code == 503 || $code == 504) {
        return 1;
    }

    # Non-retryable HTTP codes
    if ($code == 400 || $code == 401 || $code == 404 || $code == 409) {
        return 0;
    }

    # Check error message
    if ($error) {
        # Timeout is retryable
        if ($error =~ /timeout/i) {
            return 1;
        }

        # Network errors are retryable
        if ($error =~ /connection\s+(refused|reset|timeout)/i) {
            return 1;
        }

        # GraphQL validation errors are NOT retryable
        if ($error =~ /GraphQL\s+validation\s+error/i) {
            return 0;
        }
    }

    # Default: code 0 (timeout) is retryable
    if ($code == 0) {
        return 1;
    }

    # Default: unknown errors are not retryable
    return 0;
}

=head2 _calculate_backoff($attempt)

Calculate backoff delay with exponential growth and jitter.

Formula: initial_backoff * (2 ** attempt) * (0.75 + 0.5 * rand())
Cap at MAX_BACKOFF (120 seconds)

Attempt 0: ~0.5s
Attempt 1: ~1s
Attempt 2: ~2s
Attempt 3: ~4s
Attempt 4: ~8s

=cut

sub _calculate_backoff {
    my ($self, $attempt) = @_;

    $attempt //= 0;

    # Exponential backoff: 2^attempt
    my $exponential = 2 ** $attempt;
    my $base_backoff = $self->{initial_backoff} * $exponential;

    # Add jitter: ±25% (multiply by 0.75 to 1.25)
    my $jitter = 0.75 + (0.5 * rand());
    my $backoff = $base_backoff * $jitter;

    # Cap at MAX_BACKOFF
    if ($backoff > MAX_BACKOFF) {
        $backoff = MAX_BACKOFF;
    }

    return $backoff;
}

1;

__END__

=head1 LICENSE

This module is part of the LMS Zvuk Plugin and is licensed under the GPL v2.

=cut
