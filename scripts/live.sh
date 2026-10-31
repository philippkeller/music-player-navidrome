#!/bin/sh
# Shows the automatic builds of all apps live. Ctrl+C to stop.
LOG="$HOME/Library/Caches/AutoDeploy/live.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec tail -n 30 -F "$LOG"
