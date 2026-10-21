import DriftwallCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppController.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var navigation = app.navigation
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Theme.Size.sidebarMin, ideal: Theme.Size.sidebarIdeal, max: Theme.Size.sidebarMax)
        } detail: {
            NavigationStack(path: $navigation.path) {
                screen(for: navigation.selection ?? .home)
                    .navigationDestination(for: WallpaperID.self) { id in
                        WallpaperDetailView(wallpaperID: id)
                    }
            }
            .background(Theme.background)
        }
        .searchable(text: searchText, placement: .toolbar, prompt: "Search wallpapers")
        .modifier(SearchFocus(request: navigation.searchFocusRequest))
        .toolbar { MainToolbar() }
        .overlay(alignment: .bottom) { overlays }
        .overlay { if isDropTargeted { DropHint() } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(isPresented: $navigation.showOnboarding) { OnboardingView() }
        .sheet(item: $navigation.playlistNameRequest) { request in PlaylistNameSheet(request: request) }
        .sheet(item: Binding(get: { app.importReport }, set: { app.importReport = $0 })) { report in
            ImportReportView(report: report)
        }
        .onAppear { WindowOpener.openWindowAction = openWindow }
    }

    /// Typing in the toolbar search field always shows Explore results.
    private var searchText: Binding<String> {
        Binding(
            get: { app.navigation.query.text },
            set: { newValue in
                app.navigation.query.text = newValue
                if !newValue.isEmpty, app.navigation.selection != .explore { app.navigation.selection = .explore }
            }
        )
    }

    @ViewBuilder
    private func screen(for item: SidebarItem) -> some View {
        switch item {
        case .home: HomeView()
        case .explore: ExploreView()
        case .favorites: FavoritesView()
        case .recent: RecentView()
        case .library: LibraryView()
        case .displays: DisplaysView()
        case .lockScreen: LockScreenView()
        case .playlists: PlaylistsOverviewView()
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        }
    }

    @ViewBuilder
    private var overlays: some View {
        VStack(spacing: Theme.Space.s) {
            if let progress = app.importProgress {
                HStack(spacing: Theme.Space.m) {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .frame(width: 140)
                    Text("Importing “\(progress.currentName)” — \(progress.completed + 1) of \(progress.total)")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous).strokeBorder(Theme.stroke))
            }
            if let banner = app.banner {
                BannerView(banner: banner) { app.banner = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(Theme.Space.l)
        .animation(Theme.Motion.ease(reduceMotion: reduceMotion), value: app.banner)
        .animation(Theme.Motion.ease(reduceMotion: reduceMotion), value: app.importProgress)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await provider.loadFileURL() { urls.append(url) }
            }
            await app.importFiles(urls)
        }
        return true
    }
}

/// Moves keyboard focus into the toolbar search field when requested (⌘F). The API exists from macOS 15;
/// on macOS 14 ⌘F only switches to Explore.
private struct SearchFocus: ViewModifier {
    let request: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .onChange(of: request) { focused = true }
        } else {
            content
        }
    }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

private struct DropHint: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(Theme.accent)
                Text("Drop to Import")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(".mov, .mp4 and .m4v videos, or folders containing them")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(Theme.Space.xxl)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
            )
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Contextual toolbar: Import is always available; playback controls only while a live wallpaper runs;
/// view options only on pages that show a wallpaper grid.
struct MainToolbar: ToolbarContent {
    @Environment(AppController.self) private var app

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if app.engine.hasActiveWallpaper {
                ControlGroup {
                    Button {
                        app.togglePlayback()
                    } label: {
                        Label(app.settings.userPaused ? "Resume" : "Pause", systemImage: app.settings.userPaused ? "play.fill" : "pause.fill")
                    }
                    .help(app.settings.userPaused ? "Resume the live wallpaper (⌥⌘P)" : "Pause the live wallpaper (⌥⌘P)")
                    Button {
                        app.nextWallpaper()
                    } label: { Label("Next", systemImage: "forward.fill") }
                        .help("Next wallpaper (⌥⌘→)")
                }
                .controlGroupStyle(.navigation)
            }
            if showsViewOptions {
                ViewOptionsMenu()
            }
            Button {
                app.presentImportPanel()
            } label: { Label("Import", systemImage: "plus") }
                .help("Import videos (⌘I)")
        }
    }

    private var showsViewOptions: Bool {
        guard app.navigation.path.isEmpty else { return false }
        switch app.navigation.selection ?? .home {
        case .explore, .favorites, .library: return true
        default: return false
        }
    }
}

struct SidebarView: View {
    @Environment(AppController.self) private var app

    var body: some View {
        @Bindable var navigation = app.navigation
        List(selection: $navigation.selection) {
            Section("Browse") {
                ForEach([SidebarItem.home, .explore, .favorites, .recent], id: \.self) { item in
                    row(item)
                }
            }
            Section("Library") {
                row(.library, badge: app.library.missingWallpapers.count)
                row(.playlists)
                ForEach(app.library.playlists) { playlist in
                    let rotating = app.rotation.settings.playlistID == playlist.id && app.rotation.isActive
                    NavigationLink(value: SidebarItem.playlist(playlist.id)) {
                        Label {
                            HStack(spacing: Theme.Space.xs) {
                                Text(playlist.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if rotating {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.live)
                                        .accessibilityLabel("Rotating")
                                }
                            }
                        } icon: {
                            Image(systemName: "music.note.list")
                        }
                    }
                    .padding(.leading, 10)
                    .contextMenu {
                        Button("Play") { app.startPlaylist(playlist.id) }.disabled(playlist.itemIDs.isEmpty)
                        Button("Rename…") { app.navigation.renamePlaylist(playlist) }
                        Divider()
                        Button("Delete Playlist", role: .destructive) { app.deletePlaylist(playlist.id) }
                    }
                }
            }
            Section("System") {
                row(.displays)
                row(.lockScreen)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                NowPlayingFooter()
                Divider().opacity(0.6)
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .help("Settings (⌘,)")
            }
            .background(Theme.sidebar)
        }
    }

    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        NavigationLink(value: item) {
            Label(item.title, systemImage: item.symbol)
                .badge(badge)
        }
    }
}

/// Compact "now playing" status at the bottom of the sidebar.
struct NowPlayingFooter: View {
    @Environment(AppController.self) private var app

    var body: some View {
        if let current = app.currentWallpaper {
            HStack(spacing: Theme.Space.s) {
                ThumbnailView(wallpaper: current, cornerRadius: 4)
                    .frame(width: 44, height: 25)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        StatusDot(color: isPaused ? Theme.warning : Theme.live)
                        Text(statusText)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    app.togglePlayback()
                } label: {
                    Image(systemName: app.settings.userPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help(app.settings.userPaused ? "Resume" : "Pause")
                .accessibilityLabel(app.settings.userPaused ? "Resume" : "Pause")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { app.navigation.open(current.id) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now showing \(current.title), \(statusText)")
            .accessibilityAddTraits(.isButton)
        }
    }

    private var isPaused: Bool { !app.engine.pauseReasons.isEmpty }

    private var statusText: String {
        let count = app.engine.surfaceStates.count
        if let reason = PauseReason.allCases.first(where: app.engine.pauseReasons.contains) { return reason.label }
        return count > 1 ? "Live on \(count) displays" : "Live"
    }
}

struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let report: ImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(report.imported.isEmpty ? "Import Failed" : "Import Finished with Problems").font(.title2.weight(.semibold))
            if !report.imported.isEmpty {
                Label("\(report.imported.count) video(s) imported", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.live)
            }
            Text("These files could not be imported:").foregroundStyle(.secondary)
            List(report.failures, id: \.name) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.name).font(.headline)
                    Text(failure.reason).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 380)
    }
}
