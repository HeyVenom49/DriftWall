import DriftwallCore
import SwiftUI

struct ExploreView: View {
    @Environment(AppController.self) private var app
    /// The search text the results reflect. It trails the field by a short pause while typing, so the
    /// grid is rebuilt once per pause rather than once per keystroke; nil means "same as the field".
    @State private var settledText: String?

    var body: some View {
        @Bindable var navigation = app.navigation
        let query = resultsQuery(navigation.query)
        let results = app.library.search(query)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PageHeader(title: "Explore", subtitle: summary(count: results.count, query: query)) {
                    Picker("Sort", selection: $navigation.query.sort) {
                        ForEach(WallpaperSortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Sort order")
                }

                HStack(spacing: Theme.Space.s) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.xs) {
                            FilterChip(title: "All", isSelected: query.category == nil) { navigation.query.category = nil }
                            ForEach(app.library.categories, id: \.self) { category in
                                FilterChip(title: category, isSelected: query.category == category) {
                                    navigation.query.category = query.category == category ? nil : category
                                }
                            }
                        }
                    }
                    FiltersMenu(query: $navigation.query)
                    if !query.isEmpty {
                        Button("Clear") { navigation.query = SearchQuery(sort: query.sort) }
                            .help("Clear search text, category and filters")
                    }
                }

                if results.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No wallpapers found",
                                   message: noResultsMessage(query)) {
                        Button("Clear Filters") { navigation.query = SearchQuery(sort: query.sort) }
                        Button("Import Videos…") { app.presentImportPanel() }
                    }
                } else {
                    WallpaperGrid(wallpapers: results)
                        .padding(.top, Theme.Space.xs)
                }
            }
            .padding(Theme.Space.page)
        }
        .background(Theme.background)
        .navigationTitle("Explore")
        .task(id: navigation.query.text) {
            let text = navigation.query.text
            // First appearance and clearing the field apply at once; typing settles after 150 ms.
            if settledText == nil || text.isEmpty {
                settledText = text
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            settledText = text
        }
    }

    private func resultsQuery(_ live: SearchQuery) -> SearchQuery {
        var query = live
        if let settledText { query.text = settledText }
        return query
    }

    private func summary(count: Int, query: SearchQuery) -> String {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return query.isEmpty ? "\(count) wallpapers" : "\(count) matching filters" }
        return "\(count) result\(count == 1 ? "" : "s") for “\(text)”"
    }

    private func noResultsMessage(_ query: SearchQuery) -> String {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            return "Nothing matches “\(text)” with the current filters. Search looks at titles, descriptions, categories and tags."
        }
        return "No wallpapers match the current filters."
    }
}

/// Source, resolution and favorites filters in one native menu; the label shows how many are active.
private struct FiltersMenu: View {
    @Binding var query: SearchQuery

    var body: some View {
        let active = (query.source == nil ? 0 : 1) + (query.minimumResolution == nil ? 0 : 1) + (query.favoritesOnly ? 1 : 0)
        Menu {
            Picker("Source", selection: $query.source) {
                Text("All Sources").tag(WallpaperSource?.none)
                ForEach(WallpaperSource.allCases) { Text($0.displayName).tag(WallpaperSource?.some($0)) }
            }
            Picker("Resolution", selection: $query.minimumResolution) {
                Text("Any Resolution").tag(ResolutionClass?.none)
                ForEach([ResolutionClass.hd1080, .qhd1440, .uhd4k]) { Text("\($0.label) or Higher").tag(ResolutionClass?.some($0)) }
            }
            Divider()
            Toggle("Favorites Only", isOn: $query.favoritesOnly)
        } label: {
            Label(active == 0 ? "Filters" : "Filters (\(active))", systemImage: "line.3.horizontal.decrease")
        }
        .fixedSize()
        .help("Filter by source, resolution or favorites")
    }
}
