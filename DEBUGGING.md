# Zvuk Plugin Debugging Guide

## Current Issues
- ❌ Search returns "Zvuk API error" without details
- ❌ Nothing plays (stream errors)
- ❌ No logging visible

## Root Cause
LMS doesn't log plugin messages by default - need to enable debug logging.

---

## ⚡ Quick Fix (5 minutes)

### Step 1: Enable Logging

```bash
cd /home/chernysh/Projects/lms-zvuk
./enable_logging.sh
```

This script will:
1. Find your LMS installation
2. Add debug logging configuration
3. Backup existing settings
4. Restart LMS automatically

### Step 2: Reproduce the Error

In LMS Web UI:
1. Go to: **Zvuk Music > Search > Tracks**
2. Type: **"jazz"**
3. Press Enter

### Step 3: Check Logs

```bash
tail -100 ~/.squeezebox/cache/log/server.log | grep -i zvuk
```

You should now see detailed error messages explaining what's wrong.

---

## 📋 What to Look For

### If you see: `GraphQL API errors`
Example:
```
[plugin.zvuk] GraphQL API errors for searchTracks: [{"message":"Invalid token"}]
```

**Meaning:** Your token is invalid or expired
- **Fix:** Go to Zvuk settings, delete account, add token again

### If you see: `GraphQL HTTP request failed`
Example:
```
[plugin.zvuk] GraphQL HTTP request failed: Connection timeout
```

**Meaning:** Network issue or API is unreachable
- **Fix:** Check internet connection, Zvuk API might be down

### If you see: `Empty response content`
Example:
```
[plugin.zvuk] GraphQL: Empty response content for searchTracks
```

**Meaning:** API returned nothing
- **Fix:** Check token is valid, API might be blocking your region

### If you see: `No data in response`
Example:
```
[plugin.zvuk] GraphQL: No data in response for searchTracks
```

**Meaning:** Response has unexpected structure
- **Fix:** API might have changed, check logs for full response

### If you see: `Failed to parse JSON`
Example:
```
[plugin.zvuk] GraphQL: Failed to parse JSON response
[plugin.zvuk] GraphQL: Response content (first 500 chars): <!DOCTYPE html>...
```

**Meaning:** API returned HTML error instead of JSON (WAF block, maintenance, etc.)
- **Fix:** Check if Zvuk is up, check if IP is blocked, try VPN

---

## 🔍 Complete Logging Output Example

### Successful Search

```bash
$ tail -f ~/.squeezebox/cache/log/server.log | grep zvuk
```

Output:
```
[plugin.zvuk] Initializing Zvuk plugin...
[plugin.zvuk] Searching Zvuk tracks for: jazz (offset: 0)
[plugin.zvuk] GraphQL Request: searchTracks (userId: 12345, cache: enabled)
[plugin.zvuk] GraphQL URL: https://zvuk.com/api/v1/graphql
[plugin.zvuk] GraphQL Token: 069fad8d...c3b4
[plugin.zvuk] GraphQL success: searchTracks
[plugin.zvuk] Track search results: 342 total, 50 in this batch
```

### Failed Search

```
[plugin.zvuk] Searching Zvuk tracks for: jazz (offset: 0)
[plugin.zvuk] GraphQL Request: searchTracks (userId: 12345, cache: enabled)
[plugin.zvuk] GraphQL error: [{"message":"Authentication failed"}]
[plugin.zvuk] Search API error: api_error
```

---

## 🛠️ Manual Logging Setup (if script doesn't work)

### Find your LMS prefs file:

```bash
# Most common (Docker, user install):
ls -la ~/.squeezebox/prefs/server.prefs

# System install:
ls -la /var/lib/lms/prefs/server.prefs

# Alternative:
ls -la /opt/lms/prefs/server.prefs
```

### Edit the file:

```bash
# Backup first:
cp ~/.squeezebox/prefs/server.prefs ~/.squeezebox/prefs/server.prefs.bak

# Add at end of file:
echo "
# Zvuk Plugin Debug Logging
log4perl.logger.plugin.zvuk = DEBUG
" >> ~/.squeezebox/prefs/server.prefs
```

### Restart LMS:

```bash
sudo systemctl restart slimserver
# or
sudo service slimserver restart
```

---

## 🚨 Common Problems & Solutions

### "Can't find ~/.squeezebox"

LMS might be installed elsewhere:
```bash
# Find where LMS stores its files:
find / -name "server.prefs" 2>/dev/null
```

Use that directory path instead.

### "Permission denied" when running script

Make executable:
```bash
chmod +x /home/chernysh/Projects/lms-zvuk/enable_logging.sh
```

### LMS won't restart

Try manually:
```bash
sudo systemctl status slimserver   # Check status
sudo systemctl stop slimserver     # Stop
sleep 2
sudo systemctl start slimserver    # Start

# Check if it started:
ps aux | grep slimserver
```

### Still no logs after restart

Check that logging was added:
```bash
grep "plugin.zvuk" ~/.squeezebox/prefs/server.prefs
```

If nothing shows, add it manually (see above).

---

## 📊 Detailed Logging Coverage

Each module now logs:

**Plugin.pm** (Browse & Search)
- Search requests: `$log->info("Searching Zvuk for: $query")`
- Search results: `$log->info("Track search results: $total total, $count in batch")`
- Error details: `$log->warn("Track search error: $error")`

**API/Async.pm** (GraphQL)
- Request info: `$log->info("GraphQL Request: $operation")`
- Token info: `$log->debug("GraphQL Token: 069fad8d...")`
- Success: `$log->info("GraphQL success: $operation")`
- API errors: `$log->error("GraphQL API errors: ...")`
- HTTP errors: `$log->error("GraphQL HTTP request failed: ...")`

**ProtocolHandler.pm** (Streaming)
- Stream request: `$log->info("Resolving Zvuk stream for track ID: $id")`
- Response: `$log->debug("getStream response for track $id")`
- Format selected: `$log->info("Resolved stream for track $id (quality: $quality, format: $format)")`

**API.pm** (Token & Config)
- Token lookup: `$log->debug("Token found for userId: $userId")`
- Missing token: `$log->error("No token found for userId: $userId")`

**Settings.pm** (Configuration)
- Account added: `$log->info("Account added: userId=$userId")`
- Account deleted: `$log->info("Deleted account userId=$userId")`

---

## 📝 Collect Logs for Support

When reporting issues, include logs:

```bash
# Save all Zvuk logs to a file:
grep "plugin.zvuk" ~/.squeezebox/cache/log/server.log > zvuk_debug.log

# Also include full context (with timestamps):
grep -B 2 -A 2 "plugin.zvuk" ~/.squeezebox/cache/log/server.log > zvuk_debug_full.log

# Get last 1000 lines of Zvuk logs:
grep "plugin.zvuk" ~/.squeezebox/cache/log/server.log | tail -1000 > zvuk_recent.log
```

Include `zvuk_debug.log` when reporting issues.

---

## 🎯 Next Steps

1. **Run enable_logging.sh** ← Do this first
2. **Try search again** and check logs
3. **Post the error logs** when asking for help
4. **Reference docs/LOGGING.md** for more details

---

## Detailed Documentation

See `docs/LOGGING.md` for:
- Complete logging setup guide (3 methods)
- Log level explanations
- Advanced configuration
- Performance notes
- Custom logging for developers
