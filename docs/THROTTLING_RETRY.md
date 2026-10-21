# Throttling & Retry Logic

## Overview

The Zvuk plugin implements sophisticated **rate limiting** and **retry logic** to ensure stable, efficient API communication with the Zvuk music service.

### Rate Limiting (Throttling)

**What it is:** A mechanism that limits API requests to a maximum of **5 per second**.

**Why it matters:**
- Respects the API's rate limits and prevents `429 Too Many Requests` errors
- Ensures fair resource usage across all plugin instances
- Automatically queues excess requests instead of rejecting them

### Automatic Retry Logic

**What it is:** A system that automatically retries failed requests up to **5 attempts** with **exponential backoff**.

**Why it matters:**
- Handles transient API failures (timeouts, temporary server errors) gracefully
- Improves user experience by retrying recoverable errors without user intervention
- Prevents cascading failures by backing off between attempts

---

## Features

### Rate Limiting: 5 Requests Per Second

The throttle module enforces a token-bucket algorithm:

- **Capacity:** 5 request slots per second
- **Enforcement:** Requests exceeding the limit are queued and executed when a slot becomes available
- **Memory footprint:** Only 5 timestamps tracked in memory (negligible)

**Example timeline:**
```
Time 0.0s   → Requests 1-5 execute immediately
Time 0.2s   → Request 6 queued, executes at time 1.0s (slot freed)
Time 0.4s   → Request 7 queued, executes at time 1.2s
Time 0.6s   → Request 8 queued, executes at time 1.4s
```

### Backoff Sequence: Exponential with Jitter

When a request fails with a retryable error, the retry manager applies exponential backoff with ±25% jitter:

**Attempt backoff delays (typical values):**
- Attempt 1: ~0.5s (base delay)
- Attempt 2: ~1.0s (doubled)
- Attempt 3: ~2.0s (doubled)
- Attempt 4: ~4.0s (doubled)
- Attempt 5: ~8.0s (doubled)
- Maximum: 120 seconds per attempt

**Why jitter?** Randomization (±25%) prevents "thundering herd" problems where multiple clients retry simultaneously.

### Retryable Errors

The system automatically retries these errors:

- **HTTP 429** — Rate limited (too many requests)
- **HTTP 502** — Bad gateway
- **HTTP 503** — Service unavailable
- **HTTP 504** — Gateway timeout
- **Timeout (HTTP 0)** — Request took too long
- **Network errors** — Connection refused, connection reset, etc.

### Non-Retryable Errors

These errors are NOT retried (permanent failures):

- **HTTP 400** — Bad request (malformed query)
- **HTTP 401** — Unauthorized (invalid token)
- **HTTP 404** — Not found
- **HTTP 409** — Conflict
- **GraphQL validation errors** — Schema or query validation failed

---

## Configuration

### Current Settings (Hardcoded)

All settings are currently hardcoded in `/API/Async.pm`:

```perl
# Rate limiting: 5 requests per second
my $throttler = Throttle->new(5, 1.0);  # rate_limit=5, period=1.0s

# Retry: 5 attempts with 0.5s initial backoff
my $retry_mgr = Retry->new(5, 0.5);     # max_attempts=5, initial_backoff=0.5s
```

### Parameter Meanings

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `rate_limit` | 5 | Maximum requests per time period |
| `period` | 1.0s | Time period for rate limit window |
| `max_attempts` | 5 | Maximum retry attempts per request |
| `initial_backoff` | 0.5s | Base delay before first retry |
| `max_backoff` | 120s | Maximum delay cap per attempt |

### Future Configurability

These settings can be made user-configurable via plugin preferences in a future enhancement. The infrastructure is already in place to support this.

---

## Logging

### Enabling DEBUG Logging

To see detailed throttle and retry logs, enable DEBUG level logging for the Zvuk plugin:

**Via LMS Web UI:**
1. Settings → Advanced → Logging
2. Find "plugin.zvuk" in the list
3. Set level to "DEBUG"

**Or directly in `server.log` config:**
```
log.priorities=plugin.zvuk:DEBUG
```

### What to Look For

When debugging, watch for these log messages:

**Throttle delays:**
```
[plugin.zvuk] GraphQL: throttled for 0.523s
```
Indicates request was queued and delayed by 0.523 seconds.

**Rate limit errors:**
```
[plugin.zvuk] GraphQL: Rate limited (429) for search
```
Indicates API returned HTTP 429. Will retry automatically.

**Retry attempts:**
```
[plugin.zvuk] GraphQL: Request timeout for getStream
[plugin.zvuk] GraphQL: Service unavailable (503) for search
```
Indicates a transient error. Will retry with backoff.

**Cache hits:**
```
[plugin.zvuk] Cache hit for search (userId123)
```
Indicates request was served from cache (bypasses throttle/retry).

**Permanent errors (no retry):**
```
[plugin.zvuk] GraphQL error (search): Invalid token
```
HTTP 401 - will NOT retry. User action required (re-authenticate).

### Example Log Output

A typical sequence showing throttle → retry → success:

```
[2026-06-19 12:34:56] [plugin.zvuk] GraphQL Request: search (userId: user123, cache: off)
[2026-06-19 12:34:56] [plugin.zvuk] GraphQL: throttled for 0.087s
[2026-06-19 12:34:56] [plugin.zvuk] GraphQL: Service unavailable (503) for search
[2026-06-19 12:34:57] [plugin.zvuk] GraphQL Request: search (userId: user123, cache: off)  [RETRY]
[2026-06-19 12:34:57] [plugin.zvuk] GraphQL API error (search, HTTP 503): Service temporarily unavailable
[2026-06-19 12:34:58] [plugin.zvuk] GraphQL Request: search (userId: user123, cache: off)  [RETRY 2]
[2026-06-19 12:34:59] [plugin.zvuk] GraphQL API success: 42 tracks returned
```

---

## Performance Impact

### Throttle Overhead

**Request delay:**
- At normal load: ~0ms (requests execute immediately)
- At maximum load (5 req/sec): ~0-200ms per request
- Worst case: New request at start of period waits ~1000ms for oldest request to expire

**Why minimal?** The throttle uses a simple list of 5 timestamps and O(1) comparisons.

**Memory:** Negligible (~200 bytes for 5 timestamps)

**CPU:** Negligible (no crypto, no expensive operations)

### Retry Overhead

**Transparent to user:**
- First attempt fails? Retry automatically in background
- No UI blocking (all operations are async)
- Failed requests don't slow down other requests

**Worst case scenario:** 5 failed attempts = ~15 seconds total (0.5 + 1 + 2 + 4 + 8)
- User sees "Loading..." spinner, not frozen UI
- Plugin continues processing other requests

---

## Monitoring

### What to Watch For

#### High Frequency of 429 (Rate Limit) Errors

**Pattern to detect:**
```
GraphQL: Rate limited (429) for [operation] (appears frequently in logs)
```

**What it means:**
- Another client is making requests from the same IP
- API rate limit is stricter than expected
- Plugin is approaching rate limit threshold

**Action to take:**
- Review other active API clients
- Consider reducing parallel request load
- Contact API support if limit is unexpectedly strict

#### Timeout Errors

**Pattern to detect:**
```
GraphQL: Request timeout for [operation] (appears multiple times)
```

**What it means:**
- Network latency is high
- API server is slow to respond
- User's internet connection may be unstable

**Action to take:**
- Check network connectivity
- Verify API service status
- Monitor timeout frequency over time

#### 5xx Server Errors (502, 503, 504)

**Pattern to detect:**
```
GraphQL: Bad gateway (502) for [operation]
GraphQL: Service unavailable (503) for [operation]
GraphQL: Gateway timeout (504) for [operation]
```

**What it means:**
- API server has internal issues
- Load balancer or proxy is having problems
- Expected to be temporary (should auto-retry)

**Action to take:**
- Check API service status page
- Wait for auto-retry (plugin handles automatically)
- Contact API support if persists longer than 5 minutes

#### Connection Errors

**Pattern to detect:**
```
GraphQL: Network error for [operation]: connection refused
GraphQL: Network error for [operation]: connection reset
```

**What it means:**
- Network is unreachable
- Firewall blocking traffic
- DNS resolution failing

**Action to take:**
- Verify network connectivity
- Check firewall rules
- Test DNS resolution to `zvuk.com`

### Detecting Systematic Problems

**Red flags (investigate these):**

1. **Repeated 401 errors** → Token expired, user needs to re-authenticate
2. **All requests timing out** → Network or DNS issue
3. **Rate limit (429) on single operation** → Check for multiple plugin instances
4. **GraphQL validation errors** → Plugin bug or API schema change

---

## Architecture Notes

### Modules

The throttle & retry system consists of three modules:

#### `Throttle.pm`

**Purpose:** Enforce rate limiting (5 requests per second)

**Key method:**
```perl
$throttler->acquire($callback)
```
Acquires a rate limit slot, calling the callback with delay time.

**Algorithm:** Token bucket using timestamps

**Responsibilities:**
- Track recent request timestamps
- Enforce 5 req/sec limit
- Schedule delayed execution when full

#### `Retry.pm`

**Purpose:** Automatic retry with exponential backoff

**Key method:**
```perl
$retry_mgr->execute($on_success_cb, $operation_cb)
```
Executes operation with automatic retry on transient failures.

**Algorithm:** Exponential backoff with jitter

**Responsibilities:**
- Detect retryable vs. permanent errors
- Calculate backoff delays
- Schedule retry attempts
- Cap at 5 attempts

#### `API/Async.pm` Integration

**Purpose:** GraphQL request handler with integrated throttle & retry

**Key method:**
```perl
$self->_graphql($cb, $operationName, $query, $variables, $opts)
```

**Flow:**
```
1. Check cache (bypass throttle/retry if hit)
2. Throttle: acquire() - wait for rate limit slot
3. Retry: execute() - run HTTP request with auto-retry
4. Cache: write result if cacheable
5. Callback: return to caller
```

**Throttle integration:**
```perl
$throttler->acquire(sub {
    my $throttle_delay = shift;
    # ... retry logic here ...
});
```

**Retry integration:**
```perl
$retry_mgr->execute(
    sub { ... },  # on_success callback
    sub { ... }   # operation callback
);
```

### Design Decisions

#### Why Token Bucket for Throttling?

**Alternative:** Fixed window (reset at start of each second)
- Problem: Causes burst at window boundary
- Token bucket spreads requests evenly

**Alternative:** Sliding window counter
- Problem: More complex, higher memory overhead
- Token bucket is simpler and sufficient

#### Why Exponential Backoff with Jitter?

**Alternative:** Linear backoff (0.5s, 1s, 1.5s, 2s, 2.5s)
- Problem: Predictable retry timing causes thundering herd

**Alternative:** Fixed jitter (0.5s + rand(0.5s))
- Problem: Can still cluster at peak delay time

**Chosen:** Exponential with ±25% jitter gives:
- Unpredictable retry timing
- Reasonable falloff to prevent cascading retries
- Capped at 120s to prevent excessive waiting

#### Why Cache Bypass on Throttle/Retry?

**Feature:** Cache hits bypass throttle and retry entirely

**Rationale:**
- Cached data is instant, no network delay
- No point throttling when nothing is sent
- Improves perceived responsiveness for repeat requests

#### Why Separate Modules?

**Instead of:** Monolithic request handler

**Benefits:**
- Easier to test in isolation
- Reusable for other API clients
- Clear separation of concerns
- Follows Unix philosophy (do one thing well)

---

## Troubleshooting

### Plugin Requests Are Very Slow

**Diagnosis:**
1. Enable DEBUG logging
2. Look for `GraphQL: throttled for X.XXs` messages
3. If frequent, user is hitting rate limit

**Solutions:**
- Wait for backoff timer to expire
- Check for multiple plugin instances
- Verify single user is using single LMS server

### User Gets "Connection Failed" After Retries

**What happened:**
- Plugin tried 5 times, all failed
- Final error returned to user

**Causes (in order of likelihood):**
1. **Network issue** — User's internet is down
2. **Token expired** — User needs to re-authenticate (see 401 error)
3. **API down** — Check `zvuk.com` status page

**User action:**
1. Check network connectivity
2. Try refreshing (re-authenticate if needed)
3. Wait 5 minutes if API is down, then retry

### Requests Succeed But Are Slow

**Likely cause:** Legitimate rate limiting (plugin respects 5 req/sec limit)

**Check:**
1. How many search results are you requesting?
2. Multiple operations running in parallel?
3. Multiple plugin instances on same IP?

**Solutions:**
- Reduce parallel requests
- Use pagination (request less data per query)
- Wait for plugin to finish current operation

---

## API Reference

### Throttle.pm

```perl
use Throttle;

my $throttle = Throttle->new(5, 1.0);  # 5 requests per 1 second

$throttle->acquire(sub {
    my $delay = shift;  # Delay in seconds (0 if immediate)
    # Make your request here
});
```

### Retry.pm

```perl
use Retry;

my $retry = Retry->new(5, 0.5);  # 5 attempts, 0.5s base backoff

$retry->execute(
    # Success callback - receives final result
    sub {
        my $result = shift;
        if ($result->{error}) {
            # Retries exhausted or non-retryable error
        } else {
            # Success!
        }
    },
    # Operation callback - executes the actual operation
    sub {
        my $cb = shift;
        # Make request, then call $cb->($result_hash)
        $cb->({ data => $response_data });  # or
        $cb->({ error => 'msg', code => 503 });  # if failed
    }
);
```

### Retry.pm Error Classification

```perl
$retry->is_retryable($http_code, $error_message)
    # Returns true (will retry) for:
    # 429, 502, 503, 504, timeout, network errors
    # Returns false (won't retry) for:
    # 400, 401, 404, 409, GraphQL validation errors
```

---

## Summary

The throttle & retry system provides:

✅ **Reliable** — Automatic retry masks transient failures  
✅ **Respectful** — Enforces API rate limits without user intervention  
✅ **Responsive** — Cache hits bypass throttle/retry entirely  
✅ **Debuggable** — Comprehensive logging at DEBUG level  
✅ **Efficient** — Minimal CPU, memory, and latency overhead  
✅ **Resilient** — Handles 429, 5xx, timeout, and network errors gracefully  

For questions or issues, check the logs at DEBUG level or contact plugin support.
