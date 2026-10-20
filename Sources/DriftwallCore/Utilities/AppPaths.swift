import Foundation

/// File-system locations used by the app. Everything lives under the user's Application Support
/// and Caches folders; nothing is written next to user media.
public struct AppPaths: Sendable {
    public var supportDirectory: URL
    public var cacheDirectory: URL

    public init(supportDirectory: URL, cacheDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.cacheDirectory = cacheDirectory
    }

    /// Standard locations. `DRIFTWALL_DATA_DIR` overrides both roots (used by the smoke test and for debugging).
    public static func standard(appName: String = "Driftwall", environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment["DRIFTWALL_DATA_DIR"], !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            return AppPaths(supportDirectory: root.appendingPathComponent("Support"), cacheDirectory: root.appendingPathComponent("Caches"))
        }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return AppPaths(supportDirectory: support.appendingPathComponent(appName, isDirectory: true),
                        cacheDirectory: caches.appendingPathComponent(appName, isDirectory: true))
    }

    public var databaseURL: URL { supportDirectory.appendingPathComponent("Library.sqlite") }
    /// Copies of imported videos when "Copy imported videos into library" is enabled. Files here are owned by the app.
    public var mediaDirectory: URL { supportDirectory.appendingPathComponent("Media", isDirectory: true) }

    public func createDirectories() throws {
        for dir in [supportDirectory, cacheDirectory, mediaDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
