#!/bin/sh
# Builds a Release version of NaviSync for macOS and installs it into /Applications,
# so it shows up in Spotlight and Launchpad. Re-run after every git pull to update.
set -eu

cd "$(dirname "$0")/.."

if [ ! -f Config/Local.xcconfig ]; then
    echo "Config/Local.xcconfig is missing, see README (Building, step 1)." >&2
    exit 1
fi

rm -rf build/Release/NaviSync.app

xcodebuild \
    -project NaviSync.xcodeproj \
    -target NaviSync \
    -configuration Release \
    -sdk macosx \
    -allowProvisioningUpdates \
    SYMROOT="$PWD/build" \
    build | grep -E "error|warning: .*NaviSync|BUILD" || true

APP="build/Release/NaviSync.app"
if [ ! -d "$APP" ]; then
    echo "Build failed, run without the filter for details:" >&2
    echo "  xcodebuild -project NaviSync.xcodeproj -target NaviSync -configuration Release -sdk macosx -allowProvisioningUpdates SYMROOT=\$PWD/build" >&2
    exit 1
fi

# Quit a running copy so it can be replaced.
if pgrep -xq NaviSync; then
    osascript -e 'tell application id "io.backl.navisync" to quit' || true
    sleep 2
fi

rm -rf /Applications/NaviSync.app
ditto "$APP" /Applications/NaviSync.app
echo "Installed /Applications/NaviSync.app"
open /Applications/NaviSync.app
