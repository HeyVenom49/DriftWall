# Architecture

Driftwall is a Swift package with three targets plus tests:

```
DriftwallCore            (library, no AppKit/SwiftUI)
  Models/                Wallpaper, Playlist, HistoryEntry, DisplayAssignment, AppSettings
  Persistence/           SQLiteDatabase (thin libsqlite3 wrapper), LibraryStore protocol + SQLiteLibraryStore
  Library/               LibraryModel, SettingsModel, AssignmentsModel (observable, write-through), Catalog
  Search/                WallpaperSearchEngine protocol, KeywordSearchEngine
  Rotation/              RotationSequencer (pure ordering), RotationScheduler (single timer task)
  Displays/              DisplayInfo, DisplayAssignmentResolver (pure)
  Media/                 MediaInspector, MediaImporter, MediaResolver, ThumbnailService (actor)
  Utilities/             AppPaths, DiagnosticsLog

Driftwall                (executable: the app)
  App/                   DriftwallApp (scenes, commands), AppDelegate, AppController (+Actions),
                         RotationCoordinator, NavigationModel, RootView, SmokeTest, UISnapshots
  Services/Playback/     WallpaperPlaybackEngine, SharedPlayer, DesktopSurface, SystemEventMonitor
  Services/Display/      DisplayService
  Services/Wallpaper/    SystemWallpaperService, LaunchAtLoginService, GlobalHotKeyCenter
  Services/Thumbnail/    ThumbnailLoader (memory cache over ThumbnailService)
  DesignSystem/          Theme tokens, cards, grids, shelves, banners, video preview views
  Features/              Home, Explore, Detail, Favorites, Recent, Library, Playlists, Displays,
                         Settings, MenuBar, Onboarding

SampleMediaGenerator     (build-time tool) renders the 8 original looping sample videos + app icon
Tests/DriftwallCoreTests Swift Testing suite
```

## Dependencies

```
Features ──▶ AppController ──▶ LibraryModel / SettingsModel / AssignmentsModel ──▶ LibraryStore (SQLite)
                │                        │
                │                        └──▶ MediaResolver, KeywordSearchEngine
                ├──▶ WallpaperPlaybackEngine ──▶ DesktopSurface ×N ──▶ SharedPlayer (AVQueuePlayer + AVPlayerLooper)
                ├──▶ DisplayService (NSScreen / CoreGraphics)
                ├──▶ RotationCoordinator ──▶ RotationSequencer + RotationScheduler
                ├──▶ SystemEventMonitor (NSWorkspace, distributed notifications, IOKit power)
                ├──▶ ThumbnailLoader ──▶ ThumbnailService (actor, disk cache, bounded concurrency)
                └──▶ MediaImporter ──▶ MediaInspector (AVFoundation)
```

Views never call services directly. They read observable state and invoke `AppController` actions
(`apply`, `importFiles`, `removeWallpaper`, `togglePlayback`, `nextWallpaper`, and so on). The core
library has no UI dependencies, so its logic can be tested without a window server.
`DisplayAssignmentResolver`, `RotationSequencer` and `KeywordSearchEngine` are pure functions or
value types.

## Playback architecture

**Mechanism.** A video set with `NSWorkspace.setDesktopImageURL` does not animate. Driftwall therefore
plays video in its own window on each display, using only public AppKit API.

- `DesktopWallpaperWindow` is borderless, opaque and click-through (`ignoresMouseEvents`), and never
  key or main.
- Its level is `CGWindowLevelForKey(.desktopWindow)`. That is above the system wallpaper and below
  Finder's desktop icons (`.desktopIconWindow`) and every normal window. With "Show desktop icons" off,
  the level is `.desktopIconWindow + 1` instead: the video covers the icons but stays below app windows.
- `collectionBehavior` is `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`, so the
  window appears on every Space, is not moved by Mission Control, and is never part of window cycling.

**Engine.** `WallpaperPlaybackEngine.reconcile(_:)` takes the desired state as a list of
`(display, wallpaperID, url)` requests. It then:

- creates, updates (frame) or closes one `DesktopSurface` per display;
- shares one `SharedPlayer` (`AVQueuePlayer` + `AVPlayerLooper`, muted,
  `preventsDisplaySleepDuringVideoPlayback = false`) among all surfaces that show the same wallpaper.
  Mirror mode on N displays therefore uses one decoder;
- invalidates players that no surface uses: observers are removed, looping is disabled and items are
  released.

**Transitions.** `PlayerContainerView` adds a new `AVPlayerLayer` at opacity 0. It fades the layer in
only after `isReadyForDisplay`, then removes the old layer, so switching wallpapers cross-fades
without a black flash.

**Pausing.** Playback runs only while the set of `PauseReason`s is empty. The reasons are `user`,
`systemSleep`, `displaysAsleep`, `screenLocked`, `sessionInactive`, `onBattery` and `lowPowerMode`.
The battery and Low Power Mode reasons count only when the matching setting is on. Separately,
when "pause when hidden" is on, a decoder pauses while every surface using it reports
`NSWindow.occlusionState` without `.visible`.

**Failures.** A player whose looper or item fails reports `.failed(message)`. The engine hides the
affected surfaces so the normal system wallpaper shows instead of black, logs the failure to
Diagnostics, and shows a banner. Applying the wallpaper again creates a fresh player, which retries.

## Persistence

SQLite (system `libsqlite3`) through `SQLiteLibraryStore`. SwiftData was not used for two reasons:
its macros are unavailable with the Command Line Tools, and the data model is small and relational.

| Table | Contents |
| --- | --- |
| `wallpapers` | Library records (metadata, media path, bookmark, usage) |
| `favorites` | `wallpaper_id`, `created_at` (favorite state is not duplicated on the wallpaper) |
| `history` | Applied/viewed events, pruned to 500 rows |
| `playlists`, `playlist_items` | Ordered by `position` |
| `display_assignments` | Keyed by display UUID; kept while the display is disconnected |
| `settings` | One JSON blob (`AppSettings`) decoded key by key; missing or invalid keys fall back to defaults |

- **Foreign keys.** These use `ON DELETE CASCADE`. Removing a wallpaper also removes its favorites,
  history, playlist entries and assignments. Deleting a playlist never deletes wallpapers or files.
- **Upserts.** These use `ON CONFLICT DO UPDATE`, never `INSERT OR REPLACE`, which would cascade-delete
  related rows.
- **Migrations.** These are keyed by `PRAGMA user_version` (currently 1).
- **Damaged databases.** At startup, a database that fails `quick_check` is moved aside to
  `Library.sqlite.damaged-<timestamp>` (never deleted) and a fresh one is created. The user is told on
  the Home screen.
- **Write-through models.** `LibraryModel`, `SettingsModel` and `AssignmentsModel` write to the store
  before they change in-memory state.

## Media and library

- **Bundled wallpapers** come from `Resources/Catalog.json` and `Samples/*.mov` in the app bundle.
  `LibraryModel.syncCatalog` upserts editorial fields and keeps usage data. Duration, resolution and
  codec are filled in by an asynchronous backfill on first launch.
- **Imports.** `MediaImporter` validates the extension and type, checks that the file exists and is
  readable, and confirms with AVFoundation that it is playable, has a video track and has a positive
  duration. It then reads metadata (oriented size, fps, codec FourCC, file size), rejects duplicates,
  creates a bookmark and, if enabled, copies the file into `Media/`.
- **File availability.** `MediaResolver` checks files without opening them. If an imported file is
  not at its recorded path, its bookmark is resolved. A file that was moved or renamed is updated in
  place; otherwise the item is reported missing or unreadable. Missing items are flagged in the UI,
  skipped by rotation and refused by `apply`.
- **Thumbnails.** `ThumbnailService` (an actor) extracts one frame with `AVAssetImageGenerator`
  (at most 640 px) into `Caches/Driftwall/Thumbnails`. At most 2 generations run at once, and duplicate
  requests share a task. `ThumbnailLoader` adds an `NSCache` limited to 300 images and 120 MB. Grid cells
  never open a video player: a hover preview starts one only after the pointer rests 450 ms, and
  releases it on exit.

## Display management

`DisplayService` builds `DisplayInfo` from `NSScreen` and CoreGraphics. Its fields are:

- `id`, the display UUID from `CGDisplayCreateUUIDFromDisplayID`, which is stable across reconnects;
- the transient `CGDirectDisplayID`;
- the frame, pixel size, scale, rotation, and the main and built-in flags.

The service observes `NSApplication.didChangeScreenParametersNotification`, debounced by 250 ms, and
also re-syncs after wake. `AppController.reconcileDesktop()` passes the connected displays, the stored
assignments and the mode to `DisplayAssignmentResolver`, then gives the result to the engine. A
reconnected display gets its wallpaper back. A changed resolution or orientation updates the surface's
frame.

## Rotation

`RotationCoordinator` owns a `RotationSequencer` and one `RotationScheduler`. The sequencer handles
sequential and shuffle order, skipping unavailable items, and true "previous" in shuffle mode. Each
`start` cancels the previous scheduler task and bumps a generation counter, so a late task can never
fire. The scheduler stops while the system is asleep, the displays are asleep, the screen is locked or
the session is inactive, and while rotation is paused. Manual next/previous restarts the countdown.
Rotation state, including the current item, is persisted in `AppSettings.rotation` and restored at launch.

## Application lifecycle

- `DriftwallApp` declares a `Window` (the main window), a `Settings` scene, and a `MenuBarExtra` in menu style.
- `AppDelegate.applicationDidFinishLaunching` calls `AppController.start()`. That loads the library,
  syncs the catalog, configures the engine, starts the system monitors, restores the wallpapers and
  rotation, and registers hot keys.
- Closing the window does not quit the app (`applicationShouldTerminateAfterLastWindowClosed` returns
  false). The Dock icon can be hidden; it reappears while the main window is visible.
- `applicationWillTerminate` calls `shutdown()`, which closes every surface and releases every decoder.
- The launch flags `--smoke-test` and `--ui-snapshots <dir>` are for development only. Both refuse to
  run unless `DRIFTWALL_DATA_DIR` is set.

## Search

`WallpaperSearchEngine` is the extension point. `KeywordSearchEngine` is local keyword matching, not
semantic search. It is case- and diacritic-insensitive. A query matches only if every token matches
a word prefix in the title, tags, category or description, or appears inside the title. Results are
ranked title > tags > category > description. A semantic engine (for example, one using on-device
embeddings) could implement the same protocol; none exists today.
