import AppKit
import DriftwallCore
import IOKit.ps

/// Translates macOS lifecycle and power signals into playback pause reasons.
///
/// Signals used:
/// - `NSWorkspace` will-sleep / did-wake, screens-did-sleep / did-wake and session active/inactive (documented).
/// - `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications. These are widely
///   used but not formally documented; if they stop being posted the screens-did-sleep signal still applies.
/// - IOKit power-source notifications for battery state, and `ProcessInfo.isLowPowerModeEnabled`.
@MainActor
final class SystemEventMonitor {
    var onChange: ((PauseReason, Bool) -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.emit(.systemSleep, true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.emit(.systemSleep, false) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.emit(.displaysAsleep, true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.emit(.displaysAsleep, false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.emit(.sessionInactive, true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.emit(.sessionInactive, false) }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.emit(.screenLocked, true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.emit(.screenLocked, false) }

        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) { monitor in
            monitor.emit(.lowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.emit(.onBattery, SystemEventMonitor.isOnBattery) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        // Initial state.
        emit(.onBattery, Self.isOnBattery)
        emit(.lowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
    }

    static var isOnBattery: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    private func emit(_ reason: PauseReason, _ active: Bool) {
        onChange?(reason, active)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (SystemEventMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }
}
