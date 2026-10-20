import DriftwallCore
import SwiftUI

struct WallpaperDetailView: View {
    @Environment(AppController.self) private var app
    let wallpaperID: WallpaperID
    @State private var preview = PreviewPlayer()
    @State private var target: DisplayTarget = .allDisplays
    @State private var confirmRemove = false

    var body: some View {
        if let wallpaper = app.library.wallpaper(wallpaperID) {
            content(wallpaper)
                .navigationTitle(wallpaper.title)
                .onAppear {
                    app.library.recordViewed(wallpaper.id)
                    target = app.settings.defaultTarget
                }
        } else {
            EmptyStateView(symbol: "questionmark.square.dashed", title: "Wallpaper not found",
                           message: "This wallpaper was removed from your library.") {
                Button("Back to Home") { app.navigation.show(.home) }
            }
        }
    }

    private func content(_ wallpaper: Wallpaper) -> some View {
        let availability = app.library.availabilityOf(wallpaper.id)
        let liveOn = app.displaysShowing(wallpaper.id)
        let isFavorite = app.library.isFavorite(wallpaper.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                previewArea(wallpaper, availability: availability)

                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(spacing: 6) {
                            Badge(text: wallpaper.category.uppercased())
                            Badge(text: wallpaper.source.displayName.uppercased())
                            if !liveOn.isEmpty { LiveBadge() }
                        }
                        Text(wallpaper.title).font(.system(size: 30, weight: .bold))
                        if !wallpaper.summary.isEmpty {
                            Text(wallpaper.summary).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !wallpaper.tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(wallpaper.tags, id: \.self) { tag in
                                    Button("#\(tag)") {
                                        app.navigation.query = SearchQuery(text: tag)
                                        app.navigation.show(.explore)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.callout)
                                    .foregroundStyle(Theme.accent)
                                    .help("Search for “\(tag)”")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    actionPanel(wallpaper, availability: availability, isFavorite: isFavorite)
                        .frame(width: 300)
                }

                Panel {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: Theme.Space.l) {
                        MetadataItem(label: "Duration", value: wallpaper.durationText)
                        MetadataItem(label: "Resolution", value: wallpaper.resolutionText)
                        MetadataItem(label: "Quality", value: wallpaper.resolutionClass.label)
                        MetadataItem(label: "Frame Rate", value: wallpaper.frameRate > 0 ? String(format: "%.0f fps", wallpaper.frameRate) : "—")
                        MetadataItem(label: "Codec", value: wallpaper.codec ?? "—")
                        MetadataItem(label: "File Size", value: wallpaper.fileSize > 0 ? wallpaper.fileSize.formattedBytes : "—")
                        MetadataItem(label: "Added", value: wallpaper.importedAt.formatted(date: .abbreviated, time: .omitted))
                        MetadataItem(label: "Last Used", value: wallpaper.lastUsedAt?.relativeDescription ?? "Never")
                        MetadataItem(label: "Times Applied", value: "\(wallpaper.useCount)")
                        MetadataItem(label: "Source", value: wallpaper.creator ?? wallpaper.source.displayName)
                        MetadataItem(label: "File", value: availability.statusText)
                    }
                }
                if wallpaper.source == .imported {
                    Text(wallpaper.mediaPath)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(Theme.Space.page)
        }
        .confirmationDialog("Remove “\(wallpaper.title)” from your library?", isPresented: $confirmRemove) {
            Button("Remove from Library", role: .destructive) { app.removeWallpaper(wallpaper.id) }
        } message: {
            Text(wallpaper.ownsMediaFile
                 ? "The copy stored in Driftwall’s library folder will be deleted."
                 : "Your original video file will not be deleted.")
        }
        .onDisappear { preview.stop() }
    }

    private func previewArea(_ wallpaper: Wallpaper, availability: MediaAvailability) -> some View {
        ZStack {
            ThumbnailView(wallpaper: wallpaper, cornerRadius: Theme.Radius.hero)
            if let player = preview.player {
                PlayerLayerView(player: player, gravity: .resizeAspect)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            }
            if let failure = preview.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if availability.isAvailable {
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            preview.toggle()
                        } label: {
                            Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])
                        .help(preview.isPlaying ? "Pause preview (Space)" : "Play preview (Space)")
                        .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
                        Text("Preview").font(.meta).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                    }
                    .padding(Theme.Space.l)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).strokeBorder(Theme.stroke))
        .task(id: availability.url) {
            if let url = availability.url { preview.load(url) } else { preview.stop() }
        }
    }

    private func actionPanel(_ wallpaper: Wallpaper, availability: MediaAvailability, isFavorite: Bool) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if availability.isAvailable {
                    Picker("Display", selection: $target) {
                        Text("All Displays").tag(DisplayTarget.allDisplays)
                        Text("Main Display").tag(DisplayTarget.mainDisplay)
                        if app.displays.displays.count > 1 {
                            Divider()
                            ForEach(app.displays.displays) { display in
                                Text(display.name).tag(DisplayTarget.display(id: display.id))
                            }
                        }
                    }
                    Button {
                        app.apply(wallpaper.id, target: target)
                    } label: {
                        Label("Set as Wallpaper", systemImage: "play.desktopcomputer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Label(availability.statusText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("The video file can’t be found at its last known location.")
                        .font(.callout).foregroundStyle(.secondary)
                    if wallpaper.source == .imported {
                        Button("Locate File…") { app.presentRelinkPanel(for: wallpaper.id) }
                            .buttonStyle(.borderedProminent)
                    }
                }

                HStack {
                    Button {
                        app.library.toggleFavorite(wallpaper.id)
                    } label: {
                        Label(isFavorite ? "Favorited" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("l", modifiers: .command)
                    AddToPlaylistMenu(wallpaperIDs: [wallpaper.id])
                        .fixedSize()
                }

                Divider()
                playbackStatus(wallpaper)

                if wallpaper.source == .imported || availability.isAvailable {
                    Divider()
                    HStack {
                        if availability.isAvailable {
                            Button("Show in Finder") { app.revealInFinder(wallpaper.id) }
                        }
                        Spacer()
                        if wallpaper.source == .imported {
                            Button("Remove…", role: .destructive) { confirmRemove = true }
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private func playbackStatus(_ wallpaper: Wallpaper) -> some View {
        let live = app.displaysShowing(wallpaper.id)
        VStack(alignment: .leading, spacing: 6) {
            Text("DESKTOP STATUS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if live.isEmpty {
                Text("Not on your desktop").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(live) { state in
                    HStack(spacing: 6) {
                        Circle().fill(color(for: state.status)).frame(width: 7, height: 7)
                        Text(state.displayName).font(.callout.weight(.medium))
                        Spacer()
                        Text(state.status.label).font(.meta).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func color(for status: SurfaceStatus) -> Color {
        switch status {
        case .playing: return Theme.live
        case .loading: return .blue
        case .paused: return .yellow
        case .failed: return .red
        }
    }
}
