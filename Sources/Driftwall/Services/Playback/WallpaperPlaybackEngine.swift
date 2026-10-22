import AppKit
import AVFoundation
import DriftwallCore
import Observation

/// Why playback is currently suspended. Playback runs only when no reason is active.
enum PauseReason: String, CaseIterable, Hashable {
    case user, systemSleep, displaysAsleep, screenLocked, sessionInactive, onBattery, lowPowerMode

    var label: String {
        switch self {
        case .user: return "Paused by you"
        case .systemSleep: return "Mac is asleep"
        case .displaysAsleep: return "Displays are asleep"
        case .screenLocked: return "Screen is locked"
        case .sessionInactive: return "Another user is active"
        case .onBattery: return "On battery power"
        case .lowPowerMode: return "Low Power Mode"
        }
    }
}

enum SurfaceStatus: Equatable {
    case loading
    case playing
    case paused(String)
    case failed(String)

    var label: String {
        switch self {
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused(let why): return why
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

struct SurfaceState: Equatable, Identifiable {
    var id: String { displayID }
    var displayID: String
    var displayName: String
    var wallpaperID: WallpaperID
    var status: SurfaceStatus
}

/// What should play on a display.
struct PlaybackRequest: Equatable {
    var display: DisplayInfo
    var wallpaperID: WallpaperID
    var url: URL
}

/// Owns the desktop surfaces and the decoders behind them. Independent of SwiftUI: the app
/// describes the desired state with `reconcile(_:)` and the engine creates, reuses or releases
/// windows and players to match it.
@MainActor
@Observable
final class WallpaperPlaybackEngine {
    private(set) var surfaceStates: [String: SurfaceState] = [:]
    private(set) var pauseReasons: Set<PauseReason> = []
    private(set) var activePlayerCount = 0
    /// Wallpapers on at least one display. Separate from `surfaceStates` so views that only ask
    /// "is this one live?" (every grid card) aren't invalidated by pause, resume or loading changes.
    private(set) var liveWallpaperIDs: Set<WallpaperID> = []

    var gravity: VideoGravity = .fill { didSet { applyPresentationSettings() } }
    var showDesktopIcons = true { didSet { applyPresentationSettings() } }
    /// Pause a decoder when every surface using it is fully covered (e.g. by a full-screen app).
    var pauseWhenHidden = true { didSet { updatePlayback() } }

    var onFailure: ((WallpaperID, String) -> Void)?

    @ObservationIgnored private var surfaces: [String: DesktopSurface] = [:]
    @ObservationIgnored private var players: [WallpaperID: SharedPlayer] = [:]
    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let coverage = DesktopCoverageMonitor()

    init(log: DiagnosticsLog = .shared) {
        self.log = log
        coverage.onChange = { [weak self] covered in
            guard let self else { return }
            for surface in self.surfaces.values { surface.isCoveredByWindows = covered.contains(surface.directDisplayID) }
            self.updatePlayback()
        }
    }

    var isPaused: Bool { !pauseReasons.isEmpty }
    var hasActiveWallpaper: Bool { !surfaceStates.isEmpty }

    // MARK: - Desired state

    /// Makes the desktop match `requests`: one surface per requested display. Surfaces for displays
    /// not in the list are closed and decoders nobody uses any more are released.
    func reconcile(_ requests: [PlaybackRequest]) {
        let wanted = Dictionary(requests.map { ($0.display.id, $0) }, uniquingKeysWith: { a, _ in a })

        for (displayID, surface) in surfaces where wanted[displayID] == nil {
            surface.close()
            surfaces[displayID] = nil
        }

        for request in requests {
            let surface = surfaces[request.display.id] ?? makeSurface(for: request.display)
            surface.update(display: request.display)
            let player = player(for: request.wallpaperID, url: request.url)
            if player.isFailed {
                surface.showFailure(of: request.wallpaperID)
            } else if surface.wallpaperID != request.wallpaperID || !surface.window.isVisible {
                surface.show(player, gravity: avGravity)
                log.log(.info, "playback", "Showing “\(request.wallpaperID)” on \(request.display.name)")
            }
        }

        let inUse = Set(surfaces.values.compactMap(\.wallpaperID)).union(requests.map(\.wallpaperID))
        for (id, player) in players where !inUse.contains(id) {
            player.invalidate()
            players[id] = nil
        }
        updatePlayback()
    }

    func setPaused(_ reason: PauseReason, _ active: Bool) {
        let changed = active ? pauseReasons.insert(reason).inserted : pauseReasons.remove(reason) != nil
        guard changed else { return }
        log.log(.info, "playback", "\(active ? "Pause" : "Resume") — \(reason.label)")
        updatePlayback()
    }

    /// Closes every surface and releases every decoder (used at quit).
    func teardown() {
        surfaces.values.forEach { $0.close() }
        surfaces.removeAll()
        players.values.forEach { $0.invalidate() }
        players.removeAll()
        coverage.setActive(false)
        surfaceStates.removeAll()
        liveWallpaperIDs.removeAll()
        activePlayerCount = 0
    }

    // MARK: - Private

    private var avGravity: AVLayerVideoGravity {
        switch gravity {
        case .fill: return .resizeAspectFill
        case .fit: return .resizeAspect
        case .stretch: return .resize
        }
    }

    private func makeSurface(for display: DisplayInfo) -> DesktopSurface {
        let surface = DesktopSurface(display: display)
        surface.window.setShowsDesktopIcons(showDesktopIcons)
        surface.onOcclusionChange = { [weak self] in self?.updatePlayback() }
        surfaces[display.id] = surface
        return surface
    }

    private func player(for id: WallpaperID, url: URL) -> SharedPlayer {
        // A failed player is replaced so that re-applying a wallpaper retries playback.
        if let existing = players[id], existing.url == url, !existing.isFailed { return existing }
        players[id]?.invalidate()
        let player = SharedPlayer(wallpaperID: id, url: url)
        player.onStatusChange = { [weak self] player in self?.playerStatusChanged(player) }
        players[id] = player
        return player
    }

    private func playerStatusChanged(_ player: SharedPlayer) {
        if case .failed(let message) = player.status {
            log.log(.error, "playback", "Playback failed for “\(player.wallpaperID)”: \(message)")
            for surface in surfaces.values where surface.wallpaperID == player.wallpaperID {
                // Reveal the regular system wallpaper rather than leaving a black screen.
                surface.showFailure(of: player.wallpaperID)
            }
            onFailure?(player.wallpaperID, message)
        }
        updatePlayback()
    }

    private func applyPresentationSettings() {
        for surface in surfaces.values {
            surface.window.setShowsDesktopIcons(showDesktopIcons)
            surface.container.gravity = avGravity
        }
    }

    private func updatePlayback() {
        // Watch window coverage only while something could play; otherwise it would wake up for nothing.
        let watchCoverage = pauseWhenHidden && pauseReasons.isEmpty && !surfaces.isEmpty
        if watchCoverage != coverage.isActive {
            coverage.setActive(watchCoverage)
            if !watchCoverage { surfaces.values.forEach { $0.isCoveredByWindows = false } }
        }
        var states: [String: SurfaceState] = [:]
        var playing = 0
        for (id, player) in players {
            let attached = surfaces.values.filter { $0.wallpaperID == id }
            let allHidden = !attached.isEmpty && attached.allSatisfy(\.isHidden)
            let shouldPlay = pauseReasons.isEmpty && !(pauseWhenHidden && allHidden) && !player.isFailed
            if shouldPlay { player.play() } else { player.pause() }
            if shouldPlay { playing += 1 }

            let status: SurfaceStatus
            switch player.status {
            case .failed(let message): status = .failed(message)
            case .loading: status = shouldPlay ? .loading : .paused(pauseLabel(hidden: allHidden))
            case .ready: status = shouldPlay ? .playing : .paused(pauseLabel(hidden: allHidden))
            }
            for surface in attached {
                states[surface.displayID] = SurfaceState(displayID: surface.displayID, displayName: surface.displayName, wallpaperID: id, status: status)
            }
        }
        if states != surfaceStates { surfaceStates = states }
        let live = Set(states.values.map(\.wallpaperID))
        if live != liveWallpaperIDs { liveWallpaperIDs = live }
        if playing != activePlayerCount { activePlayerCount = playing }
    }

    private func pauseLabel(hidden: Bool) -> String {
        if let reason = PauseReason.allCases.first(where: pauseReasons.contains) { return reason.label }
        return hidden ? "Paused while hidden" : "Paused"
    }
}
