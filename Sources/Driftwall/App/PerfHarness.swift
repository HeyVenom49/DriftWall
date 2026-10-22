import AppKit
import DriftwallCore
import QuartzCore

/// Developer tool for repeatable performance measurements (no Instruments needed):
///
///     DRIFTWALL_DATA_DIR=<scratch> Driftwall --perf-scenario <name> [--perf-seconds 30] [--perf-library 400]
///
/// Starts the app normally, waits until the desktop plays, puts the UI into one scenario, prints
/// `PERF READY`, holds it for `--perf-seconds` while a watchdog measures main-thread stalls, then prints
/// a report and quits. CPU, energy and memory are measured from outside (top / ps / footprint) while
/// the scenario holds. Scenarios drive the same models the UI uses; no events are injected system-wide.
///
/// - `background`     main window closed: only the desktop wallpaper runs
/// - `paused`         main window closed, wallpaper paused by the user
/// - `home`           main window on Home
/// - `detail`         detail page of the wallpaper on the main display (its preview plays)
/// - `detail-hidden`  the same detail page, window ordered out (as when covered or on another Space)
/// - `lockscreen`     Lock Screen page (its preview plays)
/// - `scroll`         My Videos, scrolled up and down continuously (use `--perf-library` for a big grid)
/// - `navigate`       cycles through every sidebar screen and a detail page, one per second
/// - `pause-toggle`   My Videos grid on screen while the wallpaper pauses and resumes every 0.5 s
/// - `type`           types into search and deletes again (one key every 120 ms) on Explore
/// - `covered`        main window fills one display's visible area, as a zoomed app window would
///                    (`--perf-cover <screen name prefix>`, `--perf-cover-builtin`, else the focused screen)
///                    and the desktop surfaces' states are printed
/// - `switch`         re-applies alternating wallpapers and times how long each takes to play
@MainActor
enum PerfHarness {
    static func run(_ app: AppController, scenario: String, arguments: [String]) {
        guard ProcessInfo.processInfo.environment["DRIFTWALL_DATA_DIR"] != nil else {
            print("PERF: refusing to run without DRIFTWALL_DATA_DIR")
            exit(2)
        }
        let seconds = Double(value(after: "--perf-seconds", in: arguments) ?? "") ?? 30
        let libraryCount = Int(value(after: "--perf-library", in: arguments) ?? "") ?? 0
        Task {
            let launched = processStartDate()
            app.start()
            app.settings.hasCompletedOnboarding = true
            // The real pointer may rest over the window; hover previews would make runs depend on it.
            app.settings.hoverPreviews = false
            if libraryCount > 0 { addSyntheticWallpapers(libraryCount, to: app) }
            let playing = await waitUntil(timeout: 20) { !app.engine.surfaceStates.isEmpty && app.engine.surfaceStates.values.allSatisfy { $0.status == .playing } }
            print(String(format: "PERF startup_to_playing_s=%.3f playing=%@ displays=%d", Date().timeIntervalSince(launched), playing ? "yes" : "no", app.displays.displays.count))

            await setUp(scenario, app)
            try? await Task.sleep(for: .seconds(3))
            let watchdog = StallWatchdog()
            watchdog.start()
            print("PERF READY scenario=\(scenario) decoders: \(PlaybackDiagnostics.summary)")
            fflush(stdout)
            switch scenario {
            case "scroll": await scroll(for: seconds)
            case "switch": await switchWallpapers(app, for: seconds)
            case "navigate": await navigate(app, for: seconds)
            case "pause-toggle": await togglePause(app, for: seconds)
            case "type": await typeSearch(app, for: seconds)
            default: try? await Task.sleep(for: .seconds(seconds))
            }
            print("PERF main_thread \(watchdog.stop())")
            print("PERF END decoders: \(PlaybackDiagnostics.summary)")
            fflush(stdout)
            app.shutdown()
            exit(0)
        }
    }

    // MARK: - Scenarios

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.isMainAppWindow } }

    private static func setUp(_ scenario: String, _ app: AppController) async {
        if mainWindow == nil { WindowOpener.openMain() }
        try? await Task.sleep(for: .seconds(1))
        switch scenario {
        case "background":
            mainWindow?.close()
        case "paused":
            app.settings.userPaused = true
            mainWindow?.close()
        case "home":
            app.navigation.show(.home)
        case "detail", "detail-hidden":
            app.navigation.show(.home)
            if let id = app.currentWallpaper?.id { app.navigation.open(id) }
            if scenario == "detail-hidden" {
                try? await Task.sleep(for: .seconds(2))
                mainWindow?.orderOut(nil)
            }
        case "lockscreen":
            app.navigation.show(.lockScreen)
        case "scroll":
            mainWindow?.setFrame(NSRect(x: 80, y: 80, width: 1240, height: 800), display: true)
            app.navigation.show(.library)
        case "switch":
            mainWindow?.close()
        case "navigate":
            app.navigation.show(.home)
        case "covered":
            // `--perf-cover-builtin` covers the built-in display; otherwise the screen with keyboard focus.
            let builtIn = NSScreen.screens.first { DisplayService.directID(of: $0).map { CGDisplayIsBuiltin($0) != 0 } == true }
            let named = value(after: "--perf-cover", in: CommandLine.arguments).flatMap { name in NSScreen.screens.first { $0.localizedName.hasPrefix(name) } }
            if let screen = named ?? (CommandLine.arguments.contains("--perf-cover-builtin") ? builtIn : NSScreen.main) {
                print("PERF covering \(screen.localizedName)")
                mainWindow?.setFrame(screen.visibleFrame, display: true)
            }
            mainWindow?.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(2))
            print("PERF pauseWhenHidden=\(app.engine.pauseWhenHidden) setting=\(app.settings.pauseWhenDesktopHidden) reasons=\(app.engine.pauseReasons)")
            for state in app.engine.surfaceStates.values.sorted(by: { $0.displayName < $1.displayName }) {
                print("PERF surface \(state.displayName): \(state.status.label)")
            }
        case "pause-toggle":
            mainWindow?.setFrame(NSRect(x: 80, y: 80, width: 1240, height: 800), display: true)
            app.navigation.show(.library)
        case "type":
            mainWindow?.setFrame(NSRect(x: 80, y: 80, width: 1240, height: 800), display: true)
            app.navigation.show(.explore)
        default:
            print("PERF: unknown scenario \(scenario)")
            exit(2)
        }
    }

    /// Scrolls the biggest scroll view in the main window 30 pt per frame, reversing at either end.
    private static func scroll(for seconds: Double) async {
        guard let root = mainWindow?.contentView, let scrollView = largestScrollView(in: root),
              let document = scrollView.documentView else {
            print("PERF: no scroll view found")
            return
        }
        print(String(format: "PERF scroll content_height=%.0f viewport=%.0f", document.frame.height, scrollView.contentView.bounds.height))
        var step: CGFloat = 30
        var frames = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let clip = scrollView.contentView
            let maxY = max(0, document.frame.height - clip.bounds.height)
            var y = clip.bounds.origin.y + step
            if y >= maxY || y <= 0 { step = -step; y = min(max(0, y), maxY) }
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            frames += 1
            try? await Task.sleep(for: .milliseconds(16))
        }
        print("PERF scroll steps=\(frames)")
    }

    private static func largestScrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ v: NSView) {
            if let s = v as? NSScrollView, s.hasVerticalScroller || s.documentView.map({ $0.frame.height > s.bounds.height }) == true,
               s.bounds.height * s.bounds.width > (best.map { $0.bounds.height * $0.bounds.width } ?? 0) { best = s }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    /// Visits each screen in turn; the watchdog reports how long building each one blocks the UI.
    private static func navigate(_ app: AppController, for seconds: Double) async {
        let screens: [SidebarItem] = [.explore, .favorites, .recent, .library, .displays, .lockScreen, .playlists, .home]
        let end = Date().addingTimeInterval(seconds)
        var visits = 0
        while Date() < end {
            if visits % (screens.count + 1) == screens.count, let id = app.currentWallpaper?.id {
                app.navigation.open(id)
            } else {
                app.navigation.show(screens[visits % (screens.count + 1) % screens.count])
            }
            visits += 1
            try? await Task.sleep(for: .seconds(1))
        }
        print("PERF navigate visits=\(visits)")
    }

    private static func togglePause(_ app: AppController, for seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        var toggles = 0
        while Date() < end {
            app.togglePlayback()
            toggles += 1
            try? await Task.sleep(for: .milliseconds(500))
        }
        if app.settings.userPaused { app.togglePlayback() }
        print("PERF pause-toggle toggles=\(toggles)")
    }

    /// Types "perf 12" then deletes it, one keystroke every 120 ms, through the same query the field binds.
    private static func typeSearch(_ app: AppController, for seconds: Double) async {
        let word = Array("perf 12")
        let end = Date().addingTimeInterval(seconds)
        var keys = 0
        while Date() < end {
            for n in Array(1...word.count) + Array((0..<word.count).reversed()) {
                app.navigation.query.text = String(word.prefix(n))
                keys += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        print("PERF type keystrokes=\(keys)")
    }

    /// Alternates between two available wallpapers on all displays and times apply → playing.
    private static func switchWallpapers(_ app: AppController, for seconds: Double) async {
        let candidates = app.library.wallpapers.filter { app.library.isAvailable($0.id) }.map(\.id)
        guard candidates.count >= 2 else { print("PERF: need two wallpapers"); return }
        var times: [Double] = []
        let end = Date().addingTimeInterval(seconds)
        var index = 0
        while Date() < end {
            let id = candidates[index % 2]
            index += 1
            let start = CACurrentMediaTime()
            app.apply(id, target: .allDisplays)
            if await waitUntil(timeout: 10, { app.engine.surfaceStates.values.allSatisfy { $0.wallpaperID == id && $0.status == .playing } }) {
                times.append(CACurrentMediaTime() - start)
            }
            try? await Task.sleep(for: .seconds(2.5))
        }
        let sorted = times.sorted()
        if !sorted.isEmpty {
            print(String(format: "PERF switch count=%d median_ms=%.0f max_ms=%.0f", sorted.count, sorted[sorted.count / 2] * 1000, sorted.last! * 1000))
        }
    }

    private static func addSyntheticWallpapers(_ count: Int, to app: AppController) {
        let samples = app.library.wallpapers.filter { $0.source == .bundled }.compactMap { app.library.mediaURL(for: $0.id) }
        guard !samples.isEmpty else { return }
        for n in 0..<count where app.library.wallpaper("perf.\(n)") == nil {
            let url = samples[n % samples.count]
            app.library.add(Wallpaper(id: "perf.\(n)", title: "Perf \(n)", category: "Perf", source: .imported,
                                      mediaPath: url.path, duration: 10, pixelWidth: 1920, pixelHeight: 1080,
                                      frameRate: 30, codec: "HEVC", fileSize: 1, importedAt: Date(timeIntervalSince1970: Double(n))))
        }
    }

    // MARK: - Helpers

    private static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func processStartDate() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}

/// Measures how long the main queue takes to run a block posted every 10 ms from a background thread.
/// Latency above a frame (16.7 ms) means the UI could not have drawn on time.
final class StallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var running = false

    func start() {
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [self] in
            while isRunning {
                let posted = CACurrentMediaTime()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    self.record(CACurrentMediaTime() - posted)
                    done.signal()
                }
                done.wait()
                Thread.sleep(forTimeInterval: 0.010)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() -> String {
        lock.lock(); running = false; let values = latencies.sorted(); lock.unlock()
        guard !values.isEmpty else { return "no samples" }
        func ms(_ v: Double) -> String { String(format: "%.1f", v * 1000) }
        let p = { (q: Double) in values[min(values.count - 1, Int(Double(values.count) * q))] }
        let over = { (limit: Double) in values.filter { $0 > limit }.count }
        return "samples=\(values.count) p50_ms=\(ms(p(0.5))) p99_ms=\(ms(p(0.99))) max_ms=\(ms(values.last!)) over16ms=\(over(0.0167)) over50ms=\(over(0.05)) over100ms=\(over(0.1))"
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func record(_ latency: Double) { lock.lock(); latencies.append(latency); lock.unlock() }
}
