import AppKit
import DriftwallCore

/// Reports which displays' desktops are completely covered by app windows (see `DesktopCoverage`).
///
/// Window frames come from `CGWindowListCopyWindowInfo`, which needs no Screen Recording permission
/// for bounds. Other apps' windows post no notifications when they move, so the monitor checks once a
/// second while active (with tolerance, so the wakeup coalesces with others), and at once when the
/// frontmost app, an app's visibility or the Space changes. It runs only while a wallpaper plays.
@MainActor
final class DesktopCoverageMonitor {
    var onChange: ((Set<CGDirectDisplayID>) -> Void)?
    private(set) var covered: Set<CGDirectDisplayID> = []
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []

    var isActive: Bool { timer != nil }

    /// Starting checks on the next run-loop turn; stopping forgets coverage without calling `onChange`.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active { start() } else { stop() }
    }

    private func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens.removeAll()
        covered = []
    }

    func check() {
        guard isActive else { return }
        let result = Self.coveredDisplays()
        guard result != covered else { return }
        covered = result
        onChange?(result)
    }

    static func coveredDisplays() -> Set<CGDirectDisplayID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        // Ordinary app windows only (layer 0): not the menu bar, Dock, panels or the wallpaper itself.
        let windows: [CGRect] = info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.9,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rect
        }
        guard !windows.isEmpty else { return [] }
        // Window bounds use a top-left origin at the primary screen; NSScreen uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var result = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = DisplayService.directID(of: screen) else { continue }
            let usable = screen.visibleFrame
            let area = CGRect(x: usable.minX, y: primaryHeight - usable.maxY, width: usable.width, height: usable.height)
            if DesktopCoverage.isCovered(area, by: windows) { result.insert(id) }
        }
        return result
    }
}
