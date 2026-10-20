import AppKit
import DriftwallCore
import Observation

struct Banner: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    var kind: Kind
    var message: String
}

struct ImportProgress: Equatable {
    var total: Int
    var completed: Int
    var currentName: String
}

struct ImportReport: Identifiable {
    let id = UUID()
    var imported: [Wallpaper]
    var failures: [(name: String, reason: String)]
}

/// Composition root and app-level coordinator. Owns the services, wires them together, and exposes
/// the user-facing actions (apply, import, remove, playback control). Domain state lives in the
/// smaller models it owns (`LibraryModel`, `SettingsModel`, `AssignmentsModel`, `RotationCoordinator`).
@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    let paths: AppPaths
    let library: LibraryModel
    let settingsModel: SettingsModel
    let assignments: AssignmentsModel
    let displays = DisplayService()
    let engine = WallpaperPlaybackEngine()
    let navigation = NavigationModel()
    @ObservationIgnored let thumbnails: ThumbnailService
    @ObservationIgnored let thumbnailLoader: ThumbnailLoader
    @ObservationIgnored let importer: MediaImporter
    @ObservationIgnored let rotation: RotationCoordinator
    @ObservationIgnored private let systemEvents = SystemEventMonitor()
    @ObservationIgnored let log = DiagnosticsLog.shared

    var banner: Banner?
    var importProgress: ImportProgress?
    var importReport: ImportReport?
    var startupProblem: String?
    /// Bumped when cached thumbnails are cleared so visible images reload.
    var thumbnailEpoch = 0
    var diagnosticsEpoch = 0
    var isStarted = false

    @ObservationIgnored private var rawOnBattery = false
    @ObservationIgnored private var rawLowPower = false
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    var settings: AppSettings {
        get { settingsModel.settings }
        set { settingsModel.settings = newValue }
    }

    private init() {
        paths = AppPaths.standard()
        var problem: String?
        do { try paths.createDirectories() } catch { problem = "Could not create the data folder: \(error.localizedDescription)" }

        let store: LibraryStore
        do {
            let opened = try SQLiteLibraryStore.open(at: paths.databaseURL)
            store = opened.store
            if let backup = opened.recoveredFrom {
                problem = "The library database was damaged and has been reset. The old file was kept at \(backup.path)."
                DiagnosticsLog.shared.log(.error, "persistence", problem ?? "")
            }
        } catch {
            // Last resort: keep the app usable with an in-memory store and say so clearly.
            problem = "Your library could not be opened (\(error.localizedDescription)). Changes this session will not be saved."
            DiagnosticsLog.shared.log(.error, "persistence", problem ?? "")
            // An in-memory SQLite database cannot realistically fail to open; if it does, there is nothing to recover.
            store = try! SQLiteLibraryStore(database: SQLiteDatabase(url: nil))
        }
        startupProblem = problem

        library = LibraryModel(store: store, resolver: MediaResolver(bundleResourcesURL: Bundle.main.resourceURL))
        settingsModel = SettingsModel(store: store)
        assignments = AssignmentsModel(store: store)
        thumbnails = ThumbnailService(cacheDirectory: paths.cacheDirectory)
        thumbnailLoader = ThumbnailLoader(service: thumbnails)
        importer = MediaImporter(libraryMediaDirectory: paths.mediaDirectory)
        // The coordinator calls back into `apply`, which needs `self`; route through a weak box filled in below.
        let owner = WeakOwner()
        rotation = RotationCoordinator(library: library, settingsModel: settingsModel) { id in
            owner.controller?.apply(id, target: nil, fromRotation: true)
        }
        owner.controller = self
        log.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.diagnosticsEpoch &+= 1 } }
        }
    }

    // MARK: - Startup / shutdown

    func start() {
        guard !isStarted else { return }
        isStarted = true
        log.log(.info, "app", "Starting Driftwall \(Bundle.main.shortVersion) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        library.load()
        loadCatalog()
        Task { await backfillMetadata() }

        engine.gravity = settings.videoGravity
        engine.showDesktopIcons = settings.showDesktopIcons
        engine.pauseWhenHidden = settings.pauseWhenDesktopHidden
        engine.setPaused(.user, settings.userPaused)
        engine.onFailure = { [weak self] id, message in
            let title = self?.library.wallpaper(id)?.title ?? "The wallpaper"
            self?.showBanner(.error, "\(title) could not be played: \(message)")
        }

        systemEvents.onChange = { [weak self] reason, active in self?.handleSystemEvent(reason, active) }
        systemEvents.start()

        displays.onChange = { [weak self] _ in self?.reconcileDesktop() }
        settingsModel.onChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }

        if settings.resumeOnLaunch {
            reconcileDesktop()
        }
        rotation.restore()
        GlobalHotKeyCenter.shared.handler = { [weak self] action in
            switch action {
            case .togglePlayback: self?.togglePlayback()
            case .next: self?.nextWallpaper()
            case .previous: self?.previousWallpaper()
            }
        }
        GlobalHotKeyCenter.shared.setEnabled(settings.globalHotKeysEnabled)
        applyDockPolicy()
        syncLaunchAtLoginState()
    }

    func shutdown() {
        systemEvents.stop()
        GlobalHotKeyCenter.shared.setEnabled(false)
        rotation.setSystemSuspended(true)
        engine.teardown()
        log.log(.info, "app", "Stopped")
    }

    private func loadCatalog() {
        guard let url = Bundle.main.url(forResource: "Catalog", withExtension: "json") else {
            log.log(.warning, "library", "No bundled catalog found; only imported wallpapers are available.")
            return
        }
        do {
            library.syncCatalog(try Catalog.load(from: url), mediaSubdirectory: "Samples")
        } catch {
            log.log(.error, "library", "Bundled catalog could not be read: \(error.localizedDescription)")
        }
    }

    /// Fills in duration/resolution for items that do not have it yet (bundled items on first launch).
    private func backfillMetadata() async {
        let inspector = MediaInspector()
        for wallpaper in library.wallpapers where !wallpaper.hasMetadata {
            guard let url = library.mediaURL(for: wallpaper.id) else { continue }
            do {
                let metadata = try await inspector.inspect(url)
                guard var current = library.wallpaper(wallpaper.id) else { continue }
                current.duration = metadata.duration
                current.pixelWidth = metadata.pixelWidth
                current.pixelHeight = metadata.pixelHeight
                current.frameRate = metadata.frameRate
                current.codec = metadata.codec
                current.fileSize = metadata.fileSize
                library.update(current)
            } catch {
                log.log(.warning, "library", "Could not read metadata for “\(wallpaper.title)”: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Desktop

    /// Makes the desktop surfaces match the persisted assignments and connected displays.
    func reconcileDesktop() {
        let resolved = DisplayAssignmentResolver.resolve(
            displays: displays.displays,
            assignments: assignments.assignments,
            mode: settings.displayMode,
            mirrorWallpaperID: settings.mirrorWallpaperID,
            isAvailable: library.isAvailable
        )
        let requests = displays.displays.compactMap { display -> PlaybackRequest? in
            guard let id = resolved[display.id], let url = library.mediaURL(for: id) else { return nil }
            return PlaybackRequest(display: display, wallpaperID: id, url: url)
        }
        engine.reconcile(requests)
    }

    /// The wallpaper on the main display (or any display), for the menu bar and Home hero.
    var currentWallpaper: Wallpaper? {
        let states = engine.surfaceStates
        if let main = displays.displays.first(where: \.isMain), let state = states[main.id] { return library.wallpaper(state.wallpaperID) }
        return states.values.sorted { $0.displayID < $1.displayID }.first.flatMap { library.wallpaper($0.wallpaperID) }
    }

    func displaysShowing(_ id: WallpaperID) -> [SurfaceState] {
        engine.surfaceStates.values.filter { $0.wallpaperID == id }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Banner

    func showBanner(_ kind: Banner.Kind, _ message: String) {
        banner = Banner(kind: kind, message: message)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 8 : 4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    // MARK: - System events and settings

    private func handleSystemEvent(_ reason: PauseReason, _ active: Bool) {
        switch reason {
        case .onBattery:
            rawOnBattery = active
            engine.setPaused(.onBattery, active && settings.pauseOnBattery)
        case .lowPowerMode:
            rawLowPower = active
            engine.setPaused(.lowPowerMode, active && settings.pauseInLowPowerMode)
        case .systemSleep, .displaysAsleep, .screenLocked, .sessionInactive:
            engine.setPaused(reason, active)
            let suspended = [.systemSleep, .displaysAsleep, .screenLocked, .sessionInactive].contains { engine.pauseReasons.contains($0) }
            rotation.setSystemSuspended(suspended)
            if reason == .systemSleep && !active || reason == .displaysAsleep && !active {
                // Displays may have changed while asleep (e.g. a monitor unplugged); resync.
                displays.refresh()
                reconcileDesktop()
            }
        case .user:
            break
        }
    }

    private func settingsChanged(from old: AppSettings, to new: AppSettings) {
        if old.videoGravity != new.videoGravity { engine.gravity = new.videoGravity }
        if old.showDesktopIcons != new.showDesktopIcons { engine.showDesktopIcons = new.showDesktopIcons }
        if old.pauseWhenDesktopHidden != new.pauseWhenDesktopHidden { engine.pauseWhenHidden = new.pauseWhenDesktopHidden }
        if old.pauseOnBattery != new.pauseOnBattery { engine.setPaused(.onBattery, rawOnBattery && new.pauseOnBattery) }
        if old.pauseInLowPowerMode != new.pauseInLowPowerMode { engine.setPaused(.lowPowerMode, rawLowPower && new.pauseInLowPowerMode) }
        if old.userPaused != new.userPaused { engine.setPaused(.user, new.userPaused) }
        if old.displayMode != new.displayMode || old.mirrorWallpaperID != new.mirrorWallpaperID { reconcileDesktop() }
        if old.showDockIcon != new.showDockIcon { applyDockPolicy() }
        if old.globalHotKeysEnabled != new.globalHotKeysEnabled {
            GlobalHotKeyCenter.shared.setEnabled(new.globalHotKeysEnabled)
            if let error = GlobalHotKeyCenter.shared.lastError, new.globalHotKeysEnabled { showBanner(.error, error) }
        }
        if old.launchAtLogin != new.launchAtLogin { updateLaunchAtLogin(new.launchAtLogin) }
        if old.syncSystemWallpaper != new.syncSystemWallpaper, new.syncSystemWallpaper { syncSystemWallpaperFrames() }
    }

    func applyDockPolicy() {
        // Keep a Dock icon while the main window is visible even if hidden by preference, so the window stays reachable.
        let mainWindowVisible = NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }
        NSApp.setActivationPolicy(settings.showDockIcon || mainWindowVisible ? .regular : .accessory)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            log.log(.info, "app", "Launch at login \(enabled ? "enabled" : "disabled") — \(LaunchAtLoginService.state.description)")
            if LaunchAtLoginService.state == .requiresApproval {
                showBanner(.info, "Approve Driftwall in System Settings › General › Login Items to finish enabling launch at login.")
            }
        } catch {
            log.log(.error, "app", "Launch at login change failed: \(error.localizedDescription)")
            showBanner(.error, "Launch at login could not be changed: \(error.localizedDescription)")
            // Reflect reality rather than the failed request.
            syncLaunchAtLoginState()
        }
    }

    private func syncLaunchAtLoginState() {
        let enabled = [.enabled, .requiresApproval].contains(LaunchAtLoginService.state)
        if settings.launchAtLogin != enabled {
            settingsModel.onChange = nil
            settings.launchAtLogin = enabled
            settingsModel.onChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        }
    }

    /// Sets the static system wallpaper of each display to a still frame of its live wallpaper.
    func syncSystemWallpaperFrames() {
        guard settings.syncSystemWallpaper else { return }
        for state in engine.surfaceStates.values {
            guard let wallpaper = library.wallpaper(state.wallpaperID), let url = library.mediaURL(for: wallpaper.id),
                  let display = displays.display(id: state.displayID), let screen = displays.screen(for: display) else { continue }
            Task {
                do {
                    let frame = try await thumbnails.posterFrame(for: wallpaper.id, mediaURL: url, duration: wallpaper.duration)
                    try SystemWallpaperService.setStaticWallpaper(frame, on: screen)
                    log.log(.info, "wallpaper", "System wallpaper on \(display.name) set to a frame of “\(wallpaper.title)”")
                } catch {
                    log.log(.error, "wallpaper", "Could not set system wallpaper on \(display.name): \(error.localizedDescription)")
                }
            }
        }
    }
}

@MainActor
private final class WeakOwner {
    weak var controller: AppController?
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
