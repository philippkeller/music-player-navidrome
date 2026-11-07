#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcrun >/dev/null; then
    echo "These checks require Xcode on macOS (AVFoundation and MediaPlayer)." >&2
    exit 1
fi
seek_test_dir=$(mktemp -d)
trap 'rm -rf "$seek_test_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    NaviSync/Models/Models.swift \
    NaviSync/Services/SubsonicClient.swift \
    NaviSync/Services/SonosClient.swift \
    NaviSync/Services/PlayerController.swift \
    NaviSync/Services/PlaybackProgressWatchdog.swift \
    Tests/SeekRegression.swift \
    -o "$seek_test_dir/seek-regression"
"$seek_test_dir/seek-regression"
