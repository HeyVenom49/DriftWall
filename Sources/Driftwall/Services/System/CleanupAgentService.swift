import Foundation
import DriftwallCore

/// Installs or removes the cleanup task (see `CleanupAgent`) in `~/Library/LaunchAgents`. It is only
/// installed while Driftwall has changed something outside its own folders, and it is rewritten on every
/// launch so it always knows where the app currently is.
@MainActor
enum CleanupAgentService {
    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.driftwall.cleanup.plist")
    }

    /// Whether the cleanup task is installed.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    static func agent(paths: AppPaths, aerialVideoDirectory: URL, screenSaverPath: URL) -> CleanupAgent {
        CleanupAgent(appPath: originalAppURL(Bundle.main.bundleURL).path,
                     bundleIdentifier: Bundle.main.bundleIdentifier ?? "local.driftwall.app",
                     supportDirectory: paths.supportDirectory,
                     aerialVideoDirectory: aerialVideoDirectory,
                     screenSaverPath: screenSaverPath,
                     launchAgentPath: launchAgentURL)
    }

    /// Where the app really is. A quarantined app opened from Finder runs from a randomized, temporary
    /// App Translocation mount; that path vanishes when the app quits, so the cleanup task must record
    /// the original instead. `SecTranslocateCreateOriginalPathForURL` is exported by Security.framework
    /// but has no public header, so it is looked up at run time; if it's unavailable the path is kept.
    static func originalAppURL(_ url: URL) -> URL {
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let createOriginal = unsafeBitCast(symbol, to: CreateOriginal.self)
        return createOriginal(url as CFURL, nil).map { $0.takeRetainedValue() as URL } ?? url
    }

    /// What was last applied in this run of the app, so frequent refreshes cost nothing.
    private static var lastApplied: Bool?

    /// Installs the task when `needed`, removes it otherwise. Never runs against a scratch data folder
    /// (`DRIFTWALL_DATA_DIR`, used by tests), where it would point at files that aren't the user's.
    static func update(needed: Bool, agent: CleanupAgent, log: DiagnosticsLog = .shared) {
        guard ProcessInfo.processInfo.environment["DRIFTWALL_DATA_DIR"] == nil else { return }
        guard lastApplied != needed else { return }
        lastApplied = needed
        do {
            if needed {
                try install(agent)
            } else if isInstalled {
                remove(agent)
                log.log(.info, "cleanup", "Removed the cleanup task: Driftwall has no system changes in place")
            }
        } catch {
            log.log(.error, "cleanup", "Couldn’t install the cleanup task: \(error.localizedDescription)")
        }
    }

    private static func install(_ agent: CleanupAgent) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: agent.scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: agent.launchAgentPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(agent.script().utf8).write(to: agent.scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.scriptURL.path)
        try Data(CleanupAgent.desktopRestoreScript.utf8).write(to: agent.desktopScriptURL, options: .atomic)

        let plist = try agent.launchAgentPlist()
        let unchanged = (try? Data(contentsOf: agent.launchAgentPath)) == plist
        if unchanged && isLoaded(agent.label) { return }
        try plist.write(to: agent.launchAgentPath, options: .atomic)
        launchctl(["bootout", "gui/\(getuid())/\(agent.label)"])
        launchctl(["bootstrap", "gui/\(getuid())", agent.launchAgentPath.path])
        DiagnosticsLog.shared.log(.info, "cleanup", "Installed the cleanup task for \(agent.appPath)")
    }

    private static func remove(_ agent: CleanupAgent) {
        launchctl(["bootout", "gui/\(getuid())/\(agent.label)"])
        let fm = FileManager.default
        for url in [agent.launchAgentPath, agent.scriptURL, agent.desktopScriptURL] {
            try? fm.removeItem(at: url)
        }
    }

    private static func isLoaded(_ label: String) -> Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
