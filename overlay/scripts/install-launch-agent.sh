#!/bin/sh
# Installs magent-overlay as a per-user LaunchAgent: it starts at login, launchd restarts it
# if it dies, and ⌃⌥⌘Space is always available. Each prompt-bar request starts <agent>.
#
#   scripts/install-launch-agent.sh [--print] /path/to/agent
#
# --print writes the plist to stdout and installs nothing.
#
# Run this in the separate Standard dev account, not your primary one (see CLAUDE.md).
# It refuses to install for an admin user unless MAGENT_ALLOW_ADMIN=1.
set -eu

LABEL=com.magent.overlay
PRINT=0
if [ "${1:-}" = "--print" ]; then PRINT=1; shift; fi
[ $# -eq 1 ] || { echo "usage: $0 [--print] /path/to/agent" >&2; exit 2; }
[ -f "$1" ] && [ -x "$1" ] || { echo "$1 is not an executable file" >&2; exit 1; }
AGENT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")

if [ $PRINT -eq 0 ] && id -Gn | tr ' ' '\n' | grep -qx admin && [ "${MAGENT_ALLOW_ADMIN:-0}" != 1 ]; then
    echo "$(id -un) is an admin account. Install this in the Standard dev account instead," >&2
    echo "or set MAGENT_ALLOW_ADMIN=1 if you really mean to." >&2
    exit 1
fi

# Copy the binary to a fixed location so the plist (and the Accessibility / Screen Recording
# grants, which the agent inherits from the overlay) don't point into .build.
SUPPORT="$HOME/Library/Application Support/Magent"
BIN="$SUPPORT/magent-overlay"
LOGS="$HOME/Library/Logs/Magent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

TMP=$(mktemp -t magent-plist)
trap 'rm -f "$TMP"' EXIT
rm -f "$TMP"
plutil -create xml1 "$TMP"
plutil -insert Label -string "$LABEL" "$TMP"
plutil -insert ProgramArguments -array "$TMP"
plutil -insert ProgramArguments -string "$BIN" -append "$TMP"
plutil -insert ProgramArguments -string --daemon -append "$TMP"
plutil -insert ProgramArguments -string "$AGENT" -append "$TMP"
plutil -insert RunAtLoad -bool YES "$TMP"
plutil -insert KeepAlive -bool YES "$TMP"
# Only in the logged-in GUI session: the overlay needs windows and hotkeys.
plutil -insert LimitLoadToSessionType -string Aqua "$TMP"
# Interactive: launchd doesn't throttle its CPU or I/O like a background job.
plutil -insert ProcessType -string Interactive "$TMP"
plutil -insert StandardOutPath -string "$LOGS/overlay.log" "$TMP"
plutil -insert StandardErrorPath -string "$LOGS/overlay.log" "$TMP"
plutil -lint -s "$TMP"

if [ $PRINT -eq 1 ]; then cat "$TMP"; exit 0; fi

cd "$(dirname "$0")/.."
swift build -c release
mkdir -p "$SUPPORT" "$LOGS" "$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
# Stop the running copy before replacing its binary.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
cp "$(swift build -c release --show-bin-path)/magent-overlay" "$BIN"
cp "$TMP" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed $LABEL. ⌃⌥⌘Space opens the prompt bar. Log: $LOGS/overlay.log"
echo "Re-run this script after rebuilding; scripts/uninstall-launch-agent.sh removes it."
