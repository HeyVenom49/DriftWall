# Driftwall

A native macOS live-wallpaper app for personal use. Browse the included wallpapers or import your own
videos, preview them, and play them behind your windows on one or more displays — with favorites,
history, playlists with automatic rotation, per-display assignments, and menu-bar control.

Built with Swift, SwiftUI, AppKit and AVFoundation. No accounts, no network access, no telemetry.

> Inspired by the feature set of apps like Wallspace. No Wallspace content, branding or assets are used:
> the eight included wallpapers are original, procedurally generated videos rendered at build time.

## Requirements

- macOS 14 Sonoma or later (developed and tested on macOS 27.0.1, Apple silicon, two displays)
- Swift 6 toolchain — either Xcode or just the **Command Line Tools** (`xcode-select --install`)
- ~100 MB free disk space for the build

## Build and run

```bash
scripts/build_app.sh          # builds build/Driftwall.app (release, ad-hoc signed)
open build/Driftwall.app
```

The first build also renders the sample wallpapers into `Resources/Generated/` (about 80 seconds,
cached afterwards; the folder is git-ignored).

To install, drag `build/Driftwall.app` into `/Applications`. Because the build is only ad-hoc signed,
macOS may ask for confirmation the first time you open it (right-click › Open).

### Tests

```bash
scripts/test.sh               # unit/integration tests + end-to-end smoke test in the packaged app
scripts/test.sh --unit        # unit/integration tests only
```

- `swift test` runs 69 Swift Testing tests for `DriftwallCore` (persistence, search, favorites,
  playlists, rotation, display-assignment logic, import validation, real AVFoundation metadata
  extraction and thumbnail generation).
- The smoke test launches the packaged app with `--smoke-test` against a throwaway data folder and
  drives the real `AppController` (applying wallpapers on the real displays, verifying AVFoundation
  playback state, pause/resume, rotation, import of valid/invalid/duplicate/moved/deleted files,
  persistence on disk, cache clearing). It prints `SMOKE: N passed, M failed`.

> **Note:** the smoke test really does put a live wallpaper on your desktop for a few seconds, then removes it.
> It never touches your real library.

### Building without Xcode

With only the Command Line Tools installed, `scripts/sdk_env.sh` (sourced by the scripts) makes two
adjustments. Use the scripts rather than running `swift build` directly:

1. It builds against the macOS **26.x SDK**, because in the macOS 27 SDK SwiftUI's `@State` is a macro
   whose compiler plugin ships only with Xcode.
2. It loads the swift-testing macro plugin explicitly for `swift test`. Without this, the Command Line
   Tools build system sometimes fails with "plugin for module 'TestingMacros' not found".

XCTest and XCUITest are not available without Xcode, so the tests use Swift Testing, and the in-app
smoke test takes the place of UI automation.

## Features

| Area | What works |
| --- | --- |
| **Home** | Hero card for the current or featured wallpaper, Recently Used, Favorites, Featured, curated collections, Popular, category shortcuts, import call-to-action |
| **Explore** | Category chips, filters by source, minimum resolution and favorites, six sort orders, toolbar search, result counts, a no-results state with reset |
| **Detail** | Large looping preview with play/pause (Space), metadata (duration, resolution, fps, codec, size, dates, usage), apply to all/main/specific display (⌘↩), favorite (⌘L), add to playlist, live status per display, Show in Finder, locate a missing file, remove |
| **Favorites** | Grid with filter and sort; persisted |
| **Recent** | Applied/viewed history with Reapply, missing-file recovery and Clear History |
| **Playlists** | Create, rename, delete, add (multi-select picker), remove, drag to reorder, play, interval, shuffle, pause/resume, countdown |
| **My Videos** | Imported videos, drop zone, Check Files, missing-file panel with Locate…/Remove |
| **Import** | Native open panel (files or folders) and drag and drop anywhere on the window. Accepts `.mov`, `.mp4` and `.m4v` and checks them with AVFoundation (playable, has a video track, non-zero duration). Reads metadata, generates thumbnails, rejects duplicates and reports per-file errors. Files are referenced in place through bookmarks that follow moves and renames, or copied into the library (setting) |
| **Displays** | Arrangement diagram, per-display or same-on-all mode, per-display wallpaper choice and clear, default target, remembered assignments for disconnected displays |
| **Lock Screen** | Video while the Mac is locked, through the bundled `Driftwall.saver` screen-saver module (public ScreenSaver API). Same-as-desktop or independent wallpaper, preview, compatibility check, setup checklist (module installed, selected, password delay), Test Now, optional still system picture. Honest capability table for the running macOS |
| **Lock Screen › Advanced** | Opt-in: shows your video as one of Apple's Aerial wallpapers so macOS animates it on the lock screen itself. It needs your administrator password, backs up Apple's original first, and has a one-click Restore. See TECHNICAL_LIMITATIONS.md |
| **Menu bar** | Current wallpaper, pause state, Pause/Resume, Next/Previous, Recent, Favorites, Playlists (start/pause/stop rotation), Stop, Open, Settings, Quit |
| **Settings** | General (launch at login, Dock icon, restore on launch), Playback (scaling, desktop icons, hover previews, power behavior, system-wallpaper sync, live status), Displays, Rotation, Library and Cache (sizes, clear), Appearance, Shortcuts (including optional global hot keys), Diagnostics (event log, copy log) |

## Usage

1. On first launch, a short welcome guide explains the workflow.
2. Pick a wallpaper and choose **Set as Wallpaper**. It plays behind your windows on every Space.
3. To import your own video, choose **Import** (⌘I) or drop it on the window.
4. Make a playlist and press **Play Playlist** to rotate wallpapers on a schedule.
5. Closing the window keeps the wallpaper running. Use the menu-bar icon for control, and **Quit** to stop.

Keyboard: ⌘1…⌘7 switch screens, ⌘F searches, ⌥⌘P pauses, ⌥⌘→/← skip to the next or previous
wallpaper. Optional global shortcuts (⌃⌥⌘P, ⌃⌥⌘→, ⌃⌥⌘←) work from any app.

## Data and privacy

- Library database: `~/Library/Application Support/Driftwall/Library.sqlite`
- Copies of imported videos (only if copying is enabled): `~/Library/Application Support/Driftwall/Media/`
- Thumbnails and still frames: `~/Library/Caches/Driftwall/`
- Nothing is uploaded. Driftwall never deletes your original video files. Removing a library item
  deletes only a copy that Driftwall made inside its own Media folder.
- Set `DRIFTWALL_DATA_DIR=/some/folder` to run with a separate library (used by the tests).

## Known limitations

These are summarized here; [TECHNICAL_LIMITATIONS.md](TECHNICAL_LIMITATIONS.md) has the details.

- The live wallpaper is a desktop-level window, **not** a system wallpaper.
- **Lock screen:** video plays while the Mac is locked through Driftwall's screen saver, which you
  select in System Settings. The password prompt and login window themselves can only show a still
  picture: macOS offers no public API for video there, and its system video wallpapers require a
  private Apple entitlement.
- Only video files are supported (no still images, GIFs or web wallpapers).
- The app has an ad-hoc signature only. It is not notarized, so it is not ready for distribution.
- Launch at login relies on `SMAppService`, which may need approval in System Settings › Login Items.
  It was not exercised end to end for this ad-hoc build.

See also [ARCHITECTURE.md](ARCHITECTURE.md) and [CHANGELOG.md](CHANGELOG.md).
