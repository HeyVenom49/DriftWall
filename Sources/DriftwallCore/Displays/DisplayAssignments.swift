import CoreGraphics
import Foundation

/// A snapshot of a connected display. `id` is the display's stable UUID string (survives reconnects
/// and reboots), not the transient CGDirectDisplayID.
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var directDisplayID: UInt32
    public var name: String
    /// Frame in AppKit global screen coordinates (points).
    public var frame: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var rotation: Double

    public init(id: String, directDisplayID: UInt32, name: String, frame: CGRect, pixelWidth: Int, pixelHeight: Int,
                scale: Double, isMain: Bool, isBuiltIn: Bool, rotation: Double = 0) {
        self.id = id
        self.directDisplayID = directDisplayID
        self.name = name
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.rotation = rotation
    }

    public var isPortrait: Bool { frame.height > frame.width }
    public var resolutionText: String { "\(pixelWidth) × \(pixelHeight)" }
}

/// Pure logic that maps connected displays to wallpapers. Kept free of AppKit so it can be tested
/// with synthetic display configurations.
public enum DisplayAssignmentResolver {
    /// Returns the wallpaper that should play on each connected display.
    /// Displays whose assigned wallpaper is unavailable are omitted (the system wallpaper stays visible there).
    public static func resolve(
        displays: [DisplayInfo],
        assignments: [DisplayAssignment],
        mode: DisplayMode,
        mirrorWallpaperID: WallpaperID?,
        isAvailable: (WallpaperID) -> Bool
    ) -> [String: WallpaperID] {
        var result: [String: WallpaperID] = [:]
        switch mode {
        case .mirror:
            guard let id = mirrorWallpaperID, isAvailable(id) else { return [:] }
            for display in displays { result[display.id] = id }
        case .perDisplay:
            let byDisplay = Dictionary(assignments.map { ($0.displayID, $0.wallpaperID) }, uniquingKeysWith: { first, _ in first })
            for display in displays {
                if let id = byDisplay[display.id], isAvailable(id) { result[display.id] = id }
            }
        }
        return result
    }

    /// The displays an "Apply" targets, given the user's preference and what is connected.
    /// Falls back to the main display when a specific display is no longer connected.
    public static func targetDisplays(for target: DisplayTarget, in displays: [DisplayInfo]) -> [DisplayInfo] {
        switch target {
        case .allDisplays:
            return displays
        case .mainDisplay:
            return displays.filter(\.isMain).prefix(1).map { $0 }.ifEmpty(displays.prefix(1).map { $0 })
        case .display(let id):
            if let match = displays.first(where: { $0.id == id }) { return [match] }
            return targetDisplays(for: .mainDisplay, in: displays)
        }
    }

    /// Assignments stored for displays that are not currently connected. They are kept so the
    /// wallpaper comes back when the display is reconnected.
    public static func dormantAssignments(_ assignments: [DisplayAssignment], connected displays: [DisplayInfo]) -> [DisplayAssignment] {
        let connected = Set(displays.map(\.id))
        return assignments.filter { !connected.contains($0.displayID) }
    }
}

extension Array {
    func ifEmpty(_ fallback: @autoclosure () -> [Element]) -> [Element] { isEmpty ? fallback() : self }
}
