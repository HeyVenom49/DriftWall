# Changelog

## 1.2.0 — 2026-10-20

### Added
- **Advanced: animated lock screen.** Opt-in, behind an explicit confirmation, and it asks for your
  administrator password. It shows a Driftwall video as one of Apple's Aerial wallpapers, which macOS
  animates on the lock screen itself.
  - It converts the video to Apple's format and backs up the original first.
  - It replaces one Aerial file and verifies the result.
  - It detects when you choose that Aerial, and when macOS puts its own file back.
  - One-click Restore.
  - 13 new tests.

### Pending
- A real-system test of the Advanced mode, which needs your password.

## 1.1.0 — 2026-10-20

### Added
- **Lock Screen**: video while the Mac is locked, through a new public-API screen-saver module
  (`Driftwall.saver`), plus a `LockScreenWallpaperService` with an injectable system layer.
  The new screen includes:
  - the capability table for the running macOS;
  - same-as-desktop or independent wallpaper, with preview and compatibility checks;
  - a setup checklist (module installed, selected, password delay) and Test Now;
  - an optional still system picture.
- 15 unit tests and 9 end-to-end checks for the lock screen.

### Fixed
- Lock-screen apply deleted its own fresh copy when the folder path went through a symlink
  (`/var` vs `/private/var`). Found by the new tests.
- Applying to the lock screen on a brand-new library no longer fails while video metadata is still loading.

### Verified
- Video plays while the Mac is locked: confirmed on macOS 27.0.1 from loginwindow and saver logs
  (see TECHNICAL_LIMITATIONS.md).

### Changed (follow-up)
- **One-click setup.** Set Up Lock Screen installs the module, prepares the video and opens the right
  System Settings pane. Driftwall then confirms automatically when you choose it there.
- **Lock Now**, in the Lock Screen page and the menu bar, locks the Mac and shows the video right away.
- The module updates itself at launch after an app update; your screen-saver choice is kept.
- On macOS 27, "Open Screen Saver Settings" opens Wallpaper settings, because the separate Screen Saver
  pane no longer exists.

## 1.0.1 — 2026-10-20

### Changed
- In "Different per Display" mode, Next/Previous (toolbar, menu bar, shortcuts) now change only the
  display under the pointer instead of every display. "Same on All Displays" mode still changes all.
- Playlist rotation has a **Show on** choice (All Displays or one display), in the playlist screen and
  in Settings › Rotation. Rotating a playlist on one display leaves the others alone.

## 1.0.0 — 2026-10-20

First complete version.

### Added
- **Playback engine.** Desktop-level, click-through playback windows, one per display. Displays that
  show the same wallpaper share one looping AVFoundation decoder. Wallpaper changes cross-fade without
  a black flash. Playback pauses for sleep, display sleep, screen lock, user switching, battery, Low
  Power Mode, and a fully covered desktop. When playback fails, the system wallpaper shows instead and
  the failure is logged.
- **Library.** Eight original, procedurally generated sample wallpapers, rendered at build time by
  `SampleMediaGenerator`, plus curated collections. Local video import through the open panel or drag
  and drop (files or folders). Imports are validated and their metadata read; duplicates are rejected.
  Imported files are referenced in place through bookmarks that follow moves and renames, or optionally
  copied into the library. Missing-file detection with Locate…/Remove recovery.
- **Thumbnails.** An asynchronous, bounded, de-duplicated thumbnail pipeline with a disk cache and an
  in-memory cache. Hover previews and the detail preview player.
- **Screens.** Home, Explore (search, filters, sorting), Detail, Favorites, Recent, My Videos,
  Playlists (create, rename, delete, add, remove, reorder, rotation controls), Displays (arrangement,
  per-display or mirror mode, remembered displays), Settings (eight panes), menu-bar menu, and a
  welcome guide.
- **Rotation.** Automatic rotation through playlists with sequential or shuffle order, true previous,
  pause and resume, persistence, and suspension while asleep or locked.
- **Persistence.** SQLite with cascading foreign keys, a schema version, settings decoding that
  tolerates missing or bad keys, and recovery from a damaged database without deleting it.
- **System integration.** Launch at login (`SMAppService`), optional global hot keys, an optional
  setting that matches the static system wallpaper to a still frame, and a Dock-icon preference.
- **Diagnostics.** An in-app event log with copy and clear. Nothing leaves the Mac.
- **Testing.** 69 Swift Testing unit and integration tests, plus an end-to-end smoke test in
  the packaged app (`--smoke-test`) and a UI snapshot renderer (`--ui-snapshots`).
- **Build.** `scripts/build_app.sh` assembles and ad-hoc signs `build/Driftwall.app`;
  `scripts/test.sh` runs all checks.

### Fixed during development
- Thumbnails using `.fill` no longer overflow their containers. This affected the Home hero and the
  display arrangement diagram.
- The detail preview no longer hides its thumbnail behind a black backing before the first frame.
