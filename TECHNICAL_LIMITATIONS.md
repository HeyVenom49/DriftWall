# Technical limitations

This file records what Driftwall depends on, what it cannot do, and what has not been verified.

## Environment and toolchain

| Item | Status |
| --- | --- |
| Minimum macOS | 14.0 (`@Observable`, `SMAppService`, `MenuBarExtra`, `openSettings`) |
| Developed and tested on | macOS 27.0.1 (26A434), Apple silicon, Swift 6.4, **Command Line Tools only** (no Xcode) |
| Build SDK without Xcode | macOS **26.5 SDK**. In the 27 SDK, SwiftUI's `@State` is a macro whose plugin (`SwiftUIMacros`) ships only with Xcode. `scripts/sdk_env.sh` selects the SDK. |
| Tests | Swift Testing only: XCTest and XCUITest need Xcode. UI flows are covered by the in-app smoke test, not by UI automation. |
| `swift test` flakiness | The Command Line Tools build system intermittently omits the swift-testing macro plugin. `scripts/test.sh` loads it explicitly (`-load-plugin-library`). |
| Signing | Ad-hoc only (`codesign -s -`). The app is not notarized, has no Developer ID signature, and is **not ready for distribution**. Distributing it would need a Developer ID certificate, the hardened runtime, notarization (`notarytool`) and stapling. |
| Sandbox | Not sandboxed. If it were sandboxed (for example for the Mac App Store), imported files would need security-scoped bookmarks (`.withSecurityScope` plus `startAccessingSecurityScopedResource`) and the user-selected-file entitlement. |

## Animated wallpaper mechanism

- macOS has **no public API for an animated desktop wallpaper.**
  `NSWorkspace.setDesktopImageURL(_:for:options:)` accepts still images only; a video passed to it does
  not animate. Apple's own aerial wallpapers use private system machinery.
- Driftwall therefore uses a **workaround with public APIs**: a borderless, click-through window at
  the desktop window level on each display (see ARCHITECTURE.md). In normal use it behaves like a
  wallpaper, but it is **not identical** to one:
  - **The lock screen and login window** cannot show the desktop window. Video while locked is a
    separate feature, described in [Lock screen](#lock-screen) below.
  - **Mission Control and Show Desktop** may show the system wallpaper behind or around the video
    window while animating. How this looks was not systematically verified.
  - **Desktop icons and widgets.** With "Show desktop icons" on, the window sits below Finder's icon
    layer. Desktop widgets (macOS 14+) live in their own system layer; how they stack with the video was
    not verified on every macOS version.
  - **After quitting**, the system wallpaper reappears.
  - **No private APIs are used**, and no system process (Dock, WindowServer, Finder) is modified.

## Lock screen

Investigated on macOS 27.0.1 (SDK 27.0). The four capabilities are independent:

| Capability | Public mechanism? | Driftwall |
| --- | --- | --- |
| 1. Still picture behind the password/login UI | Only the shared system desktop picture (`NSWorkspace.setDesktopImageURL`). There's no separate lock-screen picture API. | Optional "Also use a still frame as the macOS system picture". |
| 2. Video/dynamic **system** wallpaper | **No.** The `com.apple.wallpaper` extension point (used by Apple's Aerials) requires the private entitlement `com.apple.private.wallpaper.extension`, checked in `/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt`. | Not attempted. Replacing Apple's Aerial video files would modify protected system assets, so it's excluded. |
| 3. Video while the Mac is locked | **Yes, through a screen saver.** `ScreenSaver.framework` is public and not deprecated in SDK 27. Third-party modules run in Apple's sandboxed `legacyScreenSaver` host. Its entitlements allow read-only access to the whole file system and disable library validation, so an ad-hoc-signed module loads. | `Driftwall.saver`. When "Require password after screen saver begins" is **immediate**, the video plays full screen whenever the Mac is locked by the screen saver. |
| 3b. Video **inside** the password/login UI itself | **No.** Nothing public lets an app draw on the lock/login UI, and drawing over it would interfere with authentication. | Not attempted. The password prompt appears over the still system picture. |
| 4. Video on the unlocked desktop | Desktop-level windows (above). | Live desktop wallpaper. |

How it works and what's limited:

- **Locking with ⌃⌘Q** shows macOS's lock UI first. The screen saver (and so the video) starts after
  the "Start Screen Saver when inactive" delay, or immediately through a hot corner or Driftwall's
  **Test Now**.
- **Selecting the screen saver is up to you.** You pick "Driftwall" in System Settings › Screen Saver;
  Driftwall never writes that setting. Driftwall can read the selection (best effort, read-only) from
  `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`. The format isn't documented,
  so when it can't be read the status says so instead of reporting success.
- **Status** is shown as "ready" only when the configuration has been written and read back, the video
  copy exists, the module is installed, and the selection is confirmed.
- **Playback doesn't need Driftwall to be running.** The module reads
  `~/Library/Application Support/Driftwall/LockScreen/config.json` and a clone of the video stored next
  to it. If the config is missing, the saver shows an instruction instead of failing silently.
- **Multiple displays.** macOS runs one saver instance per display, and each plays the same video.
  A different video per display isn't supported.
- **Stopping playback.** Recent `legacyScreenSaver` versions don't reliably call `stopAnimation`, so the
  module also stops on the `com.apple.screensaver.willstop` notification. That's a widely used
  workaround, not documented API.
- **Selecting the screen saver programmatically isn't possible on macOS 27.** System Events
  `set current screen saver` fails with error -10006, and the separate Screen Saver settings pane
  (`com.apple.ScreenSaver-Settings.extension`) no longer exists: the choice now lives in a sheet inside
  Wallpaper settings. Driftwall detects which layout the system has, opens the right pane, and polls
  the read-only store until the user's choice appears. The user's single click is the only manual step.
- **Verified on real hardware**, macOS 27.0.1, 2026-10-20, from system logs:
  - 19:12:02: after the user selected Driftwall, `legacyScreenSaver` loaded the module.
  - 19:14:01.213: Test Now started `ScreenSaverEngine`, and loginwindow logged `startScreenLock`
    and `lockKeybagForScreenLock`.
  - 19:14:02.367: the module logged `playing “Monochrome Silk” (preview: false)` and kept playing
    until it was dismissed at 19:14:06.

  So the video played on screen while the Mac was locked. Video *inside* the password prompt itself
  remains unsupported, as described above.

### Advanced mode: animated lock screen through Apple's Aerials (opt-in)

Added at the user's explicit request. It modifies one macOS-managed file (the user's own copy of
one Aerial video). This is an exception to the original "public APIs only" rule, and it's limited as
follows.

- **Which file the lock screen plays.** macOS has two Aerial stores:
  - `/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS/` (root-owned) is the
    **screen saver's** store.
  - `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<asset-UUID>.mov` (owned by
    the user) is the **wallpaper's** store. `WallpaperAerialsExtension` downloads its own copy here
    when an Aerial is chosen as wallpaper, and the lock screen plays this copy. The catalog is
    `aerials/manifest/entries.json`.

  Version 1.2.0 replaced the file in the screen saver's store (with an administrator password). On
  macOS 27.0.1 the lock screen kept showing Apple's video, because the wallpaper had downloaded and
  played its own copy. Driftwall now replaces the wallpaper's copy, so **no administrator password is
  needed**.
- **Steps.**
  1. Convert to Apple's format: HEVC, exactly 3840×2160 (scaled to fill), looped to at least 120 s.
  2. Back up Apple's original to `Driftwall/Aerial/Backup/` and verify its size.
  3. Keep a snapshot of the Aerial's current video, an APFS clone in Driftwall's folder. Then write the
     converted video **over the existing file in place** (truncate and rewrite, same inode). This keeps the extended attributes macOS stores with the download (`SourceURL`,
     `LastETag`, quarantine), and macOS keeps treating the file as its downloaded Aerial. A
     write that fails or doesn't verify puts the snapshot back, as does a failure to record the
     install. Restore, re-apply and repair work the same way.
  4. Keep the converted video as `Driftwall/Aerial/installed.mov` and write `manifest.json`.
  5. Restart `WallpaperAerialsExtension` and `WallpaperAgent` (`killall`; launchd relaunches them).
     Without this, the extension keeps playing the video it already loaded. The wallpaper flickers
     once.
- **One-click setup.** Driftwall reads which Aerial is chosen as a desktop wallpaper from
  `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`.
  - On macOS 27 this is a choice with provider `com.apple.wallpaper.choice.aerials`, whose
    `Configuration` is a nested binary plist `{assetID: <UUID>}`. Only IDs from the Aerial catalog
    or the videos folder are matched, and the screen saver's `Idle` choices are ignored.
  - If no Aerial is chosen, Driftwall opens Wallpaper settings and polls every 2 s for up to
    15 minutes. It continues once a chosen Aerial's file exists and its size has stopped changing.
  - Driftwall can't choose the wallpaper itself: writing the wallpaper store isn't supported, so that
    one click stays with the user.
  - Verified on macOS 27.0.1 against a real selection ("Tahoe Day").
- **Multiple displays.** The lock screen of each display shows that display's own wallpaper, so the
  video plays only on displays whose wallpaper is the replaced Aerial.
  - A desktop choice under `AllSpacesAndDisplays` applies to every display. Otherwise each
    `Displays/<CoreGraphics display UUID>` entry counts.
  - Driftwall checks every connected display (on setup, when the panel opens, and when displays change)
    and names the ones not showing the Aerial.
  - Driftwall can't set the wallpaper, so the user picks the Aerial once per display in Wallpaper
    settings.
  - Verified on macOS 27.0.1 with a built-in display (Aerial) and an external display (still image).
- **Verifying Apple's originals.** macOS stores the server's ETag on each downloaded Aerial
  (extended attribute `LastETag`, for example `"99627DD80E9ACA43158DDA2E2428CF42-8"`).
  - Apple serves Aerials from S3. A multipart ETag there is the MD5 of the concatenated MD5s of each
    part, followed by the part count. Driftwall recomputes it, offline.
  - The part size depends on the upload: newer Aerials use 64 MiB and some 2023 ones 100,000,000
    bytes. Driftwall tries every common part size that gives the recorded part count, in one read.
  - Verified on 2026-10-21 against Apple's server for all nine Aerials on the test Mac (both part
    sizes occur). A replaced file didn't match.
  - The attribute survives Driftwall's in-place writes, so the expected checksum stays known while
    Driftwall's video is installed.
  - Backups, restores and re-applies only use files that match. Candidates are the file itself,
    Driftwall's backup, and the screen saver's copy in
    `/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS`, which is world-readable
    and checked, never written.
  - A file without the attribute can't be checked, and is trusted as before.
- **Repairing Aerials changed outside Driftwall.** Driftwall writes a verified copy back when there
  is one. Otherwise it removes the file, because macOS downloads a missing Aerial again. When that
  download happens (for example only once the Aerial is shown or chosen again) **was not verified**.
- **Spaces.** With "Show on all Spaces" off, Wallpaper settings stores a display's choice under
  `Spaces/<Space UUID>/Displays/<display UUID>` for the Space it shows, and leaves `Displays/<UUID>`
  unchanged.
  - Driftwall reads each display's current Space from `com.apple.spaces` › `SpacesDisplayConfiguration`
    › `Management Data` › `Monitors` (`Display Identifier` is a display UUID, or `Main`, plus
    `Current Space.uuid`).
  - It checks, in order: `AllSpacesAndDisplays`, then that Space's entry for the display, then
    `Displays/<UUID>`, then that Space's `Default`.
  - The precedence was inferred from one Mac (macOS 27.0.1, built-in plus external display), not
    from documentation.
  - Choosing the Aerial per Space means other Spaces keep their own picture, so Driftwall suggests
    "Show on all Spaces".
- **Video format and lock-screen behaviour** (observed 2026-10-21, macOS 27.0.1, from the unified
  log of `WallpaperAerialsExtension`). These are observations, not documented behaviour.
  - Apple's 4K SDR Aerials are HEVC Main10, 3840×2160, Rec. 709, 240 fps (track timescale 240000),
    about 300 s long. Driftwall's files are 8-bit HEVC from the export preset, at the source's frame
    rate.
  - macOS's Aerial player reads samples itself (`VideoSampleReadingErrors`), not through AVPlayer.
    On lock it ramps the video up ("rampingUp"); on unlock it eases to a still.
  - The position carries over between locks (start = last stop minus about 4.6 s). Apple's videos
    loop past their end (positions over 480 s seen on a 300 s file).
  - On unlock the player keeps playing for about 6 s, then stops on a still. A lock during those
    6 s logs "Play Action: Nothing", and the video starts when the slow-down ends, about 4–5 s into
    the lock. This is the same with Apple's own Aerial (compared on 2026-10-21 with Tahoe Day
    restored). It's macOS behaviour, not something Driftwall can change.
  - Files written with AVAssetWriter in Apple's format (Main10, 240000 timescale, original length,
    and a 240 fps variant) left the lock screen black on both displays, while export-preset files
    play. Why wasn't found. Snapshots of another downloaded Aerial (Golden Gate Sunset) appear in the
    log with Apple's own file too, so they aren't the cause.
  - **Open GOP.** HEVC export presets write CRA keyframes with RASL leading frames (NAL types 21 and
    8/9). Apple's Aerials have one IDR and only TRAIL/TSA frames, in 5 temporal layers with `tscl`/
    `tsas` sample groups.
    - With export-preset files the player logged `VideoSampleReadingErrors Code=4` at unlock, and the
      next lock restarted only one of three players.
    - Driftwall therefore encodes with a VideoToolbox session with `AllowOpenGOP = false`, giving IDR
      keyframes and no RASL frames, and writes the samples unchanged with AVAssetWriter.
    - Temporal layers couldn't be reproduced: the hardware HEVC encoder rejects
      `BaseLayerFrameRateFraction` (-12900).
    - Whether the closed GOP alone stops the black screens has to be confirmed on the lock screen.
- **Still pictures.** Setting a still macOS desktop picture replaces the Aerial wallpaper, and with
  it the animated lock screen. While an Aerial is installed, Driftwall never sets one: both
  still-picture options are turned off and disabled.
- **Following the wallpaper.** When the lock-screen wallpaper changes, the new one is converted into
  the same Aerial (about a minute of encoding each time, including with wallpaper rotation). This
  applies to installs made with one-click setup, or from Options with the current wallpaper.
- **Only Aerials already downloaded can be used.** Choose the Aerial once in Wallpaper settings so
  macOS downloads it, then install over it. Driftwall never creates a new file in that folder: a new
  file wouldn't have macOS's download metadata.
  - The list comes from the `videos` folder itself.
  - Names come from `aerials/manifest/entries.json`, or from the screen saver's catalog when that
    file is missing.
  - On a Mac where no Aerial was ever chosen as wallpaper, the folder doesn't exist. Driftwall shows
    how to download one and waits until the file stops growing.
- **macOS downloading its file again.** When macOS downloads Apple's video again (for example after
  an update or a catalog change), Driftwall backs that download up as the new original and writes the
  kept converted video back. It checks at launch and every 5 minutes. If macOS deleted the file
  instead, Driftwall waits until macOS downloads it again.
- **Restore** writes the backup back in place, restarts the wallpaper processes, and deletes the
  backup, the kept copy and the manifest. Choosing a different Aerial restores the previous one
  first, so at most one Aerial is ever modified.
- **What's never touched.** The catalog, other Aerials, the screen saver's store, system preferences
  and the wallpaper selection. The Aerial keeps Apple's name and thumbnail in System Settings.
- **Disk use.** The backup and the kept converted copy are each about 0.5 GB.
- **Verified on macOS 27.0.1, 2026-10-21.**
  - Writing the converted video in place over the wallpaper store's copy of "Sequoia Sunrise", then
    restarting `WallpaperAerialsExtension` and `WallpaperAgent`: the lock screen played the user's
    video, including behind the password prompt.
  - After the restart, macOS didn't download its own file again.
- **Tests.** 12 tests cover:
  - catalog parsing, path validation and traversal rejection;
  - a full install → detect → restore cycle with a real HEVC conversion, including that macOS's
    download metadata is kept and the wallpaper is reloaded;
  - putting the video back after macOS downloads its file again, and waiting when the file is gone;
  - a missing backup, an invalid source, and switching slots.

  The production 4K conversion is an opt-in test (`DRIFTWALL_SLOW_TESTS=1`).

## Undoing system changes after the app is deleted

macOS doesn't notify an app that it's being deleted, so Driftwall installs a cleanup task outside the
app, and only while it has changed something outside its own folders:
- `~/Library/LaunchAgents/local.driftwall.cleanup.plist`, loaded with `launchctl bootstrap gui/<uid>`,
  with `AssociatedBundleIdentifiers` so System Settings › Login Items names Driftwall;
- `~/Library/Application Support/Driftwall/Cleanup/cleanup.sh`.

It runs at login, every 15 minutes, and when the app's folder changes. The script is rewritten on every
launch, so it follows the app if it moves.

- **Deciding the app is gone.**
  - The recorded path is missing; and
  - the path isn't on an unmounted `/Volumes/<name>` (an unplugged drive); and
  - Spotlight (`mdfind kMDItemCFBundleIdentifier`) finds no copy outside a Trash.
  - Then it waits 10 minutes, because a rebuild or an update replaces the app briefly.
  - If Spotlight is off for the volume, a moved app is only found again once it is launched, since
    each launch records the new path.
- **What it undoes.**
  - It writes the Aerial backup back in place, keeping macOS's download metadata, and only if the
    backup's size matches the record. With no usable backup it removes the modified Aerial, so macOS
    downloads Apple's again.
  - It removes `Driftwall.saver` and the lock-screen video copy.
  - It restores the recorded original desktop pictures through JavaScript for Automation and the
    AppKit bridge (no Apple events, so no permission prompt). Displays are matched by name;
    disconnected ones are skipped.
  - Then it removes itself. Any failed step keeps everything for the next run.
- **Not undone after deletion:** the login item. macOS stops it from opening an app that no longer
  exists; Undo All in Settings unregisters it properly.
- **Verified:** the script's logic, with the real script run by bash against a fake setup in unit
  tests. **Not verified:** a real deletion on a real system, and the desktop-picture restore, which the
  tests only compile, so they can't change the real desktop.

## Lifecycle and power signals

| Signal | API | Status |
| --- | --- | --- |
| System sleep and wake | `NSWorkspace.willSleep` / `didWake` | Implemented; not exercised automatically |
| Display sleep and wake | `NSWorkspace.screensDidSleep` / `screensDidWake` | Implemented; not exercised automatically |
| Fast user switching | `NSWorkspace.sessionDidResignActive` / `sessionDidBecomeActive` | Implemented; not verified |
| Screen lock | `com.apple.screenIsLocked` / `screenIsUnlocked` distributed notifications | Widely used but **not formally documented**. If they stop arriving, the display-sleep signal still pauses playback in most lock scenarios. |
| Battery | IOKit `IOPSNotificationCreateRunLoopSource` | Implemented. Only effective on Macs with a battery. |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChange` | Implemented; not toggled during testing |
| In-window preview not visible | `NSWindow.occlusionState` of the window hosting the preview | Implemented and measured: the preview's decoder pauses while its window is minimized, covered, hidden or on another Space, and resumes when it's visible again. |
| Desktop fully covered | `NSWindow.occlusionState` of the wallpaper window, plus window coverage of the usable area from `CGWindowListCopyWindowInfo` (`DesktopCoverage`) | Implemented and measured. Occlusion alone fires only for full-screen apps: the wallpaper stays "visible" through the menu bar and Dock. Coverage is checked once a second (with tolerance) and on app/Space changes. Gaps narrower than ~1/24 of the screen count as covered. Translucent windows count as opaque, and windows of other apps that report alpha above 0.9 are trusted. |

## Multi-monitor

**Verified** on this machine (built-in Retina 2940×1912 plus an external 1920×1080), by the automated
smoke test and visual inspection:

- one surface per display;
- independent wallpapers per display (two decoders);
- mirror mode (one shared decoder);
- display UUIDs used as stable keys.

**Implemented but not physically exercised**, because that would need unplugging or rearranging
hardware during the session:

- hot-plug and unplug (assignments are kept and restored);
- resolution, arrangement and rotation changes (the surface frame is updated);
- portrait displays;
- three or more displays;
- clamshell mode.

The pure assignment logic for these cases (reconnects with a changed `CGDirectDisplayID`, portrait
displays, fallback when the target display is gone) is covered by unit tests with synthetic
configurations.

Other caveats:

- **Identical monitors.** Two monitors of the same model normally get different UUIDs. If a monitor
  reports no serial number, macOS may give such monitors the same UUID, and they would then share
  an assignment.
- **"Displays have separate Spaces" turned off.** One Space spans all displays. The per-screen windows
  still work, but this configuration was not tested.

## Media

- **Supported containers:** `.mov`, `.mp4` and `.m4v`.
- **Codecs:** whatever AVFoundation can decode on the Mac (H.264, HEVC, ProRes; AV1 only where the
  hardware supports it). Unsupported files are rejected at import with a specific error.
- **Not supported:** still images, GIFs, web or HTML wallpapers, and audio playback (wallpapers are
  always muted).
- **Bookmarks** follow files moved or renamed on the same volume. A file deleted, or moved to an
  unmounted drive, is reported missing. The user can Locate it or remove it from the library.
- **Removing imports.** Originals are never deleted. With "Copy into library" on, removing the item
  deletes only the copy inside `~/Library/Application Support/Driftwall/Media/`; the code verifies that
  the path is inside that folder first.

## Launch at login

Implemented with `SMAppService.mainApp`. With an ad-hoc signed app, macOS may list the item as
needing approval in System Settings › General › Login Items. Driftwall shows that state and links to
the pane. Registration at login was **not exercised end to end** in this session, because it requires
logging out.

## Global shortcuts

These use Carbon's `RegisterEventHotKey`. This is a legacy API, but it is public and needs no
Accessibility permission. If another app already uses a combination, Driftwall reports which one
failed. The shortcuts are fixed and cannot be customized.

## Search

Search is local keyword matching only. Semantic or AI search is **not implemented**. The
`WallpaperSearchEngine` protocol exists so that one could be added later, for example with on-device
embeddings.

## Performance measurements

Measured on 2026-10-22 with the dev harness (`DRIFTWALL_DATA_DIR=<scratch> Driftwall --perf-scenario <name>`,
see `Sources/Driftwall/App/PerfHarness.swift`) and `ps`/`top`/`footprint` sampled over ~27 s per run.
Before and after builds were run interleaved under identical conditions.

**Conditions.** MacBook Air M4 (10-core), macOS 27.0.1, on AC power. Built-in 2560×1664 Retina panel
plus an external 1920×1080 at 144 Hz. Two different wallpapers, so two decoders: 3840×2160 H.264 at
60 fps on the built-in panel, and 2560×1440 H.264 at 60 fps on the external one. "Pause when hidden"
was on. CPU is a percentage of one core. WindowServer idle with Driftwall not running was ~17–20%.
The harness's stall watchdog posts to the main queue every 10 ms, which adds ~40 idle wakeups/s in
every run.

| Scenario | App CPU before → after | Decoder service | App energy (top) | Notes |
| --- | --- | --- | --- | --- |
| Wallpaper only, window closed | 6.7 / 6.4 → 6.3 / 6.7 | 9.0 / 8.6 → 8.3 / 8.9 | ~9 → ~9 | Unchanged (noise ±0.5) |
| Wallpaper paused | 0.6 | 0.0 | 2.7 | Already idle |
| Detail page open, window visible | 9.6 → 9.5 | 13.5 → 13.9 | 11.8 → 11.6 | Preview intentionally plays |
| Detail page open, window not visible | **9.0 / 9.2 → 6.6 / 6.7** | **13.3 / 13.6 → 8.7 / 8.6** | 10.3 / 11.2 → 8.9 / 8.3 | Hidden preview now pauses |
| Scrolling a 400-item grid (warm disk cache) | 35.2 / 32.6 → 35.5 / 33.5 | — | — | Frames over 16 ms: 56 / 78 → 70 / 49 (noise) |
| Switching screens once per second | 22.0 → 20.6 | — | — | p99 main-thread latency 42 ms both |
| Wallpaper switch (apply → playing) | median 79 ms → 80 ms | — | — | Max 129 ms both |
| Startup (launch → playing) | 0.44–0.97 s | — | — | Unchanged |
| Typing in Explore search, 400 items (round 2) | **36.5 / 36.7 → 30.0 / 30.1** | — | 37.4 → 31.5 | Frames over 16 ms: 194 / 193 → 68 / 62; p99 39 / 36 → 21 / 22 ms |
| Pause/resume every 0.5 s over a 400-item grid (round 2) | 12.7 / 11.7 → 12.9 / 12.6 | — | — | No change from the "is live" set for cards |

Attributable to Driftwall with the wallpaper playing: roughly app 6.5% + decoder service 9% +
WindowServer +26–28 points (compositing two 60 fps videos), about 42% of one core in total. Memory
footprint is ~70 MB with the window closed and ~90–160 MB with it open (the larger figure during the
400-item scroll, bounded by the 120 MB thumbnail memory cache).

**What was tried and measured but made no difference (so it was not kept):**
- removing the SwiftUI `MenuBarExtra`. A visible AppKit status-item replicant loop costs no
  measurable CPU;
- an opaque, black-backed video layer after the cross-fade. WindowServer was unchanged;
- a 2-second `preferredForwardBufferDuration` on the looped items. Footprint (68–72 → 68 MB) and
  disk reads (4.33–4.44 → 4.36–4.39 MB/s, equal to the two videos' bitrate) were unchanged, and a short
  read-ahead is the riskier choice for videos on an external drive.

**Covered desktop (round 3).** One display, the KA270 showing the 2560×1440 60 fps video, was covered
by a window filling its usable area. The same build ran with the setting off and on, ×2:

| | Setting off (old behavior) | Setting on |
| --- | --- | --- |
| App CPU | 6.8 / 7.5% | 4.8 / 5.8% |
| Decoder service | 7.9 / 7.9% | 4.5 / 5.1% |
| WindowServer | 42.5 / 43.7% | 26.5 / 35.8% |
| Disk reads | 4.39 / 4.38 MB/s | 3.38 / 3.69 MB/s |

The monitor's own cost, with nothing covered (window closed, setting off vs on, ×2): app CPU 6.8 / 6.7%
→ 7.2 / 6.6%, idle wakeups 18.6 / 18.1 → 14.3 / 18.5 per second. Within noise.

**Whole-system power.** `SystemLoad` from `AppleSmartBattery` gives whole-system power without admin
rights, but it updates only about once a minute and sometimes reports invalid values, so it wasn't
used for short A/B runs.

**Remaining bottlenecks:**
- Desktop playback cost is AVFoundation decode plus WindowServer compositing of two 60 fps streams.
  Reducing it further would need lower-resolution or lower-frame-rate media, which is the user's
  choice.
- Fast scrolling of large grids keeps the main thread ~30% busy in SwiftUI layout and display-list
  work, with no single hotspot. Occasional frames of 20–55 ms remain.
- Opening a screen costs up to ~130 ms of main-thread time for the heavier pages.
- Pausing or resuming takes 40–85 ms of main-thread time about once in six toggles. Most of it is
  CA rendering, consistent with the menu-bar icon redrawing for both menu bars; it wasn't pinned down
  further.
- A preview of the wallpaper that's already live decodes the file a second time while it's visible
  (measured +0–1.3 points of decoder service CPU).

**Not measured:** GPU and media-engine power, because `powermetrics` needs administrator rights;
battery drain over time; scroll smoothness as seen on screen, because there's no Instruments and no
Screen Recording permission. The main-thread watchdog is a proxy. Three or more displays were not
measured either. No frame-rate or battery-life figure is claimed.

## Known issues found during performance work

- **Settings stored as text are ignored.** `loadSettings` reads the settings row only as a BLOB. A
  row written as TEXT (for example edited with `sqlite3`'s JSON functions) is treated as missing, and
  every preference falls back to its default without a log entry.
- **Aerial HEVC encoder stalls (fixed).** Every wait in `ClosedGOPEncoder` was unbounded: encoder
  back-pressure, writer readiness, flushing the last frames and finishing the file. When the encoder
  stopped delivering frames (seen about once in six test runs), the conversion hung forever. Each wait
  is now bounded (20 s; 60 s to finish the file). A stalled attempt is retried once from scratch, and
  a second stall fails with "the video encoder stopped responding". Tests drop encoder output on
  purpose to cover both paths. Why the encoder service occasionally stops responding is not known.

## Things that could not be verified in this environment

- Pixel-level screenshots of the real desktop: the terminal lacks Screen Recording permission. The UI
  was verified with the app's own `--ui-snapshots` renderer. Video layers do not appear in those images.
- Interactive behavior: drag and drop from Finder, open-panel imports, the menu-bar menu, the Settings
  window, onboarding, and keyboard navigation. The underlying actions are exercised by the smoke test.
  The UI controls themselves were not automated.
- Sleep, wake, lock, unlock and fast user switching while a wallpaper is playing.
- The "Match system wallpaper" and lock-screen still-picture settings, which would have replaced the user's real desktop picture.
