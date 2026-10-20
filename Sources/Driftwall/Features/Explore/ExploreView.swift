import DriftwallCore
import SwiftUI

struct ExploreView: View {
    @Environment(AppController.self) private var app

    var body: some View {
        @Bindable var navigation = app.navigation
        let query = navigation.query
        let results = app.library.search(query)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PageHeader(title: "Explore", subtitle: summary(count: results.count, query: query))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        FilterChip(title: "All", isSelected: query.category == nil) { navigation.query.category = nil }
                        ForEach(app.library.categories, id: \.self) { category in
                            FilterChip(title: category, isSelected: query.category == category) {
                                navigation.query.category = query.category == category ? nil : category
                            }
                        }
                    }
                }

                FilterBar(query: $navigation.query)

                if results.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No wallpapers found",
                                   message: noResultsMessage(query)) {
                        Button("Clear Search & Filters") { navigation.query = SearchQuery() }
                        Button("Import Videos…") { app.presentImportPanel() }
                    }
                } else {
                    WallpaperGrid(wallpapers: results)
                }

                Text("Search matches words in titles, descriptions, categories and tags on this Mac. It is keyword search, not semantic or AI search.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, Theme.Space.l)
            }
            .padding(Theme.Space.page)
        }
        .navigationTitle("Explore")
    }

    private func summary(count: Int, query: SearchQuery) -> String {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return query.isEmpty ? "\(count) wallpapers" : "\(count) matching filters" }
        return "\(count) result\(count == 1 ? "" : "s") for “\(text)”"
    }

    private func noResultsMessage(_ query: SearchQuery) -> String {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return "Nothing matches “\(text)” with the current filters. Try fewer words or a different spelling." }
        return "No wallpapers match the current filters."
    }
}

private struct FilterBar: View {
    @Binding var query: SearchQuery

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Picker("Source", selection: $query.source) {
                Text("All Sources").tag(WallpaperSource?.none)
                ForEach(WallpaperSource.allCases) { Text($0.displayName).tag(WallpaperSource?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Resolution", selection: $query.minimumResolution) {
                Text("Any Resolution").tag(ResolutionClass?.none)
                ForEach([ResolutionClass.hd1080, .qhd1440, .uhd4k]) { Text("\($0.label) or higher").tag(ResolutionClass?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()

            Toggle("Favorites Only", isOn: $query.favoritesOnly)
                .toggleStyle(.checkbox)

            Spacer()

            Picker("Sort", selection: $query.sort) {
                ForEach(WallpaperSortOrder.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            if !query.isEmpty {
                Button("Reset") { query = SearchQuery(sort: query.sort) }
                    .help("Clear search text and filters")
            }
        }
        .controlSize(.regular)
    }
}
