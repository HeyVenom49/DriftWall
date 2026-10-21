import DriftwallCore
import SwiftUI

struct FavoritesView: View {
    @Environment(AppController.self) private var app
    @State private var filter = ""
    @State private var sort: FavoritesSort = .dateAdded

    enum FavoritesSort: String, CaseIterable, Identifiable {
        case dateAdded = "Date Favorited", title = "Title", recentlyUsed = "Recently Used"
        var id: String { rawValue }
    }

    var body: some View {
        let favorites = sorted(filtered(app.library.favoriteWallpapers))
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PageHeader(title: "Favorites", subtitle: "\(app.library.favoriteIDs.count) saved") {
                    if !app.library.favoriteIDs.isEmpty {
                        HStack(spacing: Theme.Space.s) {
                            TextField("Filter", text: $filter, prompt: Text("Filter favorites"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            Picker("Sort", selection: $sort) {
                                ForEach(FavoritesSort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help("Sort order")
                        }
                    }
                }
                if app.library.favoriteIDs.isEmpty {
                    EmptyStateView(symbol: "heart", title: "No favorites yet",
                                   message: "Hover over a wallpaper and click the heart to keep it here. When no playlist is rotating, Next and Previous step through your favorites.") {
                        Button("Explore Wallpapers") { app.navigation.show(.explore) }.buttonStyle(.borderedProminent)
                    }
                } else if favorites.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No matching favorites", message: "Nothing in your favorites matches “\(filter)”.") {
                        Button("Clear Filter") { filter = "" }
                    }
                } else {
                    WallpaperGrid(wallpapers: favorites)
                }
            }
            .padding(Theme.Space.page)
        }
        .background(Theme.background)
        .navigationTitle("Favorites")
    }

    private func filtered(_ list: [Wallpaper]) -> [Wallpaper] {
        guard !filter.trimmingCharacters(in: .whitespaces).isEmpty else { return list }
        let ids = Set(KeywordSearchEngine().search(SearchQuery(text: filter), in: list, context: SearchContext()).map(\.id))
        return list.filter { ids.contains($0.id) }
    }

    private func sorted(_ list: [Wallpaper]) -> [Wallpaper] {
        switch sort {
        case .dateAdded: return list // already ordered by date favorited, newest first
        case .title: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyUsed: return list.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        }
    }
}
