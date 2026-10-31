#!/bin/bash
# Builds NaviSync and installs it on the iPhone (over Wi-Fi or cable) and/or into
# /Applications on this Mac. Used by the GitHub Actions runner on every push, and
# can be run by hand:
#
#   scripts/deploy.sh          # iPhone + Mac
#   scripts/deploy.sh ios      # iPhone only
#   scripts/deploy.sh mac      # Mac only
#
# Signing: uses Config/Local.xcconfig, or the DEVELOPMENT_TEAM environment variable.
# Device: the first paired iPhone, or the one named in IPHONE_NAME / IPHONE_ID.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGETS="${1:-all}"
# Outside the repo so `git clean` (done by the runner's checkout) keeps it: incremental builds.
BUILD_ROOT="${NAVISYNC_BUILD_ROOT:-$HOME/Library/Caches/NaviSync-Build}"
LOG_DIR="$BUILD_ROOT/logs"
mkdir -p "$LOG_DIR"

SETTINGS=()
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    SETTINGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
elif [ ! -f Config/Local.xcconfig ]; then
    echo "error: no signing team. Create Config/Local.xcconfig (see README) or set DEVELOPMENT_TEAM." >&2
    exit 1
fi

# build <sdk> → prints the path of the built app
build() {
    local sdk="$1"
    local log="$LOG_DIR/build-$sdk.log"
    echo "==> Building for $sdk" >&2
    if ! xcodebuild \
        -project NaviSync.xcodeproj \
        -target NaviSync \
        -configuration Release \
        -sdk "$sdk" \
        -allowProvisioningUpdates \
        SYMROOT="$BUILD_ROOT/Products" \
        OBJROOT="$BUILD_ROOT/Intermediates" \
        "${SETTINGS[@]+"${SETTINGS[@]}"}" \
        build >"$log" 2>&1
    then
        echo "==> Build for $sdk FAILED. Errors:" >&2
        grep -E "error:|fatal error|Code ?Sign|provisioning" "$log" | sort -u >&2 || true
        echo "--- last lines of $log ---" >&2
        tail -n 40 "$log" >&2
        exit 1
    fi
    grep -E "warning:.*NaviSync/" "$log" | sort -u >&2 || true
    if [ "$sdk" = macosx ]; then
        echo "$BUILD_ROOT/Products/Release/NaviSync.app"
    else
        echo "$BUILD_ROOT/Products/Release-$sdk/NaviSync.app"
    fi
}

find_iphone() {
    if [ -n "${IPHONE_ID:-}" ]; then echo "$IPHONE_ID"; return; fi
    local json
    json="$(mktemp)"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
    /usr/bin/python3 - "$json" "${IPHONE_NAME:-}" <<'EOF'
import json, sys
path, wanted = sys.argv[1], sys.argv[2]
try:
    devices = json.load(open(path))["result"]["devices"]
except Exception:
    sys.exit(0)
def ok(d):
    hw, props = d.get("hardwareProperties", {}), d.get("deviceProperties", {})
    conn = d.get("connectionProperties", {})
    return (hw.get("platform") == "iOS" and hw.get("deviceType") == "iPhone"
            and conn.get("pairingState") == "paired"
            and (not wanted or props.get("name") == wanted))
candidates = [d for d in devices if ok(d)]
# Prefer one that is reachable right now.
candidates.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
if candidates:
    print(candidates[0]["identifier"])
EOF
    rm -f "$json"
}

deploy_ios() {
    local app device
    app="$(build iphoneos)" || exit 1
    device="$(find_iphone)"
    if [ -z "$device" ]; then
        echo "error: no paired iPhone found. Connect it once by cable and open Xcode → Window → Devices and Simulators." >&2
        exit 1
    fi
    echo "==> Installing on iPhone $device"
    # Retries: the Wi-Fi connection to the phone sometimes needs a moment to come up.
    for attempt in 1 2 3; do
        if xcrun devicectl device install app --device "$device" "$app"; then
            echo "==> Installed on iPhone"
            return
        fi
        echo "Install attempt $attempt failed (is the iPhone unlocked and on the same Wi-Fi?), retrying…" >&2
        sleep 10
    done
    echo "error: could not install on the iPhone" >&2
    exit 1
}

deploy_mac() {
    local app
    app="$(build macosx)" || exit 1
    # Swap the bundle in place instead of quitting the app, so a push doesn't stop the music.
    # A running copy keeps going; the next launch is the new version.
    rm -rf /Applications/NaviSync.app.new
    ditto "$app" /Applications/NaviSync.app.new || exit 1
    rm -rf /Applications/NaviSync.app
    mv /Applications/NaviSync.app.new /Applications/NaviSync.app || exit 1
    echo "==> Installed /Applications/NaviSync.app"
    if [ "${OPEN_MAC_APP:-0}" = 1 ]; then
        open /Applications/NaviSync.app
    elif pgrep -xq NaviSync; then
        echo "    NaviSync is running; quit and reopen it to use the new version."
    fi
}

case "$TARGETS" in
    ios) deploy_ios ;;
    mac) deploy_mac ;;
    all)
        # `set -e` is off inside `( … ) ||`, hence the explicit `|| exit 1` in the functions.
        # Each in a subshell, so an unreachable iPhone doesn't stop the Mac update (and vice versa).
        status=0
        ( deploy_ios ) || status=1
        ( deploy_mac ) || status=1
        exit $status
        ;;
    *) echo "usage: $0 [ios|mac|all]" >&2; exit 2 ;;
esac
