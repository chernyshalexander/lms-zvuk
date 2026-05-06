# Zvuk Plugin Logging Guide

## Problem
Zvuk plugin has detailed logging throughout the code, but LMS doesn't display it by default.

Error message: "Zvuk API error" but nothing in logs.

## Solution: Enable Plugin Logging

LMS needs to be configured to log messages from `plugin.zvuk` category.

### Method 1: Edit LMS Configuration (Recommended)

Create or edit: `~/.squeezebox/prefs/server.prefs`

Add these lines:
```
log4perl.logger.plugin.zvuk = DEBUG
log4perl.logger.plugin.zvuk.appender = LOGFILE
```

Or for maximum verbosity:
```
log4perl.logger.plugin.zvuk = DEBUG
log4perl.additivity.plugin.zvuk = 1
```

After editing, restart LMS:
```bash
sudo systemctl restart slimserver
```

### Method 2: Web UI Configuration (via LMS settings)

1. Open LMS Web UI: `http://localhost:9000`
2. Go to: Settings > Logging
3. Look for "plugin.zvuk" in the logger list
4. Set level to: **DEBUG**
5. Click: Apply and Restart

### Method 3: Command Line (Dynamic)

```bash
# Find LMS prefs directory
PREFS="${HOME}/.squeezebox/prefs"

# Backup existing
cp "$PREFS/server.prefs" "$PREFS/server.prefs.bak"

# Add plugin.zvuk logging
cat >> "$PREFS/server.prefs" << 'EOF'

# Zvuk Plugin Debugging
log4perl.logger.plugin.zvuk = DEBUG
EOF

# Restart
sudo systemctl restart slimserver
```

---

## What Gets Logged

### Plugin.pm - Browse & Search
- Plugin initialization
- Search requests
- Search results breakdown
- Browse menu navigation
- Account selection

### API/Async.pm - GraphQL Communication
- GraphQL operation names
- Request details (userId, cache status)
- Response status
- Parse errors with response content
- API errors with full details
- HTTP request failures

### ProtocolHandler.pm - Streaming
- Stream resolution for track IDs
- getStream responses
- FLAC availability and fallback
- Format selection (flac, high, mid)
- Stream URL assignment
- Metadata resolution

### API.pm - Token & Configuration
- Token validation
- Account data retrieval
- Image URL generation
- Cache metadata operations

### Settings.pm - Configuration
- Account addition/deletion
- Token validation
- Profile lookup

---

## Log Output Examples

### Successful Search
```
[plugin.zvuk] Searching Zvuk tracks for: jazz (offset: 0)
[plugin.zvuk] GraphQL Request: searchTracks (userId: 12345, cache: enabled)
[plugin.zvuk] GraphQL URL: https://zvuk.com/api/v1/graphql
[plugin.zvuk] GraphQL Token: 069fad8d...ac3b4
[plugin.zvuk] GraphQL success: searchTracks
[plugin.zvuk] Track search results: 342 total, 50 in this batch
```

### API Error
```
[plugin.zvuk] GraphQL Request: searchTracks (userId: 12345, cache: enabled)
[plugin.zvuk] GraphQL API errors for searchTracks: [{"message":"Invalid token"}]
[plugin.zvuk] Search API error: api_error
```

### HTTP Error
```
[plugin.zvuk] GraphQL Request: searchTracks (userId: 12345, cache: enabled)
[plugin.zvuk] GraphQL HTTP request failed for searchTracks: Connection timeout
```

### Token Issue
```
[plugin.zvuk] Token found for userId: 12345 (069fad8d...)
[plugin.zvuk] getStream response for track 123456: Got response
```

---

## Troubleshooting

### No Zvuk logs appearing at all

1. **Check logging is enabled:**
   ```bash
   grep "plugin.zvuk" ~/.squeezebox/prefs/server.prefs
   ```
   
   If nothing, add the lines from Method 1 above.

2. **Verify LMS restarted:**
   ```bash
   ps aux | grep slimserver
   ```
   
   Should show recent start time.

3. **Check log level:**
   By default, LMS may only log WARN and ERROR.
   Make sure you set DEBUG level.

4. **Check LMS prefs location:**
   ```bash
   # Different installs use different paths:
   ~/.squeezebox/prefs/server.prefs          # Docker/User install
   /var/lib/lms/prefs/server.prefs           # System install
   /opt/lms/prefs/server.prefs              # Alternative
   ```

### Logs show "plugin.zvuk" but no search results

This is the key symptom. Check for:

1. **API errors:**
   ```
   [plugin.zvuk] GraphQL API errors for searchTracks: [...]
   ```
   Check error message - token invalid? API changed?

2. **HTTP errors:**
   ```
   [plugin.zvuk] GraphQL HTTP request failed: ...
   ```
   Network issue, WAF blocking, or API down.

3. **Parse errors:**
   ```
   [plugin.zvuk] GraphQL: Failed to parse JSON response
   [plugin.zvuk] GraphQL: Response content (first 500 chars): ...
   ```
   API returned invalid JSON.

4. **Empty response:**
   ```
   [plugin.zvuk] GraphQL: Empty response content for searchTracks
   ```
   No data from server.

### "Zvuk API error" in Web UI but no details

This comes from the error callback in Plugin.pm:
```perl
if ($data->{error}) {
    $cb->([{ name => cstring($client, 'PLUGIN_ZVUK_ERROR_API'), type => 'text' }]);
    return;
}
```

The actual error details are ONLY in the logs.
Always check logs first when seeing UI errors.

---

## Log Levels

LMS supports these log levels:

- **FATAL** - System crash, recovery impossible
- **ERROR** - Serious problem, feature broken
- **WARN** - Potential problem, workaround attempted
- **INFO** - Notable event, operation successful ← **Use this**
- **DEBUG** - Detailed diagnostic, variable values ← **Use this for troubleshooting**
- **TRACE** - Very detailed, every line executed (rarely used)

For Zvuk plugin, use **DEBUG** level to see all details.

---

## Advanced: Custom Logging

To add more logging to the code:

```perl
# In any *.pm file:
use Slim::Utils::Log;
my $log = logger('plugin.zvuk');

# Then use:
$log->error("Something went wrong: $error");
$log->warn("Warning condition detected");
$log->info("Important event occurred");
$log->debug("Debug: variable = " . Data::Dumper::Dumper($var));
```

All messages will go to LMS logs with category `plugin.zvuk`.

---

## Finding the Log File

```bash
# Default locations:
tail -f ~/.squeezebox/cache/log/server.log     # Most common
tail -f /var/log/lms/server.log               # System install
tail -f /opt/lms/cache/log/server.log         # Alternative

# Search in log file:
grep -i zvuk ~/.squeezebox/cache/log/server.log

# Follow log in real-time:
tail -f ~/.squeezebox/cache/log/server.log | grep -i zvuk
```

---

## Performance Note

Enabling DEBUG logging has minimal performance impact:
- Only executed if logging is enabled
- String formatting is lazy (doesn't build strings if not logged)
- File I/O is buffered

Safe to leave enabled for debugging.

---

## Next Steps After Logging Works

Once you can see logs:

1. **Search test:**
   ```
   Navigate to: Zvuk > Search > Tracks > "jazz"
   ```
   Check logs for API response and error details.

2. **Stream test:**
   ```
   Play any track
   ```
   Check logs for getStream response and URL resolution.

3. **Add debug statements:**
   If logs still don't explain the issue, add more detailed logging to specific functions.

4. **Collect logs for support:**
   ```bash
   grep "plugin.zvuk" ~/.squeezebox/cache/log/server.log > zvuk_debug.log
   # Share zvuk_debug.log when reporting issues
   ```
