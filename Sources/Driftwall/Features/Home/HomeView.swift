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
                    Button("Browse Samples") { app.navigation.show(.explore) }
                }
                .padding(.top, 48)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        PageHeader(title: "Home", subtitle: "\(library.wallpapers.count) wallpapers") {
                            Button("Explore") { app.navigation.show(.explore) }
                        }
                        if let problem = app.startupProblem {
                            InlineNotice(kind: .warning, title: "Something needs attention", message: problem) {
                                Button("Dismiss") { app.startupProblem = nil }
                            }
                        }
                        NowShowingStrip()
                    }
                    .padding(.horizontal, Theme.Space.page)

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
                        ShelfRow(title: "Featured", wallpapers: featured) { app.navigation.show(.explore) }
                    }
                    ForEach(library.collections) { collection in
                        ShelfRow(title: collection.title, subtitle: collection.subtitle, wallpapers: library.wallpapers(collection.wallpaperIDs))
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        CategoryStrip()
                        ImportRow()
                    }
                    .padding(.horizontal, Theme.Space.page)
                }
                .padding(.vertical, Theme.Space.page)
            }
        }
        .background(Theme.background)
        .navigationTitle("Home")
    }
}

/// What is on the desktop right now, with the controls that act on it. Uses the real playback state.
private struct NowShowingStrip: View {
    @Environment(AppController.self) private var app

    var body: some View {
        if let current = app.currentWallpaper {
            HStack(alignment: .center, spacing: Theme.Space.xl) {
                ThumbnailView(wallpaper: current, cornerRadius: Theme.Radius.hero)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    .onTapGesture { app.navigation.open(current.id) }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("ON YOUR DESKTOP")
                        .font(.eyebrow)
                        .foregroundStyle(.tertiary)
                    Text(current.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    HStack(spacing: 6) {
                        StatusDot(color: isPaused ? Theme.warning : Theme.live)
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if !current.summary.isEmpty {
                        Text(current.summary)
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                    HStack(spacing: Theme.Space.s) {
                        Button {
                            app.togglePlayback()
                        } label: {
                            Label(app.settings.userPaused ? "Resume" : "Pause",
                                  systemImage: app.settings.userPaused ? "play.fill" : "pause.fill")
                        }
                        Button {
                            app.nextWallpaper()
                        } label: { Label("Next", systemImage: "forward.fill") }
                        Button("Details") { app.navigation.open(current.id) }
                    }
                    .controlSize(.regular)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        } else {
            InlineNotice(kind: .info, title: "No live wallpaper on your desktop",
                         message: "Pick a wallpaper below and choose Set as Wallpaper, or open one to preview it first.") {
                Button("Explore") { app.navigation.show(.explore) }
            }
        }
    }

    private var isPaused: Bool { !app.engine.pauseReasons.isEmpty }

    private var statusText: String {
        if let reason = PauseReason.allCases.first(where: app.engine.pauseReasons.contains) {
            return "Paused — \(reason.label)"
        }
        let count = app.engine.surfaceStates.count
        return count > 1 ? "Live on \(count) displays" : "Live"
    }
}

private struct CategoryStrip: View {
    @Environment(AppController.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Browse by Category")
            HStack(spacing: Theme.Space.xs) {
                ForEach(app.library.categories, id: \.self) { category in
                    Button(category) { app.navigation.explore(category: category) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct ImportRow: View {
    @Environment(AppController.self) private var app

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "film.stack")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Use your own video")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Import .mov, .mp4 or .m4v files, or drop them anywhere on this window. Originals stay where they are.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: Theme.Space.m)
            Button("Import Videos…") { app.presentImportPanel() }
        }
        .padding(.top, Theme.Space.m)
        .overlay(alignment: .top) { Divider().opacity(0.7) }
    }
}
