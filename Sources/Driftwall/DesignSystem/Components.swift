import DriftwallCore
import SwiftUI

// MARK: - Thumbnail

/// Asynchronously loaded still frame for a wallpaper, with placeholder and missing-file states.
struct ThumbnailView: View {
    @Environment(AppController.self) private var app
    let wallpaper: Wallpaper
    var cornerRadius: CGFloat = Theme.Radius.card
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        let availability = app.library.availabilityOf(wallpaper.id)
        ZStack {
            // The image lives in an overlay so its natural size never drives layout: the container decides the size.
            Theme.placeholder
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .clipped()
            if image == nil, failed || !availability.isAvailable {
                Image(systemName: availability.isAvailable ? "photo" : "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
            }
            if !availability.isAvailable {
                VStack {
                    Spacer()
                    Label(availability.statusText, systemImage: "questionmark.folder")
                        .font(.meta)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(wallpaper.id)-\(app.thumbnailEpoch)-\(availability.isAvailable)") {
            if let cached = app.thumbnailLoader.cachedImage(for: wallpaper.id) {
                image = cached
                return
            }
            image = nil
            let loaded = await app.thumbnailLoader.image(for: wallpaper, mediaURL: availability.url)
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                failed = loaded == nil
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Card

struct WallpaperCard: View {
    @Environment(AppController.self) private var app
    let wallpaper: Wallpaper
    var width: CGFloat? = nil
    @State private var isHovering = false
    @State private var showPreview = false
    @State private var preview = PreviewPlayer()
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let isLive = !app.displaysShowing(wallpaper.id).isEmpty
        let isFavorite = app.library.isFavorite(wallpaper.id)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(wallpaper: wallpaper)
                if showPreview, let player = preview.player {
                    PlayerLayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .transition(.opacity)
                }
                HStack(spacing: 6) {
                    if isLive { LiveBadge() }
                    if wallpaper.resolutionClass >= .uhd4k { Badge(text: wallpaper.resolutionClass.label) }
                    Spacer()
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .accessibilityLabel("Favorite")
                    }
                }
                .padding(8)
                if isHovering {
                    HStack(spacing: 6) {
                        Spacer()
                        CardIconButton(symbol: isFavorite ? "heart.slash" : "heart", help: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            app.library.toggleFavorite(wallpaper.id)
                        }
                        CardIconButton(symbol: "play.desktopcomputer", help: "Apply as Wallpaper") {
                            app.apply(wallpaper.id)
                        }
                    }
                    .padding(8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isLive ? Theme.live.opacity(0.9) : Theme.stroke, lineWidth: isLive ? 2 : 1)
            )
            .shadow(color: .black.opacity(isHovering ? 0.35 : 0.15), radius: isHovering ? 14 : 6, y: isHovering ? 8 : 3)
            .scaleEffect(isHovering ? 1.015 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.title)
                    .font(.cardTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onTapGesture { app.navigation.open(wallpaper.id) }
        .contextMenu { WallpaperActions(wallpaper: wallpaper) }
        .onDisappear { endPreview() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(wallpaper.title), \(wallpaper.category)\(isLive ? ", currently live" : "")\(isFavorite ? ", favorite" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.navigation.open(wallpaper.id) }
        .accessibilityAction(named: "Apply") { app.apply(wallpaper.id) }
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites") { app.library.toggleFavorite(wallpaper.id) }
    }

    private var subtitle: String {
        var parts = [wallpaper.category]
        if wallpaper.duration > 0 { parts.append(wallpaper.durationText) }
        if wallpaper.pixelWidth > 0 { parts.append(wallpaper.resolutionClass.label) }
        return parts.joined(separator: " · ")
    }

    private func hover(_ hovering: Bool) {
        isHovering = hovering
        hoverTask?.cancel()
        guard hovering else {
            endPreview()
            return
        }
        guard app.settings.hoverPreviews, let url = app.library.mediaURL(for: wallpaper.id) else { return }
        // Only start decoding after the pointer rests on the card, so sweeping across a grid stays cheap.
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            preview.load(url)
            withAnimation(.easeIn(duration: 0.25)) { showPreview = true }
        }
    }

    private func endPreview() {
        hoverTask?.cancel()
        showPreview = false
        preview.stop()
    }
}

struct CardIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(.white)
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.live).frame(width: 6, height: 6)
            Text("LIVE").font(.system(size: 10, weight: .heavy))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityLabel("Live on desktop")
    }
}

// MARK: - Context actions

/// Shared action menu used by cards, rows and the detail screen.
struct WallpaperActions: View {
    @Environment(AppController.self) private var app
    let wallpaper: Wallpaper

    var body: some View {
        let available = app.library.isAvailable(wallpaper.id)
        Button("Apply to All Displays") { app.apply(wallpaper.id, target: .allDisplays) }
            .disabled(!available)
        if app.displays.displays.count > 1 {
            Menu("Apply to Display") {
                ForEach(app.displays.displays) { display in
                    Button(display.name) { app.apply(wallpaper.id, target: .display(id: display.id)) }
                }
            }
            .disabled(!available)
        }
        Divider()
        Button(app.library.isFavorite(wallpaper.id) ? "Remove from Favorites" : "Add to Favorites") {
            app.library.toggleFavorite(wallpaper.id)
        }
        AddToPlaylistMenu(wallpaperIDs: [wallpaper.id])
        Divider()
        Button("Show Details") { app.navigation.open(wallpaper.id) }
        if available {
            Button("Show in Finder") { app.revealInFinder(wallpaper.id) }
        }
        if wallpaper.source == .imported {
            if !available {
                Button("Locate File…") { app.presentRelinkPanel(for: wallpaper.id) }
            }
            Divider()
            Button("Remove from Library", role: .destructive) { app.removeWallpaper(wallpaper.id) }
        }
    }
}

struct AddToPlaylistMenu: View {
    @Environment(AppController.self) private var app
    let wallpaperIDs: [WallpaperID]

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(app.library.playlists) { playlist in
                let contained = wallpaperIDs.allSatisfy(playlist.itemIDs.contains)
                Button {
                    app.library.addToPlaylist(playlist.id, wallpaperIDs)
                    app.playlistEdited()
                    app.showBanner(.success, "Added to “\(playlist.name)”.")
                } label: {
                    if contained { Label(playlist.name, systemImage: "checkmark") } else { Text(playlist.name) }
                }
                .disabled(contained)
            }
            if !app.library.playlists.isEmpty { Divider() }
            Button("New Playlist…") {
                if let playlist = app.library.createPlaylist(named: "", items: wallpaperIDs) {
                    app.navigation.show(.playlist(playlist.id))
                }
            }
        }
    }
}

// MARK: - Layout

struct WallpaperGrid: View {
    @Environment(AppController.self) private var app
    let wallpapers: [Wallpaper]

    var body: some View {
        let width = app.settings.gridDensity.minimumCardWidth
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.6), spacing: Theme.Space.l)], alignment: .leading, spacing: Theme.Space.l) {
            ForEach(wallpapers) { wallpaper in
                WallpaperCard(wallpaper: wallpaper)
            }
        }
    }
}

struct ShelfRow: View {
    let title: String
    var subtitle: String? = nil
    let wallpapers: [Wallpaper]
    var seeAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: title, subtitle: subtitle, actionTitle: seeAll == nil ? nil : "See All", action: seeAll)
                .padding(.horizontal, Theme.Space.page)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.l) {
                    ForEach(wallpapers) { wallpaper in
                        WallpaperCard(wallpaper: wallpaper, width: 250)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 6)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.sectionTitle)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.pageTitle)
                if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }
            Spacer()
            accessory
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: Theme.Space.s) { actions }
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .contain)
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isSelected ? Theme.accent : Theme.surfaceRaised, in: Capsule())
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .overlay(Capsule().strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(banner.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.35)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch banner.kind {
        case .info: return .blue
        case .success: return Theme.live
        case .error: return .orange
        }
    }
}

struct MetadataItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium).monospacedDigit()).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke))
    }
}
