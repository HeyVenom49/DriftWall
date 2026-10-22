# Changelog

## 1.3.1 — 2026-10-22

### Performance
- **In-window previews stop decoding while you can't see them.** That covers a minimized, covered or
  hidden window, or one on another Space. With the detail page open behind other windows, Driftwall
  used 9.0–9.2% CPU plus 13.3–13.6% in the video decoder service; now it's 6.6–6.7% plus 8.6–8.7%,
  the same as the wallpaper alone. A paused preview stays paused.
- **Thumbnails are decoded off the main thread.** Before, the JPEG was decoded on first draw, during
  scrolling. Concurrent requests for the same thumbnail share one load.
- **Explore search settles before it rebuilds the grid.** The results follow the typed text after a
  150 ms pause, not on every keystroke. Sort, category, filters and clearing still apply at once.
  Typing in a 400-wallpaper library: 36.5–36.7% → 30.0–30.1% CPU, and frames over 16 ms dropped from
  193–194 to 62–68.
- **Only one in-app preview decodes at a time.** A newer preview, such as a hover preview over the Lock
  Screen page's preview, holds the older one paused. The older one resumes where it was when the newer
  one ends.
- Grid cards now check "is this wallpaper live?" against a dedicated set. Before, they read the full
  playback state, so every pause, resume or loading change re-evaluated them. Measured with pause
  toggling over a 400-item grid: no measurable difference (11.7–12.7% → 12.6–12.9%).
- The thumbnail memory cache's cost is now taken from the decoded bitmap's bytes.
- **Settings › Storage and Settings › About no longer walk the cache and media folders on the main
  thread,** and About no longer repeats the walk for every new log entry.
- Measured before/after figures, the method and the remaining bottlenecks are in
  TECHNICAL_LIMITATIONS.md › Performance measurements.

### Fixed
- **Hiding Driftwall (⌘H) no longer hides the live wallpaper.**
- **The cleanup task now records where Driftwall.app really is.** When macOS ran the app from a
  temporary App Translocation location (a downloaded, quarantined app), the task used to record that
  location instead.

### Developer
- `--perf-scenario <name>` (with `DRIFTWALL_DATA_DIR`) holds the app in a repeatable scenario and
  reports main-thread stalls, startup time, wallpaper-switch time and decoder counts. Scenarios:
  background, paused, home, detail, detail-hidden, lockscreen, scroll, navigate, pause-toggle, type
  and switch.
- The smoke test checks decoder release on replace and clear, hidden-preview suspend/resume, preview
  release and de-duplicated thumbnail loads.

## 1.3.0 — 2026-10-21

### Added
- **Everything Driftwall changes outside its own folders can be undone, even after the app is
  deleted.**
  - **Settings › General › Changes Outside Driftwall** lists what's in place and has **Undo All
    System Changes…**: Apple's original Aerial, the default screen saver, your original desktop
    pictures, and no login item.
  - While any of those changes are in place, a small cleanup task (a per-user LaunchAgent and a
    script) is installed. If Driftwall.app is gone for 10 minutes, it undoes them and removes itself.
  - It does nothing while the app exists anywhere (found by bundle identifier if moved), or while the
    drive it was on is unplugged; an app in the Trash counts as deleted. A failed step is retried.
  - Driftwall now records each display's own desktop picture before it first replaces it, so it can
    be put back. Before, it couldn't.
- **Naming playlists.** New Playlist asks for a name. Rename… is in the playlist's menu and in
  right-click menus, and is also reached with the pencil button or by double-clicking the title.

### Changed — interface redesign
A visual and interaction redesign of every screen. Services, persistence and system integration are
unchanged; every control still calls the same `AppController` actions.

- **Design system:** one interaction accent, the system accent color, so it follows System Settings.
  Green, orange and red are used only for status. Deep-charcoal neutrals instead of near-black.
  Tokens for type, spacing, radii, sizes and motion; animations respect Reduce Motion. New shared
  components: `StatusDot`, `StatusLabel`, `InlineNotice` and `ViewOptionsMenu`.
- **Window:**
  - The sidebar has three groups: Browse (Home, Explore, Favorites, Recent); Library (My Videos and
    Playlists, with each playlist nested); and System (Displays, Lock Screen). Settings and a
    slimmer now-playing strip sit at the bottom.
- **Visual polish (follow-up):** tighter charcoal palette with dedicated sidebar / text tokens,
  lighter thumbnail hover chrome, softer strokes and shadows so artwork stays the focus, and clearer
  Lock Screen copy that distinguishes live Aerial playback from screen-saver stills.
  - The toolbar is contextual: Pause/Next only while a live wallpaper runs, View Options only on grid
    pages, Import always.
- **Wallpaper cards:**
  - The artwork comes first. Live is a small green dot plus "Live" in the subtitle, instead of a
    thick border and badges. Actions appear on hover; no shadows or scaling.
  - Cards are keyboard-focusable: Tab moves between them, Return opens, Space sets as wallpaper.
- **Home:** a compact "On your desktop" strip with real playback status replaces the 360 pt hero, so
  the library shows on the first screen. The "Popular" shelf, ranked by a curated value rather than
  real usage, is removed.
- **Explore:** category tokens, one Filters menu (source, resolution, favorites) that shows how many
  are active, sorting in the header, and Clear Filters only when something is filtered.
- **Detail:** the large preview dominates. Below it, Set as Wallpaper with its display target,
  Favorite, Add to Playlist and a More menu, live status per display, and a compact metadata grid.
  There's no boxed form any more.
- **Displays:** one row per display with its wallpaper, real status, Choose Wallpaper and Make Default
  Target. The arrangement drawing marks the default target. The outdated "the lock screen can't show
  live video" note is replaced.
- **Lock Screen:**
  - Two clearly explained options: Animated Lock Screen (behind the password prompt) and Screen
    Saver Video (the password prompt appears over a still picture).
  - The capability list is corrected: video behind the password prompt is possible with the Animated
    Lock Screen, while Driftwall drawing on the password screen itself isn't. Previews are labelled
    as previews of the video, not of the lock screen.
- **Settings:** General, Appearance, Playback (now including rotation), Displays, a new Lock Screen
  pane, Library & Cache, Shortcuts and About (version plus diagnostics).
- **Menu bar:** what's on the desktop, Pause/Next/Previous, Recent, Favorites and Playlists (as
  checkmarks; unchecking stops rotation), Lock Screen Now, then Open, Settings and Quit.
- **⌘F** now also puts the cursor in the search field on macOS 15 and later.

## 1.2.2 — 2026-10-21

### Fixed
- **Animated lock screen didn't play on a second display.** Each display has its own wallpaper, and
  macOS only animates the lock screen on displays whose wallpaper is the replaced Aerial. Driftwall
  checked whether the Aerial was chosen on *any* display, so it reported success while other displays
  showed a still picture. It now checks every connected display.
  - Setup only finishes once all of them show the Aerial: it names the displays still missing and
    waits while you choose the Aerial for each one in Wallpaper settings.
  - The panel also names any display that stops showing it, for example a newly connected monitor.
- **Second display never detected (setup kept waiting).** With "Show on all Spaces" off, macOS saves
  a display's wallpaper for its current Space only, and Driftwall only read the per-display entry. It
  now reads which Space each display shows (`com.apple.spaces`) and checks that Space's choice first.
- **Lock screen black on some locks (likely cause fixed; to be confirmed on the lock screen).**
  macOS's Aerial player restarts reading at keyframes when it speeds the video up or slows it down
  around lock and unlock. Driftwall's files came from an export preset with an *open GOP*: CRA
  keyframes followed by RASL frames that depend on the previous GOP and can't be decoded from that
  keyframe.
  - The player logged "failed to acquire next sample" on unlock, and on the next lock only one of the
    three players started again. Apple's own Aerials use closed GOPs (IDR keyframes) and never showed
    those errors.
  - Driftwall now encodes with VideoToolbox directly, with open GOP off (keyframes every 2 s). It
    still produces 8-bit HEVC at the source's frame rate in a 600 timescale, the format macOS plays.
  - The closed GOP alone didn't stop the read errors (3 in 4 locks, against 0 in 5 with Apple's
    file). They happen as the player starts slowing the video down. Driftwall now also tags every
    frame with HEVC temporal-layer information, so the file carries the `tscl`/`tsas` sample groups
    Apple's Aerials have.
  - Converting a 141 s 4K Aerial took about 2.5 minutes on the test Mac.
- **Lock screen still for a few seconds after a quick re-lock: macOS behaviour.** What's known (macOS 27.0.1):
  - Locking again within a few seconds of unlocking shows a still image for about 4–5 seconds. The
    video then plays. macOS does the same with Apple's own Aerial (compared on the same Mac): its
    player ignores "play" until it has finished easing to a still, which takes about 6 s.
  - Converting with AVAssetWriter to mirror Apple's files (HEVC Main10, 240000 timescale, Apple's
    length, optionally 240 fps) left the lock screen black on both displays. Driftwall keeps the HEVC
    export preset, whose files play.
- **Safer Aerial writes (code review).**
  - Every change to an Aerial first keeps a snapshot of its current video. It's an APFS clone, so it's
    instant and takes no extra space. A failed or incomplete write puts it back. Before, Restore and
    Repair could leave an empty or partial Aerial.
  - An install whose record can't be written also puts the Aerial back, so the file and Driftwall's
    record never disagree.
  - Starting a change while another is running is now an error. Before, it was silently ignored and
    reported as done.
  - The most specific wallpaper entry wins, so an "all displays" choice can't hide a display's own
    Aerial.
  - A damaged record can't point Driftwall at files outside its backup folder.
- **Restore could put the wrong video back.** If an Aerial had already been changed (by hand, or by an
  earlier version), installing over it backed up that changed file as "Apple's original", and Restore
  then brought back the changed video.
  - Driftwall now checks a file is Apple's original before backing it up. It recomputes the checksum
    macOS recorded when it downloaded the Aerial, so no network is needed.
  - If the file isn't the original, Driftwall uses a verified copy from the screen saver's Aerial
    folder. If there is none, it refuses to install there.
  - Restore also only writes a verified original. When none is left on the Mac, it offers to remove
    Driftwall's video so macOS downloads Apple's again.

### Added
- **Check Apple's Aerials.** The animated lock screen panel lists Aerials that no longer contain
  Apple's original video, with a Repair button for each. Repair writes a verified original copy
  back, or removes the file so macOS downloads it again.

## 1.2.1 — 2026-10-21

### Added
- **Download instead of building.** `scripts/package_release.sh` makes a universal (Apple silicon and
  Intel) `Driftwall-<version>.dmg` to attach to a GitHub release. It notarizes when a Developer ID is
  configured. The README explains installing it and the one-time approval macOS asks for.
- The screen saver Driftwall installs no longer keeps the download quarantine of a downloaded copy of
  Driftwall, so macOS doesn't refuse to load it.

### Fixed
- **Advanced lock screen showed Apple's Aerial instead of your video.** On macOS 27 the wallpaper
  (and so the lock screen) plays its own copy of each Aerial, kept in
  `~/Library/Application Support/com.apple.wallpaper/aerials/videos`. Driftwall was replacing the
  screen saver's copy in `/Library/Application Support/com.apple.idleassetsd`, which the lock screen
  doesn't use. Driftwall now replaces the wallpaper's copy and reloads the wallpaper. Verified on
  macOS 27.0.1.
- **Setup kept asking to install the screen saver** although it was installed and selected. The
  installed module's version was read through `Bundle`, which caches by path for the life of the app,
  so after the module was replaced it kept reporting the old version until Driftwall was restarted.
  The version is now read from disk each time.
- **Advanced mode on a Mac that never used an Aerial wallpaper.** It reported that Apple's Aerials
  weren't available when the wallpaper's Aerial catalog was missing. It now lists every downloaded
  Aerial video even without that catalog, taking names from the screen saver's catalog. When nothing
  is downloaded yet, it explains how to download one, opens Wallpaper settings and notices when
  the download finishes.

### Changed
- **One-click animated lock screen.** "Turn On Animated Lock Screen" plays your current lock-screen
  wallpaper (or the desktop wallpaper).
  - If an Aerial is already your wallpaper, it's used straight away.
  - Otherwise Driftwall opens Wallpaper settings, waits for you to click any Aerial and for macOS to
    download it, then finishes by itself.
  - The manual video and Aerial choice moved to Options.
- **Follows your wallpaper.** When the lock-screen wallpaper changes, Driftwall converts the new one
  into the same Aerial in the background.
- **Still pictures no longer replace the Aerial.** "Also use a still frame as the macOS system
  picture" and "Match system wallpaper to a frame" replaced the Aerial wallpaper with a still image,
  which silently turned the animated lock screen off. While it's on, both options are turned off and
  unavailable.
- Advanced mode no longer asks for your administrator password: the file it changes is in your own
  Library.
- The file is written over in place, so macOS keeps treating it as its downloaded Aerial.
- If macOS downloads Apple's video again, Driftwall puts yours back automatically. It checks at
  launch and every 5 minutes.

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
