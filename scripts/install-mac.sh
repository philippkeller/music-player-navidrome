#!/bin/sh
# Builds NaviSync for macOS, installs it into /Applications (so Spotlight finds it)
# and launches it. Quits a running copy first.
set -eu

if pgrep -xq NaviSync; then
    osascript -e 'tell application id "io.backl.navisync" to quit' || true
    sleep 2
fi
OPEN_MAC_APP=1 exec "$(dirname "$0")/deploy.sh" mac
