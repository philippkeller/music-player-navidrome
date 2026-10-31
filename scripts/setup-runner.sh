#!/bin/bash
# One-time setup for automatic installs: registers this Mac as the GitHub Actions runner
# for this repo and stores the signing Team ID as a repo variable.
# Needs the GitHub CLI; installs it with Homebrew if missing.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_DIR="$PWD"
RUNNER_DIR="$HOME/actions-runner"

if ! command -v gh >/dev/null; then
    echo "==> Installing the GitHub CLI"
    brew install gh
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "==> Log in to GitHub (a browser window opens)"
    gh auth login --web --git-protocol ssh
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "==> Repo: $REPO"

# Team ID: from Local.xcconfig or a team picked in Xcode's Signing tab (ignoring the example
# placeholder), else from the "Apple Development" certificate (its OU is the Team ID).
TEAM="$(grep -hoE 'DEVELOPMENT_TEAM *= *"?[A-Z0-9]{10}' Config/Local.xcconfig NaviSync.xcodeproj/project.pbxproj 2>/dev/null \
    | grep -oE '[A-Z0-9]{10}$' | grep -v ABCDE12345 | head -n1 || true)"
if [ -z "$TEAM" ]; then
    TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | grep -oE 'OU *= *[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' | head -n1 || true)"
fi
if [ -z "$TEAM" ]; then
    echo "error: couldn't find your Team ID. Put it into Config/Local.xcconfig and re-run." >&2
    exit 1
fi
gh variable set DEVELOPMENT_TEAM --repo "$REPO" --body "$TEAM"
echo "==> Set DEVELOPMENT_TEAM=$TEAM"

if [ -f "$RUNNER_DIR/.runner" ]; then
    echo "==> Runner already configured in $RUNNER_DIR"
else
    case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=x64 ;; esac
    VERSION="$(gh api repos/actions/runner/releases/latest -q .tag_name | sed 's/^v//')"
    echo "==> Downloading runner $VERSION ($ARCH)"
    mkdir -p "$RUNNER_DIR"
    curl -fsSL "https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-osx-$ARCH-$VERSION.tar.gz" \
        | tar xz -C "$RUNNER_DIR"
    TOKEN="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" -q .token)"
    cd "$RUNNER_DIR"
    ./config.sh --unattended --url "https://github.com/$REPO" --token "$TOKEN" \
        --name "$(scutil --get LocalHostName)" --replace
fi

cd "$RUNNER_DIR"
./svc.sh install >/dev/null 2>&1 || true
# The runner's launch agent asks for its own security session (SessionCreate), where the
# login keychain is locked and codesign fails with errSecInternalComponent. Drop that.
for plist in "$HOME"/Library/LaunchAgents/actions.runner.*.plist; do
    /usr/libexec/PlistBuddy -c "Delete :SessionCreate" "$plist" 2>/dev/null || true
done
./svc.sh stop >/dev/null 2>&1 || true
./svc.sh start
echo
echo "==> Done. The runner starts with your login. Test it with:"
echo "    gh workflow run deploy.yml --repo $REPO && gh run watch --repo $REPO"
cd "$REPO_DIR"
