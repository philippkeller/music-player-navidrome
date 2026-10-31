# NaviSync

A small SwiftUI music player for iOS and macOS that streams from a Navidrome (Subsonic) server,
modelled on Amperfy, with one extra feature: **the current song and position hand off between
devices**.

## Features

- Artist → Songs browsing (songs grouped by album, newest first), search over artists
- Streaming, plus offline downloads (per song, album or whole artist)
- Library and cover art are cached, so browsing downloaded music works offline
- Queue (play next / add to queue / remove), lock screen, Control Center and media-key controls
- Scrobbling to Navidrome
- Output picker in the player: AirPlay 2 speakers (Sonos included), Apple TV, Bluetooth.
  On the Mac there's also a headphones button that reconnects paired Bluetooth devices
- **Handoff** between iPhone and Mac via the server's saved play queue

### How the sync works

Navidrome stores one play queue per user (`savePlayQueue` / `getPlayQueue`) along with the
client that saved it (`changedBy`).

- While playing, the app saves queue + current song + position every ~10 s, and on pause,
  seek, track change and when the app goes to the background.
- The same state is kept on the device too, so the app always reopens on the last song at its
  position, even offline or after iOS closed it.
- Nothing is uploaded unless something changed on this device, so opening and closing an idle app
  never overwrites what another device is playing.
- When the app becomes active it fetches the server queue:
  - nothing loaded locally → the remote song is loaded at its position (paused, press play)
  - another device saved something newer → a **"Continue from Mac"** banner with *Resume*
- *Settings → Sync* shows what the server currently holds (song, position, device, time).
- Devices identify as `NaviSync-iPhone`, `NaviSync-iPad`, `NaviSync-Mac`.

## Building

Requires Xcode 16 or newer (the project uses synchronized folders, so new files in `NaviSync/`
are picked up automatically, with no project file edits needed).

1. Set up signing once (not checked in):
   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   # edit Config/Local.xcconfig and set DEVELOPMENT_TEAM to your Team ID
   ```
   Your Team ID is shown at developer.apple.com → Account → Membership details.
   Please don't set the team in Xcode's *Signing & Capabilities* tab: that writes into
   `project.pbxproj` and causes merge conflicts on the next pull.
2. Open `NaviSync.xcodeproj`, pick the **NaviSync** scheme and a destination
   (*My Mac* or your iPhone), then Run.
3. Log in with your Navidrome username and password (the server defaults to `https://music.backl.io`).
   Only a salted token is stored in the keychain, never the password.

### Installing on the Mac

Running from Xcode only launches the app from its build folder. To install it properly into
`/Applications` (so Spotlight, Launchpad and the Dock find it):

```sh
./scripts/install-mac.sh
```

This builds a Release version, quits a running NaviSync, replaces `/Applications/NaviSync.app`
and launches it. Your login and downloads are kept, because they live in the app's container,
not in the app bundle.

`scripts/deploy.sh [ios|mac|all]` builds and installs without Xcode's UI: on the iPhone (over
Wi-Fi or cable) and/or into `/Applications`.

### Automatic installs on every push

A GitHub Actions workflow (`.github/workflows/deploy.yml`) runs `scripts/deploy.sh` on a
self-hosted runner on the Mac laptop for every push to `main`. A minute or two after a push the
new version is on the iPhone and in `/Applications`. A running Mac app isn't quit (so music keeps
playing); it picks up the new version on its next launch. Installing on the iPhone restarts the
app there, and it reopens on the same song and position.

One-time setup, on the Mac in this repo:

```sh
scripts/setup-runner.sh
```

It installs the GitHub CLI if needed (and opens a browser to log in), registers the laptop as the
repo's runner, starts it as a login service and copies the Team ID from `Config/Local.xcconfig`
into a repo variable. The first build may show a keychain prompt for `codesign`. Choose
*Always Allow*.

Requirements while it runs: the laptop is on and logged in. For the iPhone install, the phone
must be on the same Wi-Fi and preferably unlocked. If the iPhone isn't reachable, the Mac is
still updated and the run is marked failed. Re-run it from the *Actions* tab
(*Build & install → Run workflow*, choose `ios`). Build errors are shown in the run's log.

## Project layout

```
NaviSync/
  App/        App entry, AppModel (wires services together)
  Models/     Subsonic data types
  Services/   SubsonicClient, PlayerController (AVPlayer), SyncService (handoff),
              DownloadManager, LibraryStore (offline cache), CoverArtCache, Storage
  Views/      SwiftUI views (shared; MainViews.swift has the iOS tab layout and the macOS split view)
Config/       xcconfig, Info.plist (background audio), macOS entitlements
```
