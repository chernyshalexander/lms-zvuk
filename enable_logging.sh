#!/bin/bash
# Enable Zvuk plugin debug logging in LMS

set -e

# Find LMS prefs directory
PREFS_DIR=""
if [ -d "$HOME/.squeezebox/prefs" ]; then
    PREFS_DIR="$HOME/.squeezebox/prefs"
elif [ -d "/var/lib/lms/prefs" ]; then
    PREFS_DIR="/var/lib/lms/prefs"
elif [ -d "/opt/lms/prefs" ]; then
    PREFS_DIR="/opt/lms/prefs"
else
    echo "Error: Could not find LMS prefs directory"
    echo "Checked:"
    echo "  - $HOME/.squeezebox/prefs"
    echo "  - /var/lib/lms/prefs"
    echo "  - /opt/lms/prefs"
    exit 1
fi

PREFS_FILE="$PREFS_DIR/server.prefs"

if [ ! -f "$PREFS_FILE" ]; then
    echo "Error: $PREFS_FILE not found"
    exit 1
fi

echo "Found LMS prefs: $PREFS_FILE"
echo ""

# Backup existing file
BACKUP="$PREFS_FILE.backup.$(date +%s)"
cp "$PREFS_FILE" "$BACKUP"
echo "Created backup: $BACKUP"
echo ""

# Check if already enabled
if grep -q "log4perl.logger.plugin.zvuk" "$PREFS_FILE"; then
    echo "Zvuk logging already enabled"
    echo ""
    grep "log4perl.logger.plugin.zvuk" "$PREFS_FILE"
    echo ""
    echo "To re-enable logging, restart LMS:"
    echo "  sudo systemctl restart slimserver"
    exit 0
fi

# Add logging configuration
echo "" >> "$PREFS_FILE"
echo "# Zvuk Plugin Logging (added $(date))" >> "$PREFS_FILE"
echo "log4perl.logger.plugin.zvuk = DEBUG" >> "$PREFS_FILE"
echo "" >> "$PREFS_FILE"

echo "Zvuk debug logging enabled in:"
echo "  $PREFS_FILE"
echo ""
echo "Configuration added:"
grep "log4perl.logger.plugin.zvuk" "$PREFS_FILE"
echo ""

# Restart LMS
echo "Restarting LMS..."
if command -v systemctl &> /dev/null; then
    sudo systemctl restart slimserver
    echo "LMS restarted via systemctl"
elif command -v service &> /dev/null; then
    sudo service slimserver restart
    echo "LMS restarted via service"
else
    echo "Could not find systemctl or service command"
    echo "Please restart LMS manually:"
    echo "  sudo systemctl restart slimserver"
fi

echo ""
echo "Done! Debug logging is now enabled."
echo ""
echo "View logs:"
echo "  tail -f ~/.squeezebox/cache/log/server.log | grep -i zvuk"
echo ""
echo "Or without filtering:"
echo "  tail -f ~/.squeezebox/cache/log/server.log"
