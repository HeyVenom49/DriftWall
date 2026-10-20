import DriftwallCore
import Foundation
import Observation

/// Connects the pure rotation logic (`RotationSequencer`, `RotationScheduler`) to the library and the
/// persisted `RotationSettings`. Exactly one scheduler task exists at a time.
@MainActor
@Observable
final class RotationCoordinator {
    private(set) var nextChange: Date?
    private(set) var lastMessage: String?

    @ObservationIgnored private let scheduler: RotationScheduler
    @ObservationIgnored private var sequencer: RotationSequencer?
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let settingsModel: SettingsModel
    @ObservationIgnored private let apply: (WallpaperID) -> Void
    /// True while the system is asleep/locked: rotation does not advance when nobody can see it.
    @ObservationIgnored private var systemSuspended = false

    init(library: LibraryModel, settingsModel: SettingsModel, scheduler: RotationScheduler? = nil, apply: @escaping (WallpaperID) -> Void) {
        self.library = library
        self.settingsModel = settingsModel
        self.scheduler = scheduler ?? RotationScheduler()
        self.apply = apply
        self.scheduler.onFire = { [weak self] in self?.advance(.forward, manual: false) }
    }

    var settings: RotationSettings { settingsModel.settings.rotation }
    var isActive: Bool { settings.isEnabled && settings.playlistID != nil }
    var isRunning: Bool { scheduler.isRunning }
    var playlist: Playlist? { library.playlist(settings.playlistID) }

    /// Restores rotation after launch.
    func restore() {
        guard isActive, let playlist else {
            if settings.isEnabled { update { $0.isEnabled = false } }
            return
        }
        sequencer = RotationSequencer(items: playlist.itemIDs, currentID: settings.currentWallpaperID, shuffle: settings.shuffle)
        reschedule()
    }

    func start(playlistID: String, interval: TimeInterval? = nil, shuffle: Bool? = nil) {
        guard let playlist = library.playlist(playlistID) else { return }
        guard playlist.itemIDs.contains(where: library.isAvailable) else {
            lastMessage = "“\(playlist.name)” has no playable wallpapers."
            return
        }
        update {
            $0.isEnabled = true
            $0.playlistID = playlistID
            $0.isPaused = false
            if let interval { $0.interval = interval }
            if let shuffle { $0.shuffle = shuffle }
            $0.currentWallpaperID = nil
        }
        sequencer = RotationSequencer(items: playlist.itemIDs, shuffle: settings.shuffle)
        lastMessage = nil
        advance(.forward, manual: true)
        DiagnosticsLog.shared.log(.info, "rotation", "Started playlist “\(playlist.name)” every \(RotationSettings.label(for: settings.interval))")
    }

    func stop() {
        scheduler.stop()
        sequencer = nil
        nextChange = nil
        update {
            $0.isEnabled = false
            $0.isPaused = false
        }
    }

    func setPaused(_ paused: Bool) {
        guard isActive else { return }
        update { $0.isPaused = paused }
        reschedule()
    }

    func setInterval(_ interval: TimeInterval) {
        update { $0.interval = max(10, interval) }
        reschedule()
    }

    func setShuffle(_ shuffle: Bool) {
        update { $0.shuffle = shuffle }
        sequencer?.shuffle = shuffle
    }

    /// Called when the system sleeps/locks or wakes.
    func setSystemSuspended(_ suspended: Bool) {
        guard suspended != systemSuspended else { return }
        systemSuspended = suspended
        reschedule()
    }

    /// Called after playlist edits so the sequence reflects added, removed or reordered items.
    func playlistsChanged() {
        guard isActive else { return }
        guard let playlist else {
            stop()
            lastMessage = "The rotating playlist was deleted."
            return
        }
        sequencer?.updateItems(playlist.itemIDs)
    }

    func next() { advance(.forward, manual: true) }
    func previous() { advance(.backward, manual: true) }

    // MARK: - Private

    private enum Direction { case forward, backward }

    private func advance(_ direction: Direction, manual: Bool) {
        guard isActive, var sequencer else { return }
        let id = direction == .forward ? sequencer.next(isAvailable: library.isAvailable) : sequencer.previous(isAvailable: library.isAvailable)
        self.sequencer = sequencer
        guard let id else {
            lastMessage = "No playable wallpapers left in the playlist; rotation stopped."
            DiagnosticsLog.shared.log(.warning, "rotation", lastMessage ?? "")
            stop()
            return
        }
        update { $0.currentWallpaperID = id }
        apply(id)
        if manual { reschedule() } else { nextChange = scheduler.nextFireDate }
    }

    private func reschedule() {
        if isActive && !settings.isPaused && !systemSuspended {
            scheduler.start(interval: settings.interval)
            nextChange = scheduler.nextFireDate
        } else {
            scheduler.stop()
            nextChange = nil
        }
    }

    private func update(_ change: (inout RotationSettings) -> Void) {
        var rotation = settingsModel.settings.rotation
        change(&rotation)
        settingsModel.settings.rotation = rotation
    }
}
