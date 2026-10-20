import DriftwallCore
import SwiftUI

struct HomeView: View {
    @Environment(AppController.self) private var app

    var body: some View {
        let library = app.library
        ScrollView {
            if library.wallpapers.isEmpty {
                EmptyStateView(symbol: "sparkles.tv", title: "Your library is empty",
                               message: "Import a video from your Mac to use it as a live desktop wallpaper. Drag files onto this window or choose them with Import.") {
                    Button("Import Videos…") { app.presentImportPanel() }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let problem = app.startupProblem {
                        ProblemCallout(message: problem) { app.startupProblem = nil }
                            .padding(.horizontal, Theme.Space.page)
                    }
                    if let hero = app.currentWallpaper ?? library.featuredWallpapers.first ?? library.wallpapers.first {
                        HeroView(wallpaper: hero, isLive: app.currentWallpaper?.id == hero.id)
                            .padding(.horizontal, Theme.Space.page)
                    }

                    let recent = library.recentWallpapers(limit: 12, kind: .applied).map(\.wallpaper)
                    if !recent.isEmpty {
                        ShelfRow(title: "Recently Used", wallpapers: recent) { app.navigation.show(.recent) }
                    }
                    let favorites = library.favoriteWallpapers
                    if !favorites.isEmpty {
                        ShelfRow(title: "Favorites", wallpapers: Array(favorites.prefix(12))) { app.navigation.show(.favorites) }
                    }
                    let featured = library.featuredWallpapers
                    if !featured.isEmpty {
                        ShelfRow(title: "Featured", subtitle: "Hand-picked highlights", wallpapers: featured)
                    }
                    ForEach(library.collections) { collection in
                        ShelfRow(title: collection.title, subtitle: collection.subtitle, wallpapers: library.wallpapers(collection.wallpaperIDs))
                    }
                    ShelfRow(title: "Popular", subtitle: "Ranked by curation and how often you use them",
                             wallpapers: Array(library.popularWallpapers.prefix(12))) { app.navigation.show(.explore) }

                    CategoryStrip()
                        .padding(.horizontal, Theme.Space.page)
                    ImportCallout()
                        .padding(.horizontal, Theme.Space.page)
                }
                .padding(.vertical, Theme.Space.page)
            }
        }
        .navigationTitle("Home")
    }
}

private struct HeroView: View {
    @Environment(AppController.self) private var app
    let wallpaper: Wallpaper
    let isLive: Bool
    @State private var preview = PreviewPlayer()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailView(wallpaper: wallpaper, cornerRadius: Theme.Radius.hero)
            if let player = preview.player {
                PlayerLayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: 6) {
                    if isLive { LiveBadge() } else { Badge(text: "FEATURED") }
                    Badge(text: wallpaper.category.uppercased())
                }
                Text(wallpaper.title)
                    .font(.system(size: 34, weight: .bold))
                Text(wallpaper.summary)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: 520, alignment: .leading)
                HStack(spacing: Theme.Space.s) {
                    if isLive {
                        Button(app.settings.userPaused ? "Resume" : "Pause", systemImage: app.settings.userPaused ? "play.fill" : "pause.fill") { app.togglePlayback() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Set as Wallpaper", systemImage: "play.desktopcomputer") { app.apply(wallpaper.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!app.library.isAvailable(wallpaper.id))
                    }
                    Button("Details") { app.navigation.open(wallpaper.id) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(Theme.Space.xl)
        }
        .frame(height: 360)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous).strokeBorder(Theme.stroke))
        .task(id: "\(wallpaper.id)-\(isLive)") {
            // The hero plays a muted in-app preview only while Home is on screen, and not when the same
            // video is already live on the desktop (that would decode it twice).
            if app.settings.hoverPreviews, !isLive, let url = app.library.mediaURL(for: wallpaper.id) { preview.load(url) } else { preview.stop() }
        }
        .onDisappear { preview.stop() }
    }
}

private struct CategoryStrip: View {
    @Environment(AppController.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Browse by Category")
            HStack(spacing: Theme.Space.s) {
                ForEach(app.library.categories, id: \.self) { category in
                    FilterChip(title: category, isSelected: false) { app.navigation.explore(category: category) }
                }
            }
        }
    }
}

private struct ImportCallout: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Panel {
            HStack(spacing: Theme.Space.l) {
                Image(systemName: "film.stack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bring your own video").font(.headline)
                    Text("Import .mov, .mp4 or .m4v files — or drop them anywhere on this window. Your originals stay where they are.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import Videos…") { app.presentImportPanel() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ProblemCallout: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(Theme.Space.m)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
