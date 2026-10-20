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
- **Handoff** between iPhone and Mac via the server's saved play queue

### How the sync works

Navidrome stores one play queue per user (`savePlayQueue` / `getPlayQueue`) along with the
client that saved it (`changedBy`).

- While playing, the app saves queue + current song + position every ~10 s, and on pause,
  seek, track change and when the app goes to the background.
- When the app becomes active it fetches the server queue:
  - nothing loaded locally → the remote song is loaded at its position (paused, press play)
  - another device saved something different → a **"Continue from Mac"** banner with *Resume*
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
and launches it. Re-run it after a `git pull` to update. Your login and downloads are kept,
because they live in the app's container, not in the app bundle.

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
