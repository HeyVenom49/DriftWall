import Foundation

/// Persisted lock-screen preferences (part of `AppSettings`).
public struct LockScreenSettings: Codable, Equatable, Sendable {
    public var isEnabled = false
    /// When true the lock screen follows the wallpaper on the main display's desktop.
    public var useDesktopWallpaper = true
    /// The wallpaper chosen for the lock screen when `useDesktopWallpaper` is false.
    public var wallpaperID: WallpaperID?
    /// Also set a still frame of the lock-screen video as the macOS system picture, which the login and
    /// password screens display. The system picture is shared with the desktop.
    public var setsStillSystemPicture = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case isEnabled, useDesktopWallpaper, wallpaperID, setsStillSystemPicture }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        useDesktopWallpaper = (try? c.decodeIfPresent(Bool.self, forKey: .useDesktopWallpaper)) ?? true
        wallpaperID = try? c.decodeIfPresent(String.self, forKey: .wallpaperID)
        setsStillSystemPicture = (try? c.decodeIfPresent(Bool.self, forKey: .setsStillSystemPicture)) ?? false
    }

    /// The wallpaper the lock screen should show, given what is on the desktop.
    public func targetWallpaperID(desktopWallpaperID: WallpaperID?) -> WallpaperID? {
        guard isEnabled else { return nil }
        return useDesktopWallpaper ? desktopWallpaperID : wallpaperID
    }
}

/// The file the Driftwall screen-saver module reads. Written by the app, read-only for the saver.
/// Lives at `~/Library/Application Support/Driftwall/LockScreen/config.json`.
public struct LockScreenConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var wallpaperID: WallpaperID
    public var title: String
    public var mediaPath: String
    public var gravity: VideoGravity
    public var appliedAt: Date

    public init(wallpaperID: WallpaperID, title: String, mediaPath: String, gravity: VideoGravity, appliedAt: Date) {
        version = Self.currentVersion
        self.wallpaperID = wallpaperID
        self.title = title
        self.mediaPath = mediaPath
        self.gravity = gravity
        self.appliedAt = appliedAt
    }
}

/// Support level of one lock-screen-related capability on this Mac.
public enum CapabilitySupport: Equatable, Sendable {
    case supported(String)
    case unavailable(String)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    public var detail: String {
        switch self {
        case .supported(let text), .unavailable(let text): return text
        }
    }
}

/// What macOS allows for the lock screen, evaluated from the OS version and what is installed.
/// The four capabilities are deliberately reported separately: support for one says nothing about the others.
public struct LockScreenCapabilities: Sendable {
    public var osVersion: OperatingSystemVersion
    /// 1. A still picture behind the login/password UI.
    public var staticImage: CapabilitySupport
    /// 2. A video or dynamic wallpaper installed through a supported system mechanism.
    public var systemVideoWallpaper: CapabilitySupport
    /// 3. Video playing while the Mac is locked (Driftwall: via the screen-saver module).
    public var videoWhileLocked: CapabilitySupport
    /// 4. Video on the unlocked desktop.
    public var desktopVideo: CapabilitySupport

    public var osVersionText: String { "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)" }

    public static func evaluate(osVersion: OperatingSystemVersion, screenSaverFrameworkPresent: Bool) -> LockScreenCapabilities {
        let modern = osVersion.majorVersion >= 14
        return LockScreenCapabilities(
            osVersion: osVersion,
            staticImage: .supported("A still picture can be shown, but only by setting the system desktop picture (NSWorkspace). macOS has no public API for a separate lock-screen picture."),
            systemVideoWallpaper: .unavailable("macOS’s video wallpapers (Aerials) use a wallpaper-extension point that requires a private Apple entitlement. Third-party apps cannot add one."),
            videoWhileLocked: (modern && screenSaverFrameworkPresent)
                ? .supported("Through a public screen-saver module. When “Require password” is immediate, the video plays full screen while the Mac is locked. The password prompt itself appears over the still system picture.")
                : .unavailable(screenSaverFrameworkPresent ? "Requires macOS 14 or later." : "ScreenSaver.framework is not available on this system."),
            desktopVideo: .supported("Driftwall’s live desktop wallpaper.")
        )
    }
}

/// Whether a library item can be used by the lock-screen module.
public enum LockScreenMediaCompatibility: Equatable, Sendable {
    case compatible
    case compatibleWithWarning(String)
    case incompatible(String)

    public var isUsable: Bool {
        if case .incompatible = self { return false }
        return true
    }

    public var message: String {
        switch self {
        case .compatible: return "Compatible with the lock screen."
        case .compatibleWithWarning(let text), .incompatible(let text): return text
        }
    }

    public static let supportedCodecs: Set<String> = ["H.264", "HEVC", "ProRes"]

    public static func evaluate(_ wallpaper: Wallpaper, availability: MediaAvailability) -> LockScreenMediaCompatibility {
        guard availability.isAvailable else {
            return .incompatible("The video file is missing, so it can’t be used on the lock screen.")
        }
        guard wallpaper.hasMetadata else {
            return .incompatible("Driftwall hasn’t been able to read this video’s duration and size yet.")
        }
        let ext = URL(fileURLWithPath: wallpaper.mediaPath).pathExtension.lowercased()
        guard MediaInspector.supportedExtensions.contains(ext) else {
            return .incompatible("Only .mov, .mp4 and .m4v videos are supported.")
        }
        if let codec = wallpaper.codec, !supportedCodecs.contains(codec) {
            return .compatibleWithWarning("Uses the \(codec) codec, which may not decode in the screen-saver process. H.264 or HEVC is recommended.")
        }
        if max(wallpaper.pixelWidth, wallpaper.pixelHeight) > 7680 {
            return .compatibleWithWarning("Very high resolution video may stutter on the lock screen.")
        }
        if wallpaper.isPortrait {
            return .compatibleWithWarning("Portrait video will be cropped heavily on landscape displays.")
        }
        return .compatible
    }
}

public enum ScreenSaverSelection: Equatable, Sendable {
    case selected
    case notSelected
    case unknown
}

/// Current state of the lock-screen feature, as shown in the UI. Only `.active` means the configuration
/// was written and verified; it does not by itself prove the system will run the screen saver.
public enum LockScreenStatus: Equatable, Sendable {
    case disabled
    case unsupported(String)
    case nothingSelected
    case needsSetup(String)
    case active(title: String)
    case failed(String)

    public var summary: String {
        switch self {
        case .disabled: return "Off"
        case .unsupported(let why): return "Not available: \(why)"
        case .nothingSelected: return "Choose a wallpaper for the lock screen."
        case .needsSetup(let what): return what
        case .active(let title): return "“\(title)” is ready to play while the Mac is locked."
        case .failed(let message): return message
        }
    }
}
