#!/bin/bash
# One-time setup for automatic installs: registers this Mac as the GitHub Actions runner
# for each app repo below and stores the signing Team ID as a repo variable.
# Safe to re-run (e.g. after adding a repo). Needs the GitHub CLI; installs it if missing.
set -euo pipefail

OWNER=philippkeller
REPOS=(music-player-navidrome aldi bible-app fitness-tracker-focus scanner-ios sopos weight-tracker-simple)
TEAM=KZ8MPR7WGF

if ! command -v gh >/dev/null; then
    echo "==> Installing the GitHub CLI"
    brew install gh
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "==> Log in to GitHub (a browser window opens)"
    gh auth login --web --git-protocol ssh
fi

case "$(uname -m)" in arm64) ARCH=arm64 ;; *) ARCH=x64 ;; esac
VERSION="$(gh api repos/actions/runner/releases/latest -q .tag_name | sed 's/^v//')"
TARBALL="$HOME/Library/Caches/actions-runner-$VERSION-$ARCH.tar.gz"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" \
    "https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-osx-$ARCH-$VERSION.tar.gz"

for name in "${REPOS[@]}"; do
    repo="$OWNER/$name"
    echo "==> $repo"
    gh variable set DEVELOPMENT_TEAM --repo "$repo" --body "$TEAM"
    # The first runner (NaviSync) lives in ~/actions-runner, the others in ~/actions-runners/<repo>.
    if [ "$name" = music-player-navidrome ] && [ -d "$HOME/actions-runner" ]; then
        dir="$HOME/actions-runner"
    else
        dir="$HOME/actions-runners/$name"
    fi
    if [ ! -f "$dir/.runner" ]; then
        mkdir -p "$dir"
        tar xzf "$TARBALL" -C "$dir"
        token="$(gh api -X POST "repos/$repo/actions/runners/registration-token" -q .token)"
        (cd "$dir" && ./config.sh --unattended --url "https://github.com/$repo" --token "$token" \
            --name "$(scutil --get LocalHostName)" --replace >/dev/null)
    fi
    (
        cd "$dir"
        ./svc.sh install >/dev/null 2>&1 || true
        # The runner's launch agent asks for its own security session (SessionCreate), where the
        # login keychain is locked and codesign fails with errSecInternalComponent. Drop that.
        for plist in "$HOME"/Library/LaunchAgents/actions.runner.$OWNER-$name.*.plist; do
            /usr/libexec/PlistBuddy -c "Delete :SessionCreate" "$plist" 2>/dev/null || true
        done
        ./svc.sh stop >/dev/null 2>&1 || true
        ./svc.sh start >/dev/null
    )
    echo "    runner running"
done

echo
echo "==> Done. Watch builds live with: scripts/live.sh"
