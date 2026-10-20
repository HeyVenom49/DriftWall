import DriftwallCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppController.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var navigation = app.navigation
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
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
        .toolbar { MainToolbar() }
        .overlay(alignment: .bottom) { overlays }
        .overlay { if isDropTargeted { DropHint() } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(isPresented: $navigation.showOnboarding) { OnboardingView() }
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
                        .frame(width: 160)
                    Text("Importing \(progress.currentName) (\(progress.completed + 1) of \(progress.total))")
                        .font(.callout)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let banner = app.banner {
                BannerView(banner: banner) { app.banner = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(Theme.Space.l)
        .animation(.spring(duration: 0.35), value: app.banner)
        .animation(.easeOut, value: app.importProgress)
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
            Color.black.opacity(0.35)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 44, weight: .light))
                Text("Drop videos to import").font(.title2.weight(.semibold))
                Text(".mov, .mp4 and .m4v files or folders").foregroundStyle(.secondary)
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppController.self) private var app

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if app.engine.hasActiveWallpaper {
                Button {
                    app.previousWallpaper()
                } label: { Label("Previous", systemImage: "backward.fill") }
                    .help("Previous wallpaper")
                Button {
                    app.togglePlayback()
                } label: {
                    Label(app.settings.userPaused ? "Resume" : "Pause", systemImage: app.settings.userPaused ? "play.fill" : "pause.fill")
                }
                .help(app.settings.userPaused ? "Resume the live wallpaper" : "Pause the live wallpaper")
                Button {
                    app.nextWallpaper()
                } label: { Label("Next", systemImage: "forward.fill") }
                    .help("Next wallpaper")
            }
            Button {
                app.presentImportPanel()
            } label: { Label("Import", systemImage: "plus") }
                .help("Import videos (⌘I)")
        }
    }
}

struct SidebarView: View {
    @Environment(AppController.self) private var app

    var body: some View {
        @Bindable var navigation = app.navigation
        List(selection: $navigation.selection) {
            Section {
                ForEach([SidebarItem.home, .explore, .favorites, .recent], id: \.self) { item in
                    row(item)
                }
            }
            Section("Library") {
                row(.library, badge: app.library.missingWallpapers.count)
                row(.displays)
            }
            Section {
                NavigationLink(value: SidebarItem.playlists) {
                    Label("All Playlists", systemImage: SidebarItem.playlists.symbol)
                }
                ForEach(app.library.playlists) { playlist in
                    NavigationLink(value: SidebarItem.playlist(playlist.id)) {
                        HStack {
                            Label(playlist.name, systemImage: app.rotation.settings.playlistID == playlist.id && app.rotation.isActive ? "arrow.triangle.2.circlepath" : "music.note.list")
                            Spacer()
                            Text("\(playlist.itemIDs.count)").foregroundStyle(.secondary).font(.meta)
                        }
                    }
                    .contextMenu {
                        Button("Play") { app.startPlaylist(playlist.id) }
                        Button("Delete Playlist", role: .destructive) { app.deletePlaylist(playlist.id) }
                    }
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button {
                        if let playlist = app.library.createPlaylist(named: "") { app.navigation.show(.playlist(playlist.id)) }
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("New Playlist")
                        .accessibilityLabel("New Playlist")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { NowPlayingFooter() }
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
                ThumbnailView(wallpaper: current, cornerRadius: 6)
                    .frame(width: 54, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    app.togglePlayback()
                } label: {
                    Image(systemName: app.settings.userPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.settings.userPaused ? "Resume" : "Pause")
            }
            .padding(10)
            .background(Theme.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture { app.navigation.open(current.id) }
        }
    }

    private var statusText: String {
        let count = app.engine.surfaceStates.count
        if let reason = PauseReason.allCases.first(where: app.engine.pauseReasons.contains) { return reason.label }
        return count > 1 ? "Live on \(count) displays" : "Live wallpaper"
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
