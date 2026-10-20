import Foundation

public enum VideoGravity: String, Codable, Sendable, CaseIterable, Identifiable {
    case fill, fit, stretch
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .fill: return "Fill Screen"
        case .fit: return "Fit to Screen"
        case .stretch: return "Stretch"
        }
    }
}

public enum DisplayMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Each display keeps its own wallpaper assignment.
    case perDisplay
    /// Every connected display shows the same wallpaper (one decoder shared across displays).
    case mirror
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .perDisplay: return "Different per Display"
        case .mirror: return "Same on All Displays"
        }
    }
}

/// Where the "Apply" action places a wallpaper when the user does not pick a display explicitly.
public enum DisplayTarget: Codable, Hashable, Sendable {
    case allDisplays
    case mainDisplay
    case display(id: String)
}

public enum AppearancePreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, dark, light
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public enum GridDensity: String, Codable, Sendable, CaseIterable, Identifiable {
    case compact, comfortable, large
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var minimumCardWidth: Double {
        switch self {
        case .compact: return 180
        case .comfortable: return 240
        case .large: return 320
        }
    }
}

public struct RotationSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool = false
    public var playlistID: String?
    public var interval: TimeInterval = 30 * 60
    public var shuffle: Bool = false
    public var isPaused: Bool = false
    public var currentWallpaperID: WallpaperID?
    /// The display the rotation changes, by display UUID. nil means every display.
    public var targetDisplayID: String?

    public init() {}

    public static let intervalPresets: [TimeInterval] = [60, 5 * 60, 15 * 60, 30 * 60, 60 * 60, 3 * 3600, 6 * 3600, 24 * 3600]

    public static func label(for interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds < 3600 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        if seconds < 86400 { return seconds == 3600 ? "1 hour" : "\(seconds / 3600) hours" }
        return seconds == 86400 ? "1 day" : "\(seconds / 86400) days"
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, playlistID, interval, shuffle, isPaused, currentWallpaperID, targetDisplayID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        playlistID = try c.decodeIfPresent(String.self, forKey: .playlistID)
        interval = max(10, try c.decodeIfPresent(TimeInterval.self, forKey: .interval) ?? 1800)
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        currentWallpaperID = try c.decodeIfPresent(String.self, forKey: .currentWallpaperID)
        targetDisplayID = try c.decodeIfPresent(String.self, forKey: .targetDisplayID)
    }
}

/// All persisted user preferences. Decoding tolerates missing keys so new settings can be added
/// without a schema migration: absent keys fall back to their defaults.
public struct AppSettings: Codable, Equatable, Sendable {
    // General
    public var hasCompletedOnboarding = false
    public var launchAtLogin = false
    public var showDockIcon = true
    public var resumeOnLaunch = true
    public var openMainWindowAtLaunch = true

    // Playback
    public var videoGravity: VideoGravity = .fill
    public var userPaused = false
    public var pauseOnBattery = false
    public var pauseInLowPowerMode = true
    public var pauseWhenDesktopHidden = true
    public var showDesktopIcons = true
    public var syncSystemWallpaper = false
    public var hoverPreviews = true

    // Displays
    public var displayMode: DisplayMode = .perDisplay
    public var defaultTarget: DisplayTarget = .allDisplays
    public var mirrorWallpaperID: WallpaperID?

    // Rotation
    public var rotation = RotationSettings()

    // Library
    public var copyImportsIntoLibrary = false

    // Appearance
    public var appearance: AppearancePreference = .dark
    public var gridDensity: GridDensity = .comfortable

    // Shortcuts
    public var globalHotKeysEnabled = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding, launchAtLogin, showDockIcon, resumeOnLaunch, openMainWindowAtLaunch
        case videoGravity, userPaused, pauseOnBattery, pauseInLowPowerMode, pauseWhenDesktopHidden
        case showDesktopIcons, syncSystemWallpaper, hoverPreviews
        case displayMode, defaultTarget, mirrorWallpaperID
        case rotation, copyImportsIntoLibrary, appearance, gridDensity, globalHotKeysEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // A single malformed value should not reset every other preference.
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        hasCompletedOnboarding = value(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        launchAtLogin = value(.launchAtLogin, d.launchAtLogin)
        showDockIcon = value(.showDockIcon, d.showDockIcon)
        resumeOnLaunch = value(.resumeOnLaunch, d.resumeOnLaunch)
        openMainWindowAtLaunch = value(.openMainWindowAtLaunch, d.openMainWindowAtLaunch)
        videoGravity = value(.videoGravity, d.videoGravity)
        userPaused = value(.userPaused, d.userPaused)
        pauseOnBattery = value(.pauseOnBattery, d.pauseOnBattery)
        pauseInLowPowerMode = value(.pauseInLowPowerMode, d.pauseInLowPowerMode)
        pauseWhenDesktopHidden = value(.pauseWhenDesktopHidden, d.pauseWhenDesktopHidden)
        showDesktopIcons = value(.showDesktopIcons, d.showDesktopIcons)
        syncSystemWallpaper = value(.syncSystemWallpaper, d.syncSystemWallpaper)
        hoverPreviews = value(.hoverPreviews, d.hoverPreviews)
        displayMode = value(.displayMode, d.displayMode)
        defaultTarget = value(.defaultTarget, d.defaultTarget)
        mirrorWallpaperID = value(.mirrorWallpaperID, d.mirrorWallpaperID)
        rotation = value(.rotation, d.rotation)
        copyImportsIntoLibrary = value(.copyImportsIntoLibrary, d.copyImportsIntoLibrary)
        appearance = value(.appearance, d.appearance)
        gridDensity = value(.gridDensity, d.gridDensity)
        globalHotKeysEnabled = value(.globalHotKeysEnabled, d.globalHotKeysEnabled)
    }
}
