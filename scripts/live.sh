#!/bin/sh
# Shows the current/last automatic build live. Ctrl+C to stop.
LOG="$HOME/Library/Caches/NaviSync-Build/logs/deploy.log"
touch "$LOG"
exec tail -n 30 -F "$LOG"
