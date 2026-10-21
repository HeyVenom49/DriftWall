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
  3. Write the converted video **over the existing file in place** (truncate and rewrite, same
     inode). This keeps the extended attributes macOS stores with the download (`SourceURL`,
     `LastETag`, quarantine), and macOS keeps treating the file as its downloaded Aerial. A
     write that fails or doesn't verify puts the backup back.
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
  - Apple serves Aerials from S3. A multipart ETag there is the MD5 of the concatenated MD5s of 64 MiB
    parts, followed by the part count. Driftwall recomputes it, offline.
  - Verified on macOS 27.0.1: three untouched downloads matched, and a replaced file didn't.
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

## Lifecycle and power signals

| Signal | API | Status |
| --- | --- | --- |
| System sleep and wake | `NSWorkspace.willSleep` / `didWake` | Implemented; not exercised automatically |
| Display sleep and wake | `NSWorkspace.screensDidSleep` / `screensDidWake` | Implemented; not exercised automatically |
| Fast user switching | `NSWorkspace.sessionDidResignActive` / `sessionDidBecomeActive` | Implemented; not verified |
| Screen lock | `com.apple.screenIsLocked` / `screenIsUnlocked` distributed notifications | Widely used but **not formally documented**. If they stop arriving, the display-sleep signal still pauses playback in most lock scenarios. |
| Battery | IOKit `IOPSNotificationCreateRunLoopSource` | Implemented. Only effective on Macs with a battery. |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChange` | Implemented; not toggled during testing |
| Desktop fully covered | `NSWindow.occlusionState` of the wallpaper window | Implemented. How reliably macOS reports occlusion for desktop-level windows (for example under full-screen apps on other Spaces) was **not measured**. |

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

These figures come from one ~30-second sample with `ps`. They are indicative only, not a benchmark.
Conditions: Apple silicon, two displays (2940×1912 and 1920×1080), one 1920×1080 HEVC sample playing
on both (one shared decoder), "pause when hidden" off, main window open.

| Metric | Value |
| --- | --- |
| Driftwall process CPU | ~1.4% average, 2.3% peak |
| Driftwall resident memory | ~130 MB |
| VideoToolbox decoder service | ~1% CPU |
| WindowServer | ~17.5%, against a ~10% baseline measured just afterwards without Driftwall. Roughly 7 points of extra compositing for two displays; one short run. |

Not measured: GPU or energy impact (no `powermetrics` run), 4K or 5K sources, and many-display setups.
No claims about specific frame rates are made.

## Things that could not be verified in this environment

- Pixel-level screenshots of the real desktop: the terminal lacks Screen Recording permission. The UI
  was verified with the app's own `--ui-snapshots` renderer. Video layers do not appear in those images.
- Interactive behavior: drag and drop from Finder, open-panel imports, the menu-bar menu, the Settings
  window, onboarding, and keyboard navigation. The underlying actions are exercised by the smoke test.
  The UI controls themselves were not automated.
- Sleep, wake, lock, unlock and fast user switching while a wallpaper is playing.
- The "Match system wallpaper" and lock-screen still-picture settings, which would have replaced the user's real desktop picture.
