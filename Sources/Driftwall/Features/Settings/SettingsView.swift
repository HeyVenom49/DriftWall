import DriftwallCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintbrush") }
            PlaybackSettings().tabItem { Label("Playback", systemImage: "play.rectangle") }
            DisplaySettings().tabItem { Label("Displays", systemImage: "display.2") }
            LockScreenSettings().tabItem { Label("Lock Screen", systemImage: "lock.display") }
            LibrarySettings().tabItem { Label("Library", systemImage: "externaldrive") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640)
        .frame(minHeight: 460)
    }
}

/// Binding into `AppController.settings` for a key path.
@MainActor
private func setting<T>(_ app: AppController, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { app.settings[keyPath: keyPath] }, set: { app.settings[keyPath: keyPath] = $0 })
}

private struct GeneralSettings: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Form {
            Section {
                Toggle("Launch Driftwall at login", isOn: setting(app, \.launchAtLogin))
                HStack {
                    Text(LaunchAtLoginService.state.description).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if LaunchAtLoginService.state == .requiresApproval {
                        Button("Open Login Items…") { LaunchAtLoginService.openSystemSettings() }
                    }
                }
                Toggle("Restore live wallpapers when Driftwall starts", isOn: setting(app, \.resumeOnLaunch))
                Toggle("Open the main window at launch", isOn: setting(app, \.openMainWindowAtLaunch))
                Toggle("Show Dock icon", isOn: setting(app, \.showDockIcon))
                Text("Without a Dock icon, Driftwall stays available from the menu bar. Closing the window never stops the live wallpaper; use Quit for that.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Show Welcome Guide") {
                    app.navigation.showOnboarding = true
                    WindowOpener.openMain()
                }
            }
            SystemChangesSection()
        }
        .formStyle(.grouped)
    }
}

/// What Driftwall changed outside its own folders, how it's undone if the app is deleted, and undoing
/// it now.
private struct SystemChangesSection: View {
    @Environment(AppController.self) private var app
    @State private var confirmUndo = false
    @State private var undoing = false

    var body: some View {
        let changes = app.systemChanges
        Section("Changes Outside Driftwall") {
            if changes.isEmpty {
                Text("Driftwall hasn’t changed anything outside its own folders.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(changes, id: \.self) { change in
                    Label(change, systemImage: "arrow.uturn.backward.circle")
                }
                HStack {
                    Spacer()
                    if undoing { ProgressView().controlSize(.small) }
                    Button("Undo All System Changes…") { confirmUndo = true }
                        .disabled(undoing)
                }
            }
            Text(CleanupAgentService.isInstalled
                 ? "If you delete Driftwall, a small cleanup task puts these back on its own about 10 minutes later, then removes itself. Before deleting Driftwall on purpose, you can also undo them here."
                 : "When Driftwall changes something outside its own folders, it also installs a small cleanup task that puts it back if you delete the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Undo all system changes?", isPresented: $confirmUndo) {
            Button("Undo All System Changes") {
                Task {
                    undoing = true
                    await app.undoAllSystemChanges()
                    undoing = false
                }
            }
        } message: {
            Text("Apple’s original Aerial comes back, Driftwall’s screen saver is removed, your original desktop pictures are set again, and Driftwall stops opening at login. Your library, favorites and playlists stay.")
        }
    }
}

private struct PlaybackSettings: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Form {
            Section("Video") {
                Picker("Scaling", selection: setting(app, \.videoGravity)) {
                    ForEach(VideoGravity.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show desktop icons above the wallpaper", isOn: setting(app, \.showDesktopIcons))
                Toggle("Play previews when hovering over wallpapers", isOn: setting(app, \.hoverPreviews))
            }
            Section("Power") {
                Toggle("Pause when the desktop is completely covered", isOn: setting(app, \.pauseWhenDesktopHidden))
                Toggle("Pause on battery power", isOn: setting(app, \.pauseOnBattery))
                Toggle("Pause in Low Power Mode", isOn: setting(app, \.pauseInLowPowerMode))
                Text("Playback always pauses while the Mac or its displays sleep, the screen is locked, or another user is active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System Wallpaper") {
                Toggle("Match system wallpaper to a frame of the live wallpaper", isOn: setting(app, \.syncSystemWallpaper))
                    .disabled(app.isAerialOn)
                if app.isAerialOn {
                    Text("Off while the Animated Lock Screen is on: a still picture would replace its Aerial wallpaper.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                Text("When on, Driftwall replaces each display’s macOS desktop picture with a still frame so Mission Control and your desktop after quitting look consistent. Your previous desktop picture is not restored automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RotationSection()
            Section("Status") {
                LabeledContent("Live displays", value: "\(app.engine.surfaceStates.count)")
                LabeledContent("Active decoders", value: "\(app.engine.activePlayerCount)")
                LabeledContent("Paused because", value: app.engine.pauseReasons.isEmpty ? "—" : app.engine.pauseReasons.map(\.label).sorted().joined(separator: ", "))
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplaySettings: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Form {
            Section {
                Picker("Wallpaper layout", selection: setting(app, \.displayMode)) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("“Set as Wallpaper” applies to", selection: setting(app, \.defaultTarget)) {
                    Text("All Displays").tag(DisplayTarget.allDisplays)
                    Text("Main Display").tag(DisplayTarget.mainDisplay)
                    ForEach(app.displays.displays) { display in
                        Text(display.name).tag(DisplayTarget.display(id: display.id))
                    }
                    if case .display(let id) = app.settings.defaultTarget, app.displays.display(id: id) == nil {
                        Text("Disconnected display (uses main until it returns)").tag(app.settings.defaultTarget)
                    }
                }
            }
            Section("Connected") {
                ForEach(app.displays.displays) { display in
                    LabeledContent(display.name, value: "\(display.resolutionText)\(display.isMain ? " · main" : "")")
                }
            }
            Section {
                Button("Stop Live Wallpaper on All Displays") { app.clearAllWallpapers() }
                    .disabled(!app.engine.hasActiveWallpaper)
            }
        }
        .formStyle(.grouped)
    }
}

/// Playlist rotation, shown in the Playback pane.
private struct RotationSection: View {
    @Environment(AppController.self) private var app

    var body: some View {
        let rotation = app.rotation
        Group {
            Section("Playlist Rotation") {
                Picker("Playlist", selection: Binding(get: { rotation.isActive ? rotation.settings.playlistID : nil }, set: { id in
                    if let id { app.startPlaylist(id) } else { rotation.stop() }
                })) {
                    Text("Off").tag(String?.none)
                    ForEach(app.library.playlists) { Text($0.name).tag(String?.some($0.id)) }
                }
                Picker("Change wallpaper every", selection: Binding(get: { rotation.settings.interval }, set: { rotation.setInterval($0) })) {
                    ForEach(RotationSettings.intervalPresets, id: \.self) { Text(RotationSettings.label(for: $0)).tag($0) }
                }
                Toggle("Shuffle", isOn: Binding(get: { rotation.settings.shuffle }, set: { rotation.setShuffle($0) }))
                RotationDisplayPicker()
                Toggle("Paused", isOn: Binding(get: { rotation.settings.isPaused }, set: { rotation.setPaused($0) }))
                    .disabled(!rotation.isActive)
                Text("Rotation changes only the display chosen in “Show on”. It doesn’t advance while the Mac is asleep or locked, and skips playlist items whose video file is missing.")
                    .font(.caption).foregroundStyle(.secondary)
                if app.library.playlists.isEmpty {
                    Text("Create a playlist in the main window to enable rotation.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Lock-screen preferences and status; the full setup lives on the Lock Screen page.
private struct LockScreenSettings: View {
    @Environment(AppController.self) private var app

    var body: some View {
        let lock = app.settings.lockScreen
        Form {
            Section("Animated Lock Screen") {
                LabeledContent("Status") {
                    if let manifest = app.aerial.manifest {
                        Text("On — plays “\(manifest.wallpaperTitle)” as “\(manifest.slotName)”")
                    } else {
                        Text("Off").foregroundStyle(.secondary)
                    }
                }
                if let missing = app.aerialMissingDisplays, !missing.isEmpty, app.aerial.manifest != nil {
                    Text("Not playing on \(missing.map(\.name).joined(separator: ", ")): that display shows another wallpaper.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
                Text("Plays your wallpaper on the lock screen itself, behind the password prompt, by replacing your copy of one Apple Aerial wallpaper. Apple’s original is backed up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Screen Saver Video") {
                Toggle("Play video while the screen saver runs", isOn: Binding(get: { lock.isEnabled }, set: { app.setLockScreenEnabled($0) }))
                    .disabled(!app.lockScreen.isSupported)
                LabeledContent("Status", value: app.lockScreen.status.summary)
                LabeledContent("Password required", value: app.passwordDelay.map { $0.replacingOccurrences(of: "delay is ", with: "") } ?? "Unknown")
                Toggle("Also use a still frame as the macOS wallpaper picture",
                       isOn: Binding(get: { lock.setsStillSystemPicture }, set: { app.setLockScreenStillPicture($0) }))
                    .disabled(app.isAerialOn || !lock.isEnabled)
                if app.isAerialOn {
                    Text("Off while the Animated Lock Screen is on: a still picture would replace its Aerial wallpaper.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Section {
                Button("Open Lock Screen Setup…") {
                    app.navigation.show(.lockScreen)
                    WindowOpener.openMain()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            app.refreshLockScreen()
            app.refreshAerial()
        }
    }
}

private struct LibrarySettings: View {
    @Environment(AppController.self) private var app
    @State private var cacheSize: Int64 = 0
    @State private var mediaSize: Int64 = 0

    var body: some View {
        Form {
            Section("Importing") {
                Toggle("Copy imported videos into Driftwall’s library", isOn: setting(app, \.copyImportsIntoLibrary))
                Text(app.settings.copyImportsIntoLibrary
                     ? "New imports are copied, so they keep working if the original is moved or deleted. Uses extra disk space."
                     : "New imports are referenced where they are. Driftwall follows files you rename or move on the same disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                LabeledContent("Wallpapers", value: "\(app.library.wallpapers.count) (\(app.library.importedWallpapers.count) imported)")
                LabeledContent("Missing files", value: "\(app.library.missingWallpapers.count)")
                LabeledContent("Copied videos", value: mediaSize.formattedBytes)
                HStack {
                    Button("Check Files") { app.rescanLibrary() }
                    Button("Show Library Folder") { NSWorkspace.shared.activateFileViewerSelecting([app.paths.supportDirectory]) }
                }
            }
            Section("Preview Cache") {
                LabeledContent("Preview images", value: cacheSize.formattedBytes)
                Button("Clear Cache") {
                    Task {
                        await app.clearThumbnailCache()
                        await refreshSizes()
                    }
                }
                Text("Cached previews are regenerated automatically when needed. Clearing the cache never affects your videos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshSizes() }
    }

    /// Walks both folders off the main thread; the media folder can hold many large copies.
    private func refreshSizes() async {
        let thumbnails = app.thumbnails, media = app.paths.mediaDirectory
        let sizes = await Task.detached(priority: .utility) { (thumbnails.cacheSize(), ThumbnailService.directorySize(media)) }.value
        (cacheSize, mediaSize) = sizes
    }
}

private struct AppearanceSettings: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Form {
            Picker("Appearance", selection: setting(app, \.appearance)) {
                ForEach(AppearancePreference.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Grid size", selection: setting(app, \.gridDensity)) {
                ForEach(GridDensity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Form {
            Section("Global (work in any app)") {
                Toggle("Enable global shortcuts", isOn: setting(app, \.globalHotKeysEnabled))
                ForEach(GlobalHotKeyCenter.Action.allCases, id: \.rawValue) { action in
                    LabeledContent(action.title, value: action.display)
                }
                if let error = GlobalHotKeyCenter.shared.lastError, app.settings.globalHotKeysEnabled {
                    Text(error).font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Section("In Driftwall") {
                LabeledContent("Import videos", value: "⌘I")
                LabeledContent("New playlist", value: "⇧⌘N")
                LabeledContent("Pause / resume wallpaper", value: "⌥⌘P")
                LabeledContent("Next / previous wallpaper", value: "⌥⌘→ / ⌥⌘←")
                LabeledContent("Search", value: "⌘F")
                LabeledContent("Go to Home … Lock Screen", value: "⌘1 … ⌘8")
                LabeledContent("Open focused wallpaper (grid)", value: "↩")
                LabeledContent("Set focused wallpaper (grid)", value: "Space")
                LabeledContent("Move between wallpapers", value: "Tab / ⇧Tab")
                LabeledContent("Set as wallpaper (detail)", value: "⌘↩")
                LabeledContent("Favorite (detail)", value: "⌘L")
                LabeledContent("Play / pause preview (detail)", value: "Space")
            }
        }
        .formStyle(.grouped)
    }
}

/// Version, then the diagnostics that stay on this Mac.
private struct AboutSettings: View {
    @Environment(AppController.self) private var app
    /// Measured off the main thread when the pane opens; walking the cache folder in `body` would
    /// repeat it on every new log entry.
    @State private var cacheSize: Int64?

    var body: some View {
        let _ = app.diagnosticsEpoch
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Driftwall").font(.title3.weight(.semibold))
                    Text("Version \(Bundle.main.shortVersion) · Live video wallpapers for your Mac").font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Diagnostics").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Version").foregroundStyle(.secondary); Text(Bundle.main.shortVersion) }
                GridRow { Text("macOS").foregroundStyle(.secondary); Text(ProcessInfo.processInfo.operatingSystemVersionString) }
                GridRow { Text("Data folder").foregroundStyle(.secondary); Text(app.paths.supportDirectory.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("Playback").foregroundStyle(.secondary); Text(playbackSummary) }
                GridRow { Text("Current").foregroundStyle(.secondary); Text(app.currentWallpaper?.title ?? "None") }
                GridRow { Text("Missing files").foregroundStyle(.secondary); Text("\(app.library.missingWallpapers.count)") }
                GridRow { Text("Preview cache").foregroundStyle(.secondary); Text(cacheSize?.formattedBytes ?? "…") }
                GridRow { Text("Decoders").foregroundStyle(.secondary); Text(PlaybackDiagnostics.summary) }
            }
            .font(.callout)
            Text("Recent events").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(app.log.snapshot.reversed()) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                            Text(entry.level.rawValue.uppercased()).foregroundStyle(color(entry.level)).frame(width: 60, alignment: .leading)
                            Text("\(entry.category): \(entry.message)").textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            HStack {
                Text("Diagnostics stay on this Mac. Nothing is sent anywhere.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.log.exportText(), forType: .string)
                }
                Button("Clear") { app.log.clear() }
            }
        }
        .padding(20)
        .frame(minHeight: 420)
        .task {
            let thumbnails = app.thumbnails
            cacheSize = await Task.detached(priority: .utility) { thumbnails.cacheSize() }.value
        }
    }

    private var playbackSummary: String {
        let engine = app.engine
        if engine.surfaceStates.isEmpty { return "No live wallpaper" }
        let states = engine.surfaceStates.values.map { "\($0.displayName): \($0.status.label)" }.sorted()
        return states.joined(separator: "; ")
    }

    private func color(_ level: DiagnosticsLog.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}
