import AppKit
import DriftwallCore

/// Runs a shell command with administrator rights through AppleScript's `with administrator privileges`,
/// which shows macOS's standard authorization dialog naming Driftwall. Nothing is cached: every call asks.
struct AppleScriptPrivilegedRunner: PrivilegedRunner {
    func runAsAdministrator(_ shellCommand: String) async throws {
        let source = AerialCommandBuilder.appleScript(forShellCommand: shellCommand)
        let failure: (code: Int, message: String)? = await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return nil }
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            return (code, message)
        }.value
        if let failure {
            if failure.code == -128 { throw AerialError.cancelled }
            throw AerialError.privilegedStepFailed(failure.message)
        }
    }
}

enum AerialWallpaperSelection {
    /// Read-only check of the wallpaper store: is the given Aerial chosen as a *desktop* wallpaper
    /// (which is what macOS animates on the lock screen)? Returns nil when the store can't be read.
    static func isSelectedAsWallpaper(_ assetID: String) -> Bool? {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return search(root, assetID: assetID, inDesktop: false)
    }

    private static func search(_ value: Any, assetID: String, inDesktop: Bool, depth: Int = 0) -> Bool {
        guard depth < 24 else { return false }
        switch value {
        case let string as String:
            return inDesktop && string.caseInsensitiveCompare(assetID) == .orderedSame
        case let data as Data:
            guard inDesktop else { return false }
            if let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                return search(nested, assetID: assetID, inDesktop: true, depth: depth + 1)
            }
            return data.range(of: Data(assetID.utf8)) != nil
        case let dict as [String: Any]:
            return dict.contains { key, child in
                // "Idle" holds the screen saver; only "Desktop" choices are wallpapers.
                guard key != "Idle" else { return false }
                return search(child, assetID: assetID, inDesktop: inDesktop || key == "Desktop", depth: depth + 1)
            }
        case let array as [Any]:
            return array.contains { search($0, assetID: assetID, inDesktop: inDesktop, depth: depth + 1) }
        default:
            return false
        }
    }

    static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
