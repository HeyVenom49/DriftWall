import Foundation
import Observation

/// Observable wrapper around persisted `AppSettings`. Every change is saved immediately.
@MainActor
@Observable
public final class SettingsModel {
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?(oldValue, settings)
        }
    }

    @ObservationIgnored public var onChange: ((_ old: AppSettings, _ new: AppSettings) -> Void)?
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let log: DiagnosticsLog

    public init(store: LibraryStore, log: DiagnosticsLog = .shared) {
        self.store = store
        self.log = log
        do {
            settings = try store.loadSettings()
        } catch {
            settings = AppSettings()
            log.log(.error, "settings", "Could not load settings, using defaults: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try store.saveSettings(settings)
        } catch {
            log.log(.error, "settings", "Could not save settings: \(error.localizedDescription)")
        }
    }
}

/// Observable, persisted display → wallpaper assignments (including those for disconnected displays).
@MainActor
@Observable
public final class AssignmentsModel {
    public private(set) var assignments: [DisplayAssignment] = []
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let log: DiagnosticsLog

    public init(store: LibraryStore, log: DiagnosticsLog = .shared) {
        self.store = store
        self.log = log
        reload()
    }

    public func reload() {
        do { assignments = try store.assignments() } catch {
            log.log(.error, "displays", "Could not load display assignments: \(error.localizedDescription)")
        }
    }

    public func wallpaperID(for displayID: String) -> WallpaperID? {
        assignments.first { $0.displayID == displayID }?.wallpaperID
    }

    public func assign(_ wallpaperID: WallpaperID, to display: DisplayInfo, at date: Date = Date()) {
        let assignment = DisplayAssignment(displayID: display.id, wallpaperID: wallpaperID, displayName: display.name, updatedAt: date)
        do {
            try store.setAssignment(assignment)
            assignments.removeAll { $0.displayID == display.id }
            assignments.insert(assignment, at: 0)
        } catch {
            log.log(.error, "displays", "Could not save assignment for \(display.name): \(error.localizedDescription)")
        }
    }

    public func clear(displayID: String) {
        do {
            try store.removeAssignment(displayID: displayID)
            assignments.removeAll { $0.displayID == displayID }
        } catch {
            log.log(.error, "displays", "Could not clear assignment: \(error.localizedDescription)")
        }
    }
}
