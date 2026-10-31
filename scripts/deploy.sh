#!/bin/bash
# Builds the app and installs it on the iPhone (over Wi-Fi or cable) and, if the app
# supports macOS, into /Applications. Used by the GitHub Actions runner on every push,
# and can be run by hand:
#
#   scripts/deploy.sh          # everything
#   scripts/deploy.sh ios      # iPhone only
#   scripts/deploy.sh mac      # Mac only
#
# Signing: the team in the project, Config/Local.xcconfig, or the DEVELOPMENT_TEAM env var.
# Device: the first paired iPhone, or the one named in IPHONE_NAME / IPHONE_ID.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="$(find . -maxdepth 2 -name '*.xcodeproj' | sort | head -n1)"
APP="$(basename "$PROJECT" .xcodeproj)"   # the target has the project's name
TARGETS="${1:-all}"
# Outside the repo so `git clean` (done by the runner's checkout) keeps it: incremental builds.
CACHE="$HOME/Library/Caches/AutoDeploy"
BUILD_ROOT="$CACHE/$APP"
LOG_DIR="$BUILD_ROOT/logs"
mkdir -p "$LOG_DIR"
# Live progress of all apps for `scripts/live.sh`.
LIVE="$CACHE/live.log"
[ -f "$LIVE" ] && [ "$(wc -c < "$LIVE")" -gt 2000000 ] && : > "$LIVE"
exec > >(awk -v p="[$APP] " '{ print p $0; fflush() }' | tee -a "$LIVE") 2>&1
echo "==> $(date '+%H:%M:%S') Deploy started: $(git log -1 --format=%s)"

SETTINGS=()
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    SETTINGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

# build <sdk> → prints the path of the built app
build() {
    local sdk="$1"
    local log="$LOG_DIR/build-$sdk.log"
    echo "==> Building for $sdk" >&2
    if ! xcodebuild \
        -project "$PROJECT" \
        -target "$APP" \
        -configuration Release \
        -sdk "$sdk" \
        -allowProvisioningUpdates \
        SYMROOT="$BUILD_ROOT/Products" \
        OBJROOT="$BUILD_ROOT/Intermediates" \
        "${SETTINGS[@]+"${SETTINGS[@]}"}" \
        build 2>&1 | tee "$log" | { grep --line-buffered -E "^(SwiftCompile|CompileSwift |Ld |CodeSign )|error:" | cut -c1-120 >&2 || true; }
    then
        echo "==> Build for $sdk FAILED. Errors:" >&2
        grep -E "error:|fatal error|Code ?Sign|provisioning" "$log" | sort -u >&2 || true
        echo "--- last lines of $log ---" >&2
        tail -n 40 "$log" >&2
        exit 1
    fi
    if [ "$sdk" = macosx ]; then
        echo "$BUILD_ROOT/Products/Release/$APP.app"
    else
        echo "$BUILD_ROOT/Products/Release-$sdk/$APP.app"
    fi
}

find_iphone() {
    if [ -n "${IPHONE_ID:-}" ]; then echo "$IPHONE_ID"; return; fi
    local json
    json="$(mktemp)"
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
    /usr/bin/python3 - "$json" "${IPHONE_NAME:-}" <<'PY'
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
PY
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
    local app dest="/Applications/$APP.app"
    app="$(build macosx)" || exit 1
    # Swap the bundle in place instead of quitting the app, so a push doesn't stop it.
    # A running copy keeps going; the next launch is the new version.
    rm -rf "$dest.new"
    ditto "$app" "$dest.new" || exit 1
    rm -rf "$dest"
    mv "$dest.new" "$dest" || exit 1
    echo "==> Installed $dest"
    if [ "${OPEN_MAC_APP:-0}" = 1 ]; then
        open "$dest"
    elif pgrep -xq "$APP"; then
        echo "    $APP is running; quit and reopen it to use the new version."
    fi
}

supports_mac() { grep -q 'SUPPORTED_PLATFORMS = .*macosx' "$PROJECT/project.pbxproj"; }

case "$TARGETS" in
    ios) deploy_ios ;;
    mac) deploy_mac ;;
    all)
        # `set -e` is off inside `( … ) ||`, hence the explicit `|| exit 1` in the functions.
        # Each in a subshell, so an unreachable iPhone doesn't stop the Mac update (and vice versa).
        status=0
        ( deploy_ios ) || status=1
        if supports_mac; then ( deploy_mac ) || status=1; fi
        [ $status = 0 ] && echo "==> $(date '+%H:%M:%S') Done ✓" || echo "==> $(date '+%H:%M:%S') FAILED ✗"
        exit $status
        ;;
    *) echo "usage: $0 [ios|mac|all]" >&2; exit 2 ;;
esac
