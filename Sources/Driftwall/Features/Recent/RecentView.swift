import DriftwallCore
import SwiftUI

struct RecentView: View {
    @Environment(AppController.self) private var app
    @State private var kind: HistoryKind? = .applied
    @State private var confirmClear = false

    var body: some View {
        let items = app.library.recentWallpapers(limit: 100, kind: kind)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            PageHeader(title: "Recent", subtitle: "Wallpapers you recently applied or viewed") {
                HStack {
                    Picker("Show", selection: $kind) {
                        Text("Applied").tag(HistoryKind?.some(.applied))
                        Text("Viewed").tag(HistoryKind?.some(.viewed))
                        Text("All").tag(HistoryKind?.none)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button("Clear History…") { confirmClear = true }
                        .disabled(app.library.history.isEmpty)
                }
            }
            .padding([.horizontal, .top], Theme.Space.page)

            if items.isEmpty {
                EmptyStateView(symbol: "clock", title: "Nothing here yet",
                               message: kind == .applied ? "Wallpapers you set on your desktop will appear here." : "Wallpapers you open will appear here.") {
                    Button("Explore Wallpapers") { app.navigation.show(.explore) }
                }
                Spacer()
            } else {
                List {
                    ForEach(items, id: \.wallpaper.id) { item in
                        RecentRow(wallpaper: item.wallpaper, entry: item.entry)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Recent")
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { app.library.clearHistory() }
        } message: {
            Text("Your wallpapers, favorites and playlists are not affected.")
        }
    }
}

private struct RecentRow: View {
    @Environment(AppController.self) private var app
    let wallpaper: Wallpaper
    let entry: HistoryEntry

    var body: some View {
        let availability = app.library.availabilityOf(wallpaper.id)
        HStack(spacing: Theme.Space.m) {
            ThumbnailView(wallpaper: wallpaper, cornerRadius: 8)
                .frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.title).font(.headline)
                Text("\(entry.kind == .applied ? "Applied" : "Viewed") \(entry.date.relativeDescription) · \(wallpaper.category)")
                    .font(.callout).foregroundStyle(.secondary)
                if !availability.isAvailable {
                    Label("Video file is missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if availability.isAvailable {
                Button("Reapply") { app.apply(wallpaper.id) }
            } else if wallpaper.source == .imported {
                Button("Locate…") { app.presentRelinkPanel(for: wallpaper.id) }
                Button("Remove", role: .destructive) { app.removeWallpaper(wallpaper.id) }
            }
            Button {
                app.navigation.open(wallpaper.id)
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .accessibilityLabel("Show details")
        }
        .padding(.vertical, 4)
        .contextMenu { WallpaperActions(wallpaper: wallpaper) }
    }
}
