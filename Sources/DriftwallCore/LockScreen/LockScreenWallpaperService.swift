import Foundation
import Observation

public enum LockScreenError: LocalizedError, Equatable {
    case unsupported(String)
    case incompatibleMedia(String)
    case mediaUnavailable(String)
    case writeFailed(String)
    case verificationFailed
    case saverInstallFailed(String)
    case stillPictureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let why): return "Lock-screen video isn’t available on this Mac: \(why)"
        case .incompatibleMedia(let why): return why
        case .mediaUnavailable(let title): return "The video for “\(title)” can’t be found. Relink it in My Videos and try again."
        case .writeFailed(let detail): return "Driftwall couldn’t save the lock-screen video: \(detail). Check that your disk has free space."
        case .verificationFailed: return "The lock-screen configuration was written but could not be read back. Try again."
        case .saverInstallFailed(let detail): return "The Driftwall screen saver couldn’t be installed: \(detail)"
        case .stillPictureFailed(let detail): return "The video was applied, but the still system picture couldn’t be set: \(detail)"
        }
    }
}

/// System operations the lock-screen service needs. The app provides the real implementation
/// (screen-saver install, System Settings, NSWorkspace); tests provide a fake.
@MainActor
public protocol LockScreenSystem: AnyObject {
    var screenSaverFrameworkPresent: Bool { get }
    var osVersion: OperatingSystemVersion { get }
    /// Whether the Driftwall screen-saver module is installed and up to date.
    var isSaverInstalled: Bool { get }
    func installSaver() throws
    func uninstallSaver() throws
    /// Best-effort read of the current screen-saver choice.
    func screenSaverSelection() -> ScreenSaverSelection
    /// Sets the macOS system picture (shown behind the login/password UI) on every display.
    func setStillSystemPicture(_ imageURL: URL) throws
}

/// Applies and reports the lock-screen wallpaper. Independent of the desktop playback engine and of SwiftUI.
///
/// Mechanism: the chosen video is copied (APFS clone, so normally no extra disk space) into
/// `<support>/LockScreen/Media/` and described in `<support>/LockScreen/config.json`. The Driftwall
/// screen-saver module reads that file and plays the video while the screen saver runs, which on a Mac
/// that requires the password immediately is whenever the Mac is locked.
@MainActor
@Observable
public final class LockScreenWallpaperService {
    public private(set) var status: LockScreenStatus = .disabled
    public private(set) var config: LockScreenConfig?
    public private(set) var capabilities: LockScreenCapabilities
    public private(set) var saverSelection: ScreenSaverSelection = .unknown
    public private(set) var isSaverInstalled = false
    public private(set) var isApplying = false

    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let system: LockScreenSystem
    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let now: () -> Date

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var mediaDirectory: URL { directory.appendingPathComponent("Media", isDirectory: true) }

    public init(directory: URL, system: LockScreenSystem, log: DiagnosticsLog = .shared, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.system = system
        self.log = log
        self.now = now
        capabilities = .evaluate(osVersion: system.osVersion, screenSaverFrameworkPresent: system.screenSaverFrameworkPresent)
        config = Self.readConfig(at: directory.appendingPathComponent("config.json"))
    }

    public var isSupported: Bool { capabilities.videoWhileLocked.isSupported }

    /// Re-reads system state and recomputes `status` for the given settings.
    public func refresh(settings: LockScreenSettings, targetWallpaperTitle: String?) {
        capabilities = .evaluate(osVersion: system.osVersion, screenSaverFrameworkPresent: system.screenSaverFrameworkPresent)
        isSaverInstalled = system.isSaverInstalled
        saverSelection = isSaverInstalled ? system.screenSaverSelection() : .notSelected
        config = Self.readConfig(at: configURL)

        guard settings.isEnabled else { status = .disabled; return }
        guard isSupported else { status = .unsupported(capabilities.videoWhileLocked.detail); return }
        guard let config, FileManager.default.fileExists(atPath: config.mediaPath) else {
            status = targetWallpaperTitle == nil ? .nothingSelected : .needsSetup("Press Apply to prepare the lock-screen video.")
            return
        }
        if !isSaverInstalled {
            status = .needsSetup("Install the Driftwall screen saver to finish setup.")
        } else {
            switch saverSelection {
            case .selected:
                status = .active(title: config.title)
            case .notSelected:
                status = .needsSetup("Select “Driftwall” in System Settings › Screen Saver to finish setup.")
            case .unknown:
                // Never claim success for something that could not be checked.
                status = .needsSetup("Video prepared. Make sure “Driftwall” is selected in System Settings › Screen Saver.")
            }
        }
    }

    /// Copies the video into the lock-screen folder, writes the config atomically and reads it back.
    /// Only returns successfully when the saver will find a complete, valid configuration.
    @discardableResult
    public func apply(_ wallpaper: Wallpaper, mediaURL: URL?, availability: MediaAvailability, gravity: VideoGravity) throws -> LockScreenConfig {
        guard isSupported else { throw LockScreenError.unsupported(capabilities.videoWhileLocked.detail) }
        let compatibility = LockScreenMediaCompatibility.evaluate(wallpaper, availability: availability)
        guard compatibility.isUsable else { throw LockScreenError.incompatibleMedia(compatibility.message) }
        guard let mediaURL, FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw LockScreenError.mediaUnavailable(wallpaper.title)
        }
        isApplying = true
        defer { isApplying = false }

        let fm = FileManager.default
        let ext = mediaURL.pathExtension.lowercased()
        let destination = mediaDirectory.appendingPathComponent("\(Self.safeName(wallpaper.id)).\(ext)")
        do {
            try fm.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            if config?.mediaPath != destination.path || !fm.fileExists(atPath: destination.path) || Self.size(of: destination) != Self.size(of: mediaURL) {
                let temp = mediaDirectory.appendingPathComponent(".incoming-\(UUID().uuidString).\(ext)")
                try fm.copyItem(at: mediaURL, to: temp) // clonefile on APFS
                _ = try? fm.removeItem(at: destination)
                try fm.moveItem(at: temp, to: destination)
            }
            let newConfig = LockScreenConfig(wallpaperID: wallpaper.id, title: wallpaper.title, mediaPath: destination.path,
                                             gravity: gravity, appliedAt: now())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(newConfig).write(to: configURL, options: .atomic)
            // Remove media from earlier selections so the folder never grows.
            for file in (try? fm.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent != destination.lastPathComponent {
                try? fm.removeItem(at: file)
            }
        } catch {
            log.log(.error, "lockscreen", "Apply failed: \(error.localizedDescription)")
            throw LockScreenError.writeFailed(error.localizedDescription)
        }

        guard let readBack = Self.readConfig(at: configURL), readBack.wallpaperID == wallpaper.id,
              fm.fileExists(atPath: readBack.mediaPath) else {
            throw LockScreenError.verificationFailed
        }
        config = readBack
        log.log(.info, "lockscreen", "Lock-screen video set to “\(wallpaper.title)”")
        return readBack
    }

    /// Removes the configuration and copied media. The screen saver then shows a short instruction instead of video.
    public func clear() {
        try? FileManager.default.removeItem(at: configURL)
        try? FileManager.default.removeItem(at: mediaDirectory)
        config = nil
        log.log(.info, "lockscreen", "Lock-screen video cleared")
    }

    public func installSaver() throws {
        do {
            try system.installSaver()
            isSaverInstalled = system.isSaverInstalled
            log.log(.info, "lockscreen", "Screen-saver module installed")
        } catch {
            log.log(.error, "lockscreen", "Screen-saver install failed: \(error.localizedDescription)")
            throw LockScreenError.saverInstallFailed(error.localizedDescription)
        }
    }

    public func uninstallSaver() throws {
        try system.uninstallSaver()
        isSaverInstalled = system.isSaverInstalled
    }

    public func setStillSystemPicture(_ imageURL: URL) throws {
        do {
            try system.setStillSystemPicture(imageURL)
        } catch {
            throw LockScreenError.stillPictureFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    public static func readConfig(at url: URL) -> LockScreenConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let config = try? decoder.decode(LockScreenConfig.self, from: data), config.version <= LockScreenConfig.currentVersion else { return nil }
        return config
    }

    static func safeName(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? String($0) : "_" }.joined()
    }

    static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }
}
