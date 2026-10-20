import AppKit
import ColorSync
import DriftwallCore
import Observation

/// Enumerates connected displays and publishes changes (connect, disconnect, resolution, arrangement,
/// rotation). Displays are identified by their CoreGraphics UUID, which is stable across reconnects.
@MainActor
@Observable
final class DisplayService {
    private(set) var displays: [DisplayInfo] = []
    @ObservationIgnored var onChange: (([DisplayInfo]) -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init() {
        displays = Self.currentDisplays()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    func display(id: String) -> DisplayInfo? { displays.first { $0.id == id } }

    func screen(for display: DisplayInfo) -> NSScreen? {
        NSScreen.screens.first { Self.directID(of: $0) == display.directDisplayID }
    }

    /// Re-reads the configuration now. Screen-parameter notifications arrive in bursts while macOS
    /// reconfigures, so notifications are coalesced through `scheduleRefresh`.
    func refresh() {
        let latest = Self.currentDisplays()
        guard latest != displays else { return }
        let previous = Set(displays.map(\.id)), current = Set(latest.map(\.id))
        for added in current.subtracting(previous) { DiagnosticsLog.shared.log(.info, "displays", "Display connected: \(latest.first { $0.id == added }?.name ?? added)") }
        for removed in previous.subtracting(current) { DiagnosticsLog.shared.log(.info, "displays", "Display disconnected: \(displays.first { $0.id == removed }?.name ?? removed)") }
        displays = latest
        onChange?(latest)
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    static func directID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func uuidString(for displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return "display-\(displayID)"
    }

    static func currentDisplays() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let directID = directID(of: screen) else { return nil }
            let mode = CGDisplayCopyDisplayMode(directID)
            let pixelWidth = mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor)
            let pixelHeight = mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor)
            return DisplayInfo(
                id: uuidString(for: directID),
                directDisplayID: directID,
                name: screen.localizedName,
                frame: screen.frame,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: Double(screen.backingScaleFactor),
                isMain: directID == mainID,
                isBuiltIn: CGDisplayIsBuiltin(directID) != 0,
                rotation: CGDisplayRotation(directID)
            )
        }
    }
}
