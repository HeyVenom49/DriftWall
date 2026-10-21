import AppKit
import DriftwallCore
import SwiftUI

@main
struct DriftwallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let app = AppController.shared

    var body: some Scene {
        Window("Driftwall", id: "main") {
            RootView()
                .environment(app)
                .preferredColorScheme(app.settings.appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
                .preferredColorScheme(app.settings.appearance.colorScheme)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(app)
        } label: {
            Image(systemName: app.engine.hasActiveWallpaper && !app.engine.isPaused ? "play.desktopcomputer" : "desktopcomputer")
                .accessibilityLabel("Driftwall")
        }
        .menuBarExtraStyle(.menu)
    }
}

extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--smoke-test") {
                SmokeTest.run(AppController.shared)
                return
            }
            if let index = CommandLine.arguments.firstIndex(of: "--ui-snapshots"), index + 1 < CommandLine.arguments.count {
                UISnapshots.run(AppController.shared, outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                return
            }
            let app = AppController.shared
            app.start()
            if !app.settings.hasCompletedOnboarding { app.navigation.showOnboarding = true }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
                // Drop the Dock icon after the main window closes when the user prefers a menu-bar-only app.
                DispatchQueue.main.async { MainActor.assumeIsolated { AppController.shared.applyDockPolicy() } }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppController.shared.applyDockPolicy() }
            }
            if !app.settings.openMainWindowAtLaunch && app.settings.hasCompletedOnboarding {
                DispatchQueue.main.async {
                    NSApp.windows.filter { $0.isMainAppWindow }.forEach { $0.close() }
                }
            }
        }
    }

    /// The live wallpaper keeps running after the main window closes; quit from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { WindowOpener.openMain() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppController.shared.shutdown() }
    }
}

/// Opens or focuses the main window from places that do not have SwiftUI's `openWindow` (AppKit callbacks).
@MainActor
enum WindowOpener {
    static var openWindowAction: OpenWindowAction?

    static func openMain() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.isMainAppWindow }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppCommands: Commands {
    let app: AppController

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Videos…") { app.presentImportPanel() }
                .keyboardShortcut("i", modifiers: .command)
            Button("New Playlist…") {
                WindowOpener.openMain()
                app.navigation.newPlaylist()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Playback") {
            Button(app.settings.userPaused ? "Resume Wallpaper" : "Pause Wallpaper") { app.togglePlayback() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next Wallpaper") { app.nextWallpaper() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Wallpaper") { app.previousWallpaper() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("Stop Live Wallpaper") { app.clearAllWallpapers() }
                .disabled(!app.engine.hasActiveWallpaper)
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(Self.shortcutItems.enumerated()), id: \.offset) { offset, item in
                Button(item.title) { app.navigation.show(item) }
                    .keyboardShortcut(KeyEquivalent(Character(String(offset + 1))), modifiers: .command)
            }
            Divider()
            Button("Search") { app.navigation.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
    }

    static let shortcutItems: [SidebarItem] = [.home, .explore, .favorites, .recent, .playlists, .library, .displays, .lockScreen]
}

extension NSWindow {
    /// The SwiftUI `Window(id: "main")` scene's window (SwiftUI may append a suffix to the identifier).
    var isMainAppWindow: Bool { identifier?.rawValue.hasPrefix("main") ?? false }
}
