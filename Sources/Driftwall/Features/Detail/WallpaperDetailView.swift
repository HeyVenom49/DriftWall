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
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                previewArea(wallpaper, availability: availability)

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        info(wallpaper)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        actions(wallpaper, availability: availability)
                            .frame(width: 280, alignment: .leading)
                    }

                    Divider().opacity(0.7)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                              alignment: .leading, spacing: Theme.Space.l) {
                        MetadataItem(label: "Duration", value: wallpaper.durationText)
                        MetadataItem(label: "Resolution", value: wallpaper.resolutionText)
                        MetadataItem(label: "Frame Rate", value: wallpaper.frameRate > 0 ? String(format: "%.0f fps", wallpaper.frameRate) : "—")
                        MetadataItem(label: "Codec", value: wallpaper.codec ?? "—")
                        MetadataItem(label: "File Size", value: wallpaper.fileSize > 0 ? wallpaper.fileSize.formattedBytes : "—")
                        MetadataItem(label: "Added", value: wallpaper.importedAt.formatted(date: .abbreviated, time: .omitted))
                        MetadataItem(label: "Last Used", value: wallpaper.lastUsedAt?.relativeDescription ?? "Never")
                        MetadataItem(label: "Times Applied", value: "\(wallpaper.useCount)")
                        MetadataItem(label: "Source", value: wallpaper.creator ?? wallpaper.source.displayName)
                        MetadataItem(label: "File", value: availability.statusText)
                    }
                    if wallpaper.source == .imported {
                        Text(wallpaper.mediaPath)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(Theme.Space.page)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .confirmationDialog("Remove “\(wallpaper.title)” from your library?", isPresented: $confirmRemove) {
            Button("Remove from Library", role: .destructive) { app.removeWallpaper(wallpaper.id) }
        } message: {
            Text(wallpaper.ownsMediaFile
                 ? "The copy stored in Driftwall’s library folder will be deleted."
                 : "Your original video file will not be deleted.")
        }
        .onDisappear { preview.stop() }
    }

    // MARK: - Preview

    private func previewArea(_ wallpaper: Wallpaper, availability: MediaAvailability) -> some View {
        ZStack {
            ThumbnailView(wallpaper: wallpaper, cornerRadius: Theme.Radius.hero)
            if let player = preview.player {
                PlayerLayerView(player: player, gravity: .resizeAspectFill, onVisibilityChange: preview.setVisible)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            }
            if let failure = preview.failure {
                InlineNotice(kind: .error, title: "The preview can’t play", message: failure)
                    .frame(maxWidth: 420)
            }
            if availability.isAvailable {
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            preview.toggle()
                        } label: {
                            Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 34, height: 34)
                                .background(.ultraThinMaterial, in: Circle())
                                .environment(\.colorScheme, .dark)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])
                        .help(preview.isPlaying ? "Pause preview (Space)" : "Play preview (Space)")
                        .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
                        Text(preview.isPlaying ? "Preview" : "Preview paused")
                            .font(.meta)
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 3)
                        Spacer()
                    }
                    .padding(Theme.Space.l)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .task(id: availability.url) {
            if let url = availability.url { preview.load(url) } else { preview.stop() }
        }
    }

    // MARK: - Information

    private func info(_ wallpaper: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(wallpaper.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(metaLine(wallpaper))
                .font(.meta)
                .foregroundStyle(Theme.secondaryText)
            if !wallpaper.summary.isEmpty {
                Text(wallpaper.summary)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if !wallpaper.tags.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(wallpaper.tags, id: \.self) { tag in
                        Button("#\(tag)") {
                            app.navigation.query = SearchQuery(text: tag)
                            app.navigation.show(.explore)
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .help("Search for “\(tag)”")
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
    }

    private func metaLine(_ wallpaper: Wallpaper) -> String {
        var parts = [wallpaper.category, wallpaper.source.displayName]
        if wallpaper.duration > 0 { parts.append(wallpaper.durationText) }
        if wallpaper.pixelWidth > 0 { parts.append(wallpaper.resolutionText) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Actions

    private func actions(_ wallpaper: Wallpaper, availability: MediaAvailability) -> some View {
        let isFavorite = app.library.isFavorite(wallpaper.id)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            if availability.isAvailable {
                Button {
                    app.apply(wallpaper.id, target: target)
                } label: {
                    Label("Set as Wallpaper", systemImage: "play.desktopcomputer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Set as wallpaper (⌘↩)")

                Picker("On", selection: $target) {
                    Text("All Displays").tag(DisplayTarget.allDisplays)
                    Text("Main Display").tag(DisplayTarget.mainDisplay)
                    if app.displays.displays.count > 1 {
                        Divider()
                        ForEach(app.displays.displays) { display in
                            Text(display.name).tag(DisplayTarget.display(id: display.id))
                        }
                    }
                }
                .help("Which display “Set as Wallpaper” changes")
            } else {
                InlineNotice(kind: .warning, title: availability.statusText,
                             message: "The video file can’t be found at its last known location.")
                if wallpaper.source == .imported {
                    Button("Locate File…") { app.presentRelinkPanel(for: wallpaper.id) }
                        .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: Theme.Space.s) {
                Button {
                    app.library.toggleFavorite(wallpaper.id)
                } label: {
                    Label(isFavorite ? "Favorited" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
                }
                .keyboardShortcut("l", modifiers: .command)
                .help(isFavorite ? "Remove from Favorites (⌘L)" : "Add to Favorites (⌘L)")
                AddToPlaylistMenu(wallpaperIDs: [wallpaper.id])
                    .fixedSize()
                Menu {
                    if availability.isAvailable {
                        Button("Show in Finder") { app.revealInFinder(wallpaper.id) }
                    }
                    if wallpaper.source == .imported {
                        if !availability.isAvailable {
                            Button("Locate File…") { app.presentRelinkPanel(for: wallpaper.id) }
                        }
                        Divider()
                        Button("Remove from Library…", role: .destructive) { confirmRemove = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!availability.isAvailable && wallpaper.source != .imported)
                .help("More")
                .accessibilityLabel("More actions")
            }

            playbackStatus(wallpaper)
                .padding(.top, Theme.Space.xs)
        }
    }

    @ViewBuilder
    private func playbackStatus(_ wallpaper: Wallpaper) -> some View {
        let live = app.displaysShowing(wallpaper.id)
        VStack(alignment: .leading, spacing: 6) {
            Text("ON YOUR DESKTOP")
                .font(.eyebrow)
                .foregroundStyle(.tertiary)
            if live.isEmpty {
                Text("Not on any display")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(live) { state in
                    HStack(spacing: 6) {
                        StatusDot(color: color(for: state.status))
                        Text(state.displayName).font(.callout)
                        Spacer()
                        Text(state.status.label)
                            .font(.meta)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func color(for status: SurfaceStatus) -> Color {
        switch status {
        case .playing: return Theme.live
        case .loading: return Theme.accent
        case .paused: return Theme.warning
        case .failed: return Theme.danger
        }
    }
}
