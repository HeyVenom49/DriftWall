import AppKit
import DriftwallCore

/// Real `LockScreenSystem`: installs the bundled screen-saver module into `~/Library/Screen Savers`
/// (the documented per-user location), reads which screen saver is selected (read-only, best effort),
/// and sets the still system picture with `NSWorkspace`. It never writes system preferences or
/// protected files: the user picks the screen saver in System Settings.
@MainActor
final class MacLockScreenSystem: LockScreenSystem {
    static let saverName = "Driftwall.saver"

    var screenSaverFrameworkPresent: Bool {
        FileManager.default.fileExists(atPath: "/System/Library/Frameworks/ScreenSaver.framework")
    }

    var osVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    private var bundledSaverURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(Self.saverName)
    }

    var installedSaverURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/\(Self.saverName)")
    }

    var isSaverInstalled: Bool {
        guard let installed = Bundle(url: installedSaverURL)?.infoDictionary?["CFBundleVersion"] as? String else { return false }
        // Up to date only if it matches the module shipped in this build.
        let bundled = bundledSaverURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleVersion"] as? String }
        return bundled == nil || bundled == installed
    }

    func installSaver() throws {
        guard let source = bundledSaverURL, FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The screen-saver module is missing from Driftwall.app. Rebuild the app."])
        }
        let fm = FileManager.default
        let folder = installedSaverURL.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".Driftwall-\(UUID().uuidString).saver")
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: installedSaverURL.path) {
            _ = try fm.replaceItemAt(installedSaverURL, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: installedSaverURL)
        }
    }

    func uninstallSaver() throws {
        if FileManager.default.fileExists(atPath: installedSaverURL.path) {
            try FileManager.default.trashItem(at: installedSaverURL, resultingItemURL: nil)
        }
    }

    /// Reads the system wallpaper store (read-only). The format is not documented, so anything unexpected
    /// yields `.unknown` rather than a guess.
    func screenSaverSelection() -> ScreenSaverSelection {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return .unknown }
        var sawIdleSection = false
        let found = Self.containsDriftwall(root, sawIdle: &sawIdleSection)
        if found { return .selected }
        return sawIdleSection ? .notSelected : .unknown
    }

    private static func containsDriftwall(_ value: Any, sawIdle: inout Bool, depth: Int = 0) -> Bool {
        guard depth < 24 else { return false }
        switch value {
        case let string as String:
            return string.contains(saverName) || string.contains("local.driftwall.saver")
        case let data as Data:
            if let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                return containsDriftwall(nested, sawIdle: &sawIdle, depth: depth + 1)
            }
            return data.range(of: Data(saverName.utf8)) != nil
        case let dict as [String: Any]:
            if dict["Idle"] != nil { sawIdle = true }
            return dict.values.contains { containsDriftwall($0, sawIdle: &sawIdle, depth: depth + 1) }
        case let array as [Any]:
            return array.contains { containsDriftwall($0, sawIdle: &sawIdle, depth: depth + 1) }
        default:
            return false
        }
    }

    func setStillSystemPicture(_ imageURL: URL) throws {
        for screen in NSScreen.screens {
            try SystemWallpaperService.setStaticWallpaper(imageURL, on: screen)
        }
    }

    // MARK: - User-facing helpers (not part of the testable protocol)

    static func openScreenSaverSettings() {
        open("x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")
    }

    static func openLockScreenSettings() {
        open("x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
    }

    /// Starts the currently selected screen saver now, the same as a hot corner would.
    static func startScreenSaver() {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Reads the password delay with `sysadminctl -screenLock status` (read-only). nil when unknown.
    static func passwordDelayDescription() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
            process.arguments = ["-screenLock", "status"]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let range = text.range(of: "screenLock ") else { return nil }
            return text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
