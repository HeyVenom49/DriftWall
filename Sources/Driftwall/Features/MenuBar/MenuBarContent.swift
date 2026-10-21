import DriftwallCore
import SwiftUI

/// Native menu shown from the menu-bar icon.
struct MenuBarContent: View {
    @Environment(AppController.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let current = app.currentWallpaper {
            Text("On Your Desktop: \(current.title)")
            if let reason = PauseReason.allCases.first(where: app.engine.pauseReasons.contains) {
                Text("Paused — \(reason.label)")
            }
        } else {
            Text("No live wallpaper")
        }
        Divider()

        Button(app.settings.userPaused ? "Resume" : "Pause") { app.togglePlayback() }
            .disabled(!app.engine.hasActiveWallpaper)
        Button("Next Wallpaper") { app.nextWallpaper() }
        Button("Previous Wallpaper") { app.previousWallpaper() }

        Divider()

        Menu("Recent") {
            let recent = app.library.recentWallpapers(limit: 10, kind: .applied)
            if recent.isEmpty { Text("Nothing yet") }
            ForEach(recent, id: \.wallpaper.id) { item in
                Button(item.wallpaper.title) { app.apply(item.wallpaper.id) }
                    .disabled(!app.library.isAvailable(item.wallpaper.id))
            }
        }
        Menu("Favorites") {
            let favorites = app.library.favoriteWallpapers
            if favorites.isEmpty { Text("No favorites yet") }
            ForEach(favorites) { wallpaper in
                Button(wallpaper.title) { app.apply(wallpaper.id) }
                    .disabled(!app.library.isAvailable(wallpaper.id))
            }
        }
        Menu("Playlists") {
            if app.library.playlists.isEmpty { Text("No playlists yet") }
            ForEach(app.library.playlists) { playlist in
                let active = app.rotation.isActive && app.rotation.settings.playlistID == playlist.id
                Toggle(playlist.name, isOn: Binding(get: { active }, set: { on in
                    if on { app.startPlaylist(playlist.id) } else { app.rotation.stop() }
                }))
                    .disabled(playlist.itemIDs.isEmpty)
            }
            if app.rotation.isActive {
                Divider()
                Button(app.rotation.settings.isPaused ? "Resume Rotation" : "Pause Rotation") {
                    app.rotation.setPaused(!app.rotation.settings.isPaused)
                }
                Button("Stop Rotation") { app.rotation.stop() }
            }
        }

        if app.isLockScreenReady {
            Divider()
            Button("Lock Screen Now") { app.lockNow() }
        }
        Divider()
        Button("Stop Live Wallpaper") { app.clearAllWallpapers() }
            .disabled(!app.engine.hasActiveWallpaper)
        Divider()

        Button("Open Driftwall") {
            WindowOpener.openWindowAction = openWindow
            WindowOpener.openMain()
        }
        .keyboardShortcut("o")
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Driftwall") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
