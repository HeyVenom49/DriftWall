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
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
            }
            if !availability.isAvailable {
                VStack {
                    Spacer()
                    Label(availability.statusText, systemImage: "questionmark.folder")
                        .font(.meta)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
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
            withAnimation(.easeOut(duration: Theme.Motion.standard)) {
                image = loaded
                failed = loaded == nil
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Card

/// A wallpaper in a grid or shelf: the artwork is the focus; status is a small dot, actions appear on hover.
struct WallpaperCard: View {
    @Environment(AppController.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper
    var width: CGFloat? = nil
    @State private var isHovering = false
    @State private var showPreview = false
    @State private var preview = PreviewPlayer()
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        let isLive = !app.displaysShowing(wallpaper.id).isEmpty
        let isFavorite = app.library.isFavorite(wallpaper.id)
        let available = app.library.isAvailable(wallpaper.id)
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                ThumbnailView(wallpaper: wallpaper)
                if showPreview, let player = preview.player {
                    PlayerLayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .transition(.opacity)
                }
                if isHovering {
                    LinearGradient(colors: [.clear, .black.opacity(0.38)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                VStack {
                    HStack(spacing: 6) {
                        if isLive {
                            StatusDot(color: Theme.live)
                                .padding(5)
                                .background(.black.opacity(0.40), in: Circle())
                        }
                        Spacer()
                        if isFavorite && !isHovering {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.40), in: Circle())
                        }
                    }
                    Spacer()
                    if isHovering {
                        HStack(spacing: 6) {
                            Spacer()
                            CardIconButton(symbol: isFavorite ? "heart.fill" : "heart",
                                           help: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                                app.library.toggleFavorite(wallpaper.id)
                            }
                            if available {
                                CardIconButton(symbol: "play.desktopcomputer", help: "Set as Wallpaper") {
                                    app.apply(wallpaper.id)
                                }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(6)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent.opacity(0.9) : Theme.stroke, lineWidth: isFocused ? 1.5 : 0.5)
            )
            .shadow(color: .black.opacity(isHovering ? 0.28 : 0.12), radius: isHovering ? 10 : 4, y: isHovering ? 4 : 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.title)
                    .font(.cardTitle)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if isLive {
                        Text("Live").foregroundStyle(Theme.live)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(subtitle).foregroundStyle(Theme.secondaryText)
                }
                .font(.meta)
                .lineLimit(1)
            }
            .padding(.horizontal, 1)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            app.navigation.open(wallpaper.id)
            return .handled
        }
        .onKeyPress(.space) {
            guard available else { return .ignored }
            app.apply(wallpaper.id)
            return .handled
        }
        .onHover(perform: hover)
        .animation(Theme.Motion.ease(Theme.Motion.quick, reduceMotion: reduceMotion), value: isHovering)
        .onTapGesture { app.navigation.open(wallpaper.id) }
        .contextMenu { WallpaperActions(wallpaper: wallpaper) }
        .onDisappear { endPreview() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(wallpaper.title), \(wallpaper.category)\(isLive ? ", currently live" : "")\(isFavorite ? ", favorite" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.navigation.open(wallpaper.id) }
        .accessibilityAction(named: "Set as Wallpaper") { app.apply(wallpaper.id) }
        .accessibilityAction(named: isFavorite ? "Remove from Favorites" : "Add to Favorites") { app.library.toggleFavorite(wallpaper.id) }
        .help("\(wallpaper.title) — press Return for details, Space to set as wallpaper")
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
            withAnimation(Theme.Motion.ease(reduceMotion: reduceMotion)) { showPreview = true }
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
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Theme.Size.iconButton, height: Theme.Size.iconButton)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Status

/// Small round status indicator.
struct StatusDot: View {
    var color: Color = Theme.live
    var body: some View {
        Circle().fill(color).frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
            .accessibilityHidden(true)
    }
}

enum StatusKind {
    case live, info, warning, error, neutral

    var color: Color {
        switch self {
        case .live: return Theme.live
        case .info: return Theme.accent
        case .warning: return Theme.warning
        case .error: return Theme.danger
        case .neutral: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .live: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .neutral: return "circle"
        }
    }
}

/// One line of status: a colored symbol and text.
struct StatusLabel: View {
    let kind: StatusKind
    let text: String
    var font: Font = .callout

    var body: some View {
        Label {
            Text(text).foregroundStyle(kind == .neutral ? .secondary : .primary)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .font(font)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A callout for information that needs attention, with optional actions. Replaces boxed "info panels".
struct InlineNotice<Actions: View>: View {
    let kind: StatusKind
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            HStack(spacing: Theme.Space.s) { actions }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
        .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous).strokeBorder(kind.color.opacity(0.18)))
        .accessibilityElement(children: .combine)
    }
}

extension InlineNotice where Actions == EmptyView {
    init(kind: StatusKind, title: String, message: String? = nil) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}

/// Small neutral text tag (category, source).
struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.secondary)
    }
}

/// "Live" status tag.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: Theme.live)
            Text("Live").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.live)
        .accessibilityElement(children: .ignore)
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
        Button("Set as Wallpaper on All Displays") { app.apply(wallpaper.id, target: .allDisplays) }
            .disabled(!available)
        if app.displays.displays.count > 1 {
            Menu("Set as Wallpaper On") {
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
            Button("New Playlist…") { app.navigation.newPlaylist(with: wallpaperIDs) }
        }
    }
}

// MARK: - Layout

struct WallpaperGrid: View {
    @Environment(AppController.self) private var app
    let wallpapers: [Wallpaper]

    var body: some View {
        let width = app.settings.gridDensity.minimumCardWidth
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.65), spacing: Theme.Space.grid)],
                  alignment: .leading, spacing: Theme.Space.l + 4) {
            ForEach(wallpapers) { wallpaper in
                WallpaperCard(wallpaper: wallpaper)
            }
        }
    }
}

/// A horizontal row of wallpapers on Home.
struct ShelfRow: View {
    let title: String
    var subtitle: String? = nil
    let wallpapers: [Wallpaper]
    var seeAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: title, subtitle: subtitle, actionTitle: seeAll == nil ? nil : "Show All", action: seeAll)
                .padding(.horizontal, Theme.Space.page)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.grid) {
                    ForEach(wallpapers) { wallpaper in
                        WallpaperCard(wallpaper: wallpaper, width: Theme.Size.shelfItem)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, 2)
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
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(Theme.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Title, optional subtitle and trailing controls at the top of a page.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.pageTitle)
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: Theme.Space.l)
            accessory
        }
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
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
                .padding(.bottom, 2)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: Theme.Space.s) { actions }
                .padding(.top, 6)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityElement(children: .contain)
    }
}

/// A selectable filter token (categories).
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(
                    isSelected ? Theme.surfaceRaised : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .strokeBorder(isSelected ? Theme.strokeStrong : Color.clear)
                )
                .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Toolbar-style menu for grid size, shared by the grid pages.
struct ViewOptionsMenu: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Menu {
            Picker("Thumbnail Size", selection: Binding(get: { app.settings.gridDensity }, set: { app.settings.gridDensity = $0 })) {
                ForEach(GridDensity.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Play Previews on Hover", isOn: Binding(get: { app.settings.hoverPreviews }, set: { app.settings.hoverPreviews = $0 }))
        } label: {
            Label("View Options", systemImage: "square.grid.2x2")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Thumbnail size and previews")
    }
}

/// Transient feedback at the bottom of the window (apply results, import results).
struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
            Text(banner.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous).strokeBorder(Theme.stroke))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var kind: StatusKind {
        switch banner.kind {
        case .info: return .info
        case .success: return .live
        case .error: return .warning
        }
    }
}

/// A label above a value (detail metadata).
struct MetadataItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.eyebrow).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A grouped section surface. Use for one group of related controls; never nest them.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.5)
            )
    }
}
