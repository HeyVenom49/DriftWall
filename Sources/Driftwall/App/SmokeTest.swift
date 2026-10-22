import AppKit
import DriftwallCore

/// End-to-end check run inside the real, packaged app: `Driftwall.app/Contents/MacOS/Driftwall --smoke-test`
/// with `DRIFTWALL_DATA_DIR` pointing at a scratch folder. It drives the same `AppController` actions the UI
/// uses (no simulated clicks) and exercises real AVFoundation playback on the real displays.
/// This is not a substitute for UI tests; it verifies the integration of services in the packaged bundle.
@MainActor
enum SmokeTest {
    private static var failures: [String] = []
    private static var passes = 0

    static func run(_ app: AppController) {
        guard ProcessInfo.processInfo.environment["DRIFTWALL_DATA_DIR"] != nil else {
            print("SMOKE: refusing to run without DRIFTWALL_DATA_DIR (would touch real user data)")
            exit(2)
        }
        Task {
            await execute(app)
            app.clearAllWallpapers()
            app.shutdown()
            print("SMOKE: \(passes) passed, \(failures.count) failed")
            failures.forEach { print("SMOKE FAIL: \($0)") }
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            passes += 1
            print("SMOKE ok   \(name)")
        } else {
            failures.append(name)
            print("SMOKE FAIL \(name)")
        }
    }

    /// Non-autoclosure variant so the condition can be computed with `await`.
    private static func expect(_ value: Bool, _ name: String) {
        check(value, name)
    }

    private static func wait(_ seconds: Double = 8, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func execute(_ app: AppController) async {
        app.start()
        let library = app.library
        check(library.wallpapers.count >= 8, "bundled catalog loaded (\(library.wallpapers.count) wallpapers)")
        check(library.missingWallpapers.isEmpty, "all bundled media files present")
        check(!library.collections.isEmpty, "curated collections loaded")
        expect(await wait { library.wallpapers.allSatisfy(\.hasMetadata) }, "metadata extracted for every wallpaper")

        // Thumbnails
        guard let sample = library.wallpaper("sample.aurora-drift") else {
            check(false, "sample.aurora-drift exists")
            return
        }
        let image = await app.thumbnailLoader.image(for: sample, mediaURL: library.mediaURL(for: sample.id))
        check(image != nil, "thumbnail generated")
        check(FileManager.default.fileExists(atPath: app.thumbnails.thumbnailURL(for: sample.id).path), "thumbnail cached on disk")
        app.thumbnailLoader.clearMemory()
        async let first = app.thumbnailLoader.image(for: sample, mediaURL: library.mediaURL(for: sample.id))
        async let second = app.thumbnailLoader.image(for: sample, mediaURL: library.mediaURL(for: sample.id))
        let (a, b) = await (first, second)
        check(a != nil && a === b, "concurrent thumbnail requests share one load")

        // Search
        check(library.search(SearchQuery(text: "auro")).first?.id == sample.id, "prefix search finds Aurora")
        check(library.search(SearchQuery(text: "zzzz")).isEmpty, "nonsense search returns nothing")

        // Apply + playback on every connected display
        let displayCount = app.displays.displays.count
        print("SMOKE info displays connected: \(displayCount) — \(app.displays.displays.map(\.name).joined(separator: ", "))")
        app.apply(sample.id, target: .allDisplays)
        check(app.engine.surfaceStates.count == displayCount, "a surface per display (\(app.engine.surfaceStates.count)/\(displayCount))")
        expect(await wait { app.engine.surfaceStates.values.allSatisfy { $0.status == .playing } }, "video playing on all displays")
        check(app.engine.activePlayerCount == 1, "same wallpaper shares one decoder (\(app.engine.activePlayerCount))")
        check(app.currentWallpaper?.id == sample.id, "current wallpaper reported")
        check(library.recentWallpapers(kind: .applied).first?.wallpaper.id == sample.id, "applied wallpaper recorded in history")

        app.togglePlayback()
        expect(await wait { app.engine.surfaceStates.values.allSatisfy { if case .paused = $0.status { return true } else { return false } } }, "user pause pauses playback")
        app.togglePlayback()
        expect(await wait { app.engine.surfaceStates.values.allSatisfy { $0.status == .playing } }, "resume restarts playback")

        if displayCount > 1, let second = app.displays.displays.first(where: { !$0.isMain }) {
            app.apply("sample.neon-grid", target: .display(id: second.id))
            check(app.settings.displayMode == .perDisplay, "per-display mode after targeting one display")
            expect(await wait { app.engine.surfaceStates[second.id]?.wallpaperID == "sample.neon-grid" && app.engine.surfaceStates[second.id]?.status == .playing }, "second display plays its own wallpaper")
            check(app.engine.activePlayerCount == 2, "two decoders for two different wallpapers")
            // Next/Previous without a playlist change only the display under the pointer.
            if let active = app.activeDisplay, let other = app.displays.displays.first(where: { $0.id != active.id }) {
                let activeBefore = app.engine.surfaceStates[active.id]?.wallpaperID
                let otherBefore = app.engine.surfaceStates[other.id]?.wallpaperID
                app.nextWallpaper()
                expect(await wait { app.engine.surfaceStates[active.id]?.wallpaperID != activeBefore }, "next changes the display under the pointer")
                check(app.engine.surfaceStates[other.id]?.wallpaperID == otherBefore, "next leaves the other display unchanged")
            }
            app.settings.displayMode = .mirror
            expect(await wait { Set(app.engine.surfaceStates.values.map(\.wallpaperID)).count == 1 }, "mirror mode shows one wallpaper everywhere")
            app.settings.displayMode = .perDisplay
            check(PlaybackDiagnostics.live[.desktop] == Set(app.engine.surfaceStates.values.map(\.wallpaperID)).count,
                  "replaced decoders are released (\(PlaybackDiagnostics.summary))")
        } else {
            print("SMOKE info single display: per-display assignment not exercised")
        }

        // In-window preview: holds its decoder while its window can't be seen, keeps the user's choice.
        if let url = library.mediaURL(for: "sample.neon-grid") {
            let previewsBefore = PlaybackDiagnostics.live[.preview, default: 0]
            let preview = PreviewPlayer()
            preview.load(url)
            expect(await wait { (preview.player?.rate ?? 0) > 0 }, "preview plays")
            preview.setVisible(false)
            check(preview.player?.rate == 0 && preview.isPlaying && preview.isSuspended, "hidden preview stops decoding but stays 'playing'")
            preview.setVisible(true)
            check((preview.player?.rate ?? 0) > 0 && !preview.isSuspended, "preview resumes when visible again")
            preview.pause()
            preview.setVisible(false)
            preview.setVisible(true)
            check(preview.player?.rate == 0 && !preview.isPlaying, "a preview paused by the user stays paused after hiding")
            preview.stop()
            check(preview.player == nil && PlaybackDiagnostics.live[.preview, default: 0] == previewsBefore, "stopped preview releases its decoder")

            // Only the newest preview decodes; the older one resumes when it ends.
            let page = PreviewPlayer(), hover = PreviewPlayer()
            page.load(url)
            expect(await wait { (page.player?.rate ?? 0) > 0 }, "page preview plays")
            if let other = library.mediaURL(for: "sample.deep-tide") { hover.load(other) }
            expect(await wait { (hover.player?.rate ?? 0) > 0 }, "hover preview plays")
            check(page.player?.rate == 0 && page.isPlaying && page.isSuspended, "older preview is held while a newer one plays")
            hover.stop()
            check((page.player?.rate ?? 0) > 0 && !page.isSuspended, "older preview resumes when the newer one stops")
            page.pause()
            hover.load(url)
            hover.stop()
            check(page.player?.rate == 0 && !page.isPlaying, "a paused preview isn't resumed by another one ending")
            page.stop()
        }

        // Favorites and playlists
        library.setFavorite(sample.id, true)
        check(library.isFavorite(sample.id), "favorite added")
        let playlist = library.createPlaylist(named: "Smoke", items: ["sample.deep-tide", "sample.ember-dusk", "sample.silk-mono"])
        check(playlist != nil, "playlist created")
        if let playlist {
            app.startPlaylist(playlist.id)
            check(app.rotation.isActive && app.rotation.settings.currentWallpaperID == "sample.deep-tide", "rotation starts at first item")
            check(app.rotation.nextChange != nil, "rotation scheduled")
            app.nextWallpaper()
            check(app.rotation.settings.currentWallpaperID == "sample.ember-dusk", "next advances playlist")
            expect(await wait { app.currentWallpaper?.id == "sample.ember-dusk" }, "rotation applied wallpaper to desktop")
            if let main = app.displays.displays.first(where: \.isMain), let second = app.displays.displays.first(where: { !$0.isMain }) {
                app.rotation.setTargetDisplay(second.id)
                let mainBefore = app.engine.surfaceStates[main.id]?.wallpaperID
                app.nextWallpaper()
                expect(await wait { app.engine.surfaceStates[second.id]?.wallpaperID == app.rotation.settings.currentWallpaperID }, "rotation targeted at one display changes it")
                check(app.engine.surfaceStates[main.id]?.wallpaperID == mainBefore, "rotation targeted at one display leaves the others alone")
                app.rotation.setTargetDisplay(nil)
            }
            app.rotation.stop()
            check(!app.rotation.isActive && app.rotation.nextChange == nil, "rotation stops cleanly")
        }

        // Import: a valid video from outside the library, and an invalid file.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("driftwall-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let external = scratch.appendingPathComponent("my_holiday-clip.mov")
        let bogus = scratch.appendingPathComponent("notes.txt")
        if let source = library.mediaURL(for: "sample.rain-lights") { try? FileManager.default.copyItem(at: source, to: external) }
        try? "not a video".write(to: bogus, atomically: true, encoding: .utf8)
        await app.importFiles([external, bogus])
        let imported = library.importedWallpapers.first { $0.mediaPath == external.path }
        check(imported != nil, "valid video imported")
        check(imported?.title == "My Holiday Clip", "imported title derived from file name")
        check(app.importReport?.failures.count == 1, "invalid file reported as failure")
        await app.importFiles([external])
        check(library.importedWallpapers.filter { $0.mediaPath == external.path }.count == 1, "duplicate import rejected")

        if let imported {
            // Move the file: the bookmark should follow it.
            let moved = scratch.appendingPathComponent("renamed.mov")
            try? FileManager.default.moveItem(at: external, to: moved)
            library.refreshAvailability()
            let relocated = library.wallpaper(imported.id).map { URL(fileURLWithPath: $0.mediaPath).resolvingSymlinksInPath().path }
            check(relocated == moved.resolvingSymlinksInPath().path, "moved file relocated through bookmark")
            // Delete the file: the item must be reported missing and applying must be refused.
            try? FileManager.default.removeItem(at: moved)
            library.refreshAvailability()
            check(!library.isAvailable(imported.id), "deleted file reported missing")
            app.apply(imported.id)
            check(app.currentWallpaper?.id != imported.id, "missing media is not applied")
            app.removeWallpaper(imported.id)
            check(library.wallpaper(imported.id) == nil, "imported item removed")
        }
        // Removing a referenced import must never delete the original.
        let keep = scratch.appendingPathComponent("keep.mov")
        if let source = library.mediaURL(for: "sample.citrus-haze") { try? FileManager.default.copyItem(at: source, to: keep) }
        await app.importFiles([keep])
        if let item = library.importedWallpapers.first(where: { $0.mediaPath == keep.path }) {
            app.removeWallpaper(item.id)
            check(FileManager.default.fileExists(atPath: keep.path), "original file kept after removal")
        } else {
            check(false, "second import for removal test")
        }

        // Lock screen (scratch folder only: the saver is not installed and the system picture is not changed).
        let bundledSaver = Bundle.main.resourceURL?.appendingPathComponent("Driftwall.saver")
        check(bundledSaver.flatMap { Bundle(url: $0)?.infoDictionary?["NSPrincipalClass"] as? String } == "DriftwallSaverView", "screen-saver module bundled in the app")
        check(app.lockScreen.capabilities.videoWhileLocked.isSupported, "lock-screen video supported on this macOS")
        app.apply(sample.id, target: .allDisplays)
        app.settings.lockScreen.isEnabled = true
        app.settings.lockScreen.useDesktopWallpaper = true
        expect(await app.applyLockScreen(quiet: true), "lock screen applied (same as desktop)")
        check(app.lockScreen.config?.wallpaperID == sample.id, "lock screen follows desktop wallpaper")
        app.apply("sample.deep-tide", target: .allDisplays)
        expect(await wait { app.lockScreen.config?.wallpaperID == "sample.deep-tide" }, "lock screen updates when the desktop changes")
        app.chooseLockScreenWallpaper("sample.nebula-bloom", useDesktop: false)
        expect(await app.applyLockScreen(quiet: true), "independent lock-screen wallpaper applied")
        app.apply(sample.id, target: .allDisplays)
        try? await Task.sleep(for: .milliseconds(300))
        check(app.lockScreen.config?.wallpaperID == "sample.nebula-bloom", "independent lock screen ignores desktop changes")
        check(app.lockScreen.config.map { FileManager.default.fileExists(atPath: $0.mediaPath) } == true, "lock-screen video copied")
        app.setLockScreenEnabled(false)
        check(app.lockScreen.config == nil, "disabling clears the lock-screen video")

        // Settings persistence through a fresh store on the same database file.
        app.settings.videoGravity = .fit
        if let reopened = try? SQLiteLibraryStore.open(at: app.paths.databaseURL).store {
            check((try? reopened.loadSettings().videoGravity) == .fit, "settings persisted to disk")
            check((try? reopened.favorites().map(\.0).contains(sample.id)) == true, "favorites persisted to disk")
            check((try? reopened.playlists().contains { $0.name == "Smoke" }) == true, "playlists persisted to disk")
        } else {
            check(false, "database reopened")
        }

        app.clearAllWallpapers()
        check(PlaybackDiagnostics.live[.desktop, default: 0] == 0 && app.engine.activePlayerCount == 0, "clearing the wallpaper releases every decoder")

        // Cache management
        await app.clearThumbnailCache()
        check(!FileManager.default.fileExists(atPath: app.thumbnails.thumbnailURL(for: sample.id).path), "cache cleared")

        try? FileManager.default.removeItem(at: scratch)
    }
}
