import AppKit
import DriftwallCore

/// Restarts macOS's wallpaper agent and Aerial extension (launchd starts them again right away) so
/// they load the replaced Aerial video instead of the copy they already have in memory.
struct KillallWallpaperReloader: AerialWallpaperReloader {
    func reload() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAerialsExtension", "WallpaperAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DiagnosticsLog.shared.log(.warning, "aerial", "Couldn’t restart the wallpaper processes: \(error.localizedDescription)")
        }
    }
}

enum AerialWallpaperSelection {
    static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
