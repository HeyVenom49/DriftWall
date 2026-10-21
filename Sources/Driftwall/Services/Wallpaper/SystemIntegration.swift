import AppKit
import Carbon.HIToolbox
import DriftwallCore
import ServiceManagement

/// Sets the static system desktop picture through the public `NSWorkspace` API. Used (when enabled)
/// to mirror a still frame of the live wallpaper so the lock screen, Mission Control and the desktop
/// after quitting show a matching image. A video file passed to this API would not animate.
@MainActor
enum SystemWallpaperService {
    static func setStaticWallpaper(_ imageURL: URL, on screen: NSScreen) throws {
        // Keep the user's own picture so it can be put back (Undo All, or the cleanup task after deletion).
        AppController.shared.recordOriginalDesktopPicture(for: screen)
        defer { AppController.shared.refreshCleanupAgent() }
        try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ])
    }
}

/// Launch-at-login through `SMAppService.mainApp` (macOS 13+). The system may require the user to
/// approve the login item in System Settings › General › Login Items.
@MainActor
enum LaunchAtLoginService {
    enum State: Equatable {
        case enabled, disabled, requiresApproval, unavailable(String)

        var description: String {
            switch self {
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
            case .unavailable(let reason): return "Unavailable: \(reason)"
            }
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable("run Driftwall from its .app bundle")
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// System-wide shortcuts registered with Carbon's `RegisterEventHotKey`. This public API does not
/// require Accessibility permission (unlike global event monitors).
@MainActor
final class GlobalHotKeyCenter {
    enum Action: UInt32, CaseIterable {
        case togglePlayback = 1, next, previous

        var keyCode: UInt32 {
            switch self {
            case .togglePlayback: return UInt32(kVK_ANSI_P)
            case .next: return UInt32(kVK_RightArrow)
            case .previous: return UInt32(kVK_LeftArrow)
            }
        }

        var title: String {
            switch self {
            case .togglePlayback: return "Play / Pause"
            case .next: return "Next Wallpaper"
            case .previous: return "Previous Wallpaper"
            }
        }

        var display: String {
            switch self {
            case .togglePlayback: return "⌃⌥⌘P"
            case .next: return "⌃⌥⌘→"
            case .previous: return "⌃⌥⌘←"
            }
        }
    }

    static let shared = GlobalHotKeyCenter()
    var handler: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private(set) var isRegistered = false
    private(set) var lastError: String?

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard !isRegistered else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if let action = GlobalHotKeyCenter.Action(rawValue: hotKeyID.id) {
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKeyCenter.shared.handler?(action) } }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        guard status == noErr else {
            lastError = "Could not install the shortcut handler (\(status))."
            return
        }
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        var failures: [String] = []
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4452_4657), id: action.rawValue) // 'DRFW'
            let result = RegisterEventHotKey(action.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) } else { failures.append(action.display) }
        }
        lastError = failures.isEmpty ? nil : "Already in use by another app: \(failures.joined(separator: ", "))"
        isRegistered = true
        DiagnosticsLog.shared.log(failures.isEmpty ? .info : .warning, "shortcuts", lastError ?? "Global shortcuts registered")
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        isRegistered = false
    }
}
