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
    /// The Space each display shows now (read-only, from the `com.apple.spaces` preferences). Wallpaper
    /// choices can be per Space, so this decides which choice is on screen.
    static func currentSpaces(mainDisplayID: String?) -> [String: String] {
        guard let configuration = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString) else { return [:] }
        return AerialWallpaperStore.currentSpaces(inSpacesPreferences: configuration, mainDisplayID: mainDisplayID)
    }

    static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
