#!/bin/sh
# Stops and removes the magent-overlay LaunchAgent. Stopping it also kills a running agent.
set -eu

LABEL=com.magent.overlay
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/Library/Application Support/Magent/magent-overlay"
echo "Removed $LABEL. Logs are left in ~/Library/Logs/Magent."
