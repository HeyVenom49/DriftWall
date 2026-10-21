import AppKit
import DriftwallCore

/// Developer tool: `Driftwall --ui-snapshots <dir>` (with `DRIFTWALL_DATA_DIR` set) walks through the main
/// screens and writes PNGs of the main window's view hierarchy. The app renders its own views, so no
/// Screen Recording permission is needed. Video layers do not render into these images; thumbnails do.
@MainActor
enum UISnapshots {
    static func run(_ app: AppController, outputDirectory: URL) {
        guard ProcessInfo.processInfo.environment["DRIFTWALL_DATA_DIR"] != nil else {
            print("SNAPSHOTS: refusing to run without DRIFTWALL_DATA_DIR")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        Task {
            app.start()
            app.settings.hasCompletedOnboarding = true
            app.settings.hoverPreviews = false
            // Some state so screens are populated.
            app.library.setFavorite("sample.aurora-drift", true)
            app.library.setFavorite("sample.neon-grid", true)
            app.library.setFavorite("sample.nebula-bloom", true)
            if let playlist = app.library.createPlaylist(named: "Evening Calm", items: ["sample.deep-tide", "sample.aurora-drift", "sample.silk-mono"]) {
                app.apply("sample.ember-dusk")
                app.apply("sample.aurora-drift")
                // Prepare the lock screen without installing the saver (scratch data folder only).
                app.settings.lockScreen.isEnabled = true
                await app.applyLockScreen(quiet: true)
                try? await Task.sleep(for: .seconds(2))
                let screens: [(String, SidebarItem)] = [
                    ("home", .home), ("explore", .explore), ("favorites", .favorites), ("recent", .recent),
                    ("library", .library), ("displays", .displays), ("lockscreen", .lockScreen), ("playlists", .playlists),
                    ("playlist", .playlist(playlist.id)),
                ]
                for (name, item) in screens {
                    app.navigation.show(item)
                    try? await Task.sleep(for: .seconds(1.5))
                    capture(name, to: outputDirectory)
                }
                app.navigation.query = SearchQuery(text: "night")
                app.navigation.show(.explore)
                try? await Task.sleep(for: .seconds(1.5))
                capture("search", to: outputDirectory)
                app.navigation.query = SearchQuery(text: "qwerty")
                try? await Task.sleep(for: .seconds(1))
                capture("no-results", to: outputDirectory)
                app.navigation.renamePlaylist(playlist)
                try? await Task.sleep(for: .seconds(1))
                capture("rename-playlist", to: outputDirectory)
                app.navigation.playlistNameRequest = nil
                try? await Task.sleep(for: .seconds(0.5))
                app.navigation.query = SearchQuery()
                app.navigation.show(.home)
                app.navigation.open("sample.neon-grid")
                try? await Task.sleep(for: .seconds(2))
                capture("detail", to: outputDirectory)
            }
            app.clearAllWallpapers()
            app.shutdown()
            exit(0)
        }
    }

    private static func capture(_ name: String, to directory: URL) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 800 }),
              let window = Optional(main.attachedSheet ?? main),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("SNAPSHOTS: no window for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("SNAPSHOTS: wrote \(url.path)")
    }
}
