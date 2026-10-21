import DriftwallCore
import SwiftUI

struct PlaylistsOverviewView: View {
    @Environment(AppController.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PageHeader(title: "Playlists", subtitle: "Rotate through wallpapers automatically") {
                    Button("New Playlist…") { app.navigation.newPlaylist() }
                    .buttonStyle(.borderedProminent)
                }
                if app.library.playlists.isEmpty {
                    EmptyStateView(symbol: "list.bullet.rectangle", title: "No playlists",
                                   message: "Group wallpapers into a playlist, then let Driftwall switch between them on a schedule.") {
                        Button("Create a Playlist…") { app.navigation.newPlaylist() }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Space.grid)], alignment: .leading, spacing: Theme.Space.xl) {
                        ForEach(app.library.playlists) { playlist in
                            PlaylistCard(playlist: playlist)
                        }
                    }
                }
            }
            .padding(Theme.Space.page)
        }
        .background(Theme.background)
        .navigationTitle("Playlists")
    }
}

private struct PlaylistCard: View {
    @Environment(AppController.self) private var app
    let playlist: Playlist

    var body: some View {
        let items = app.library.wallpapers(Array(playlist.itemIDs.prefix(4)))
        let isRotating = app.rotation.isActive && app.rotation.settings.playlistID == playlist.id
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ZStack {
                Theme.placeholder
                if items.isEmpty {
                    Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                        ForEach(items) { ThumbnailView(wallpaper: $0, cornerRadius: 0).aspectRatio(16 / 9, contentMode: .fill) }
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.cardTitle)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if isRotating {
                        StatusDot(color: app.rotation.settings.isPaused ? Theme.warning : Theme.live)
                        Text(app.rotation.settings.isPaused ? "Rotation paused" : "Rotating now")
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text("\(playlist.itemIDs.count) wallpaper\(playlist.itemIDs.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                .font(.meta)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.navigation.show(.playlist(playlist.id)) }
        .contextMenu {
            Button("Play") { app.startPlaylist(playlist.id) }.disabled(playlist.itemIDs.isEmpty)
            Button("Rename…") { app.navigation.renamePlaylist(playlist) }
            Divider()
            Button("Delete Playlist", role: .destructive) { app.deletePlaylist(playlist.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct PlaylistDetailView: View {
    @Environment(AppController.self) private var app
    let playlistID: String
    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var selection = Set<WallpaperID>()

    var body: some View {
        if let playlist = app.library.playlist(playlistID) {
            content(playlist)
        } else {
            EmptyStateView(symbol: "questionmark.square.dashed", title: "Playlist not found", message: "It may have been deleted.") {
                Button("All Playlists") { app.navigation.show(.playlists) }
            }
        }
    }

    private func content(_ playlist: Playlist) -> some View {
        let rotation = app.rotation
        let isRotating = rotation.isActive && rotation.settings.playlistID == playlist.id
        let items = app.library.wallpapers(playlist.itemIDs)
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(playlist.name)
                    .font(.pageTitle)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { app.navigation.renamePlaylist(playlist) }
                    .help("Double-click to rename")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: "Rename") { app.navigation.renamePlaylist(playlist) }
                Button {
                    app.navigation.renamePlaylist(playlist)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Rename playlist")
                .accessibilityLabel("Rename playlist")
                Spacer()
                Button("Add Wallpapers…") { showPicker = true }
                Menu {
                    Button("Rename…") { app.navigation.renamePlaylist(playlist) }
                    Divider()
                    Button("Delete Playlist…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
            }

            HStack(spacing: Theme.Space.l) {
                if isRotating {
                    Button {
                        rotation.setPaused(!rotation.settings.isPaused)
                    } label: {
                        Label(rotation.settings.isPaused ? "Resume Rotation" : "Pause Rotation", systemImage: rotation.settings.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Stop") { rotation.stop() }
                } else {
                    Button {
                        app.startPlaylist(playlist.id)
                    } label: { Label("Play Playlist", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(items.isEmpty)
                }
                Picker("Change every", selection: Binding(get: { rotation.settings.interval }, set: { rotation.setInterval($0) })) {
                    ForEach(intervalOptions(current: rotation.settings.interval), id: \.self) { Text(RotationSettings.label(for: $0)).tag($0) }
                }
                .fixedSize()
                Toggle("Shuffle", isOn: Binding(get: { rotation.settings.shuffle }, set: { rotation.setShuffle($0) }))
                    .toggleStyle(.switch)
                RotationDisplayPicker()
                    .fixedSize()
                Spacer()
                if isRotating {
                    RotationStatus()
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous).strokeBorder(Theme.stroke))

            if items.isEmpty {
                EmptyStateView(symbol: "plus.rectangle.on.rectangle", title: "This playlist is empty",
                               message: "Add wallpapers, then press Play to rotate through them.") {
                    Button("Add Wallpapers…") { showPicker = true }.buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, wallpaper in
                        PlaylistRow(index: offset + 1, wallpaper: wallpaper,
                                    isCurrent: isRotating && rotation.settings.currentWallpaperID == wallpaper.id) {
                            app.library.removeFromPlaylist(playlist.id, [wallpaper.id])
                            app.playlistEdited()
                        }
                        .tag(wallpaper.id)
                    }
                    .onMove { source, destination in
                        app.library.movePlaylistItems(playlist.id, fromOffsets: source, toOffset: destination)
                        app.playlistEdited()
                    }
                    .onDelete { offsets in
                        app.library.removeFromPlaylist(playlist.id, Set(offsets.map { items[$0].id }))
                        app.playlistEdited()
                    }
                }
                .onDeleteCommand {
                    app.library.removeFromPlaylist(playlist.id, selection)
                    selection.removeAll()
                    app.playlistEdited()
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
                Text("Drag rows to reorder. Removing an item never deletes the wallpaper or its video.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.page)
        .background(Theme.background)
        .navigationTitle(playlist.name)
        .sheet(isPresented: $showPicker) {
            WallpaperPickerSheet(title: "Add to “\(playlist.name)”", excluded: Set(playlist.itemIDs)) { ids in
                app.library.addToPlaylist(playlist.id, ids)
                app.playlistEdited()
            }
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $confirmDelete) {
            Button("Delete Playlist", role: .destructive) { app.deletePlaylist(playlist.id) }
        } message: {
            Text("The wallpapers in it stay in your library.")
        }
    }

    private func intervalOptions(current: TimeInterval) -> [TimeInterval] {
        var options = RotationSettings.intervalPresets
        if !options.contains(current) { options.append(current); options.sort() }
        return options
    }
}

private struct RotationStatus: View {
    @Environment(AppController.self) private var app

    var body: some View {
        if app.rotation.settings.isPaused {
            Label("Rotation paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if let next = app.rotation.nextChange {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label("Next change in \(Self.countdown(next.timeIntervalSince(context.date)))", systemImage: "timer")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Waiting (system asleep or locked)", systemImage: "moon").foregroundStyle(.secondary)
        }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PlaylistRow: View {
    @Environment(AppController.self) private var app
    let index: Int
    let wallpaper: Wallpaper
    let isCurrent: Bool
    let remove: () -> Void

    var body: some View {
        let available = app.library.isAvailable(wallpaper.id)
        HStack(spacing: Theme.Space.m) {
            Text("\(index)").font(.meta).foregroundStyle(.tertiary).frame(width: 24)
            ThumbnailView(wallpaper: wallpaper, cornerRadius: 6)
                .frame(width: Theme.Size.rowThumbnail.width, height: Theme.Size.rowThumbnail.height)
            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.title).font(.body.weight(.semibold))
                if available {
                    Text("\(wallpaper.category) · \(wallpaper.durationText)").font(.callout).foregroundStyle(.secondary)
                } else {
                    StatusLabel(kind: .warning, text: "Missing file — skipped during rotation", font: .caption)
                }
            }
            Spacer()
            if isCurrent { LiveBadge() }
            Button("Set") { app.apply(wallpaper.id) }
                .disabled(!available)
                .help("Set as wallpaper now")
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove from playlist")
                .accessibilityLabel("Remove from playlist")
        }
        .padding(.vertical, 3)
    }
}

/// Multi-select wallpaper picker used to add items to a playlist.
struct WallpaperPickerSheet: View {
    @Environment(AppController.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: String
    let excluded: Set<WallpaperID>
    let onAdd: ([WallpaperID]) -> Void
    @State private var selected: [WallpaperID] = []
    @State private var text = ""

    var body: some View {
        let candidates = app.library.search(SearchQuery(text: text, sort: .title)).filter { !excluded.contains($0.id) }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                TextField("Search", text: $text).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if candidates.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: excluded.isEmpty ? "No wallpapers" : "Nothing left to add",
                               message: text.isEmpty ? "Every wallpaper is already in this playlist." : "No wallpapers match “\(text)”.") { EmptyView() }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                        ForEach(candidates) { wallpaper in
                            let isSelected = selected.contains(wallpaper.id)
                            VStack(alignment: .leading, spacing: 4) {
                                ThumbnailView(wallpaper: wallpaper)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 2.5 : 1))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.title3).foregroundStyle(isSelected ? Theme.accent : .white)
                                            .padding(6)
                                    }
                                Text(wallpaper.title).font(.cardTitle).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelected { selected.removeAll { $0 == wallpaper.id } } else { selected.append(wallpaper.id) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(wallpaper.title)
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(4)
                }
            }
            HStack {
                Text(selected.isEmpty ? "Select wallpapers to add" : "\(selected.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
    }
}

/// Chooses which display playlist rotation changes.
struct RotationDisplayPicker: View {
    @Environment(AppController.self) private var app

    var body: some View {
        let selected = app.rotation.settings.targetDisplayID
        Picker("Show on", selection: Binding(get: { selected }, set: { app.rotation.setTargetDisplay($0) })) {
            Text("All Displays").tag(String?.none)
            ForEach(app.displays.displays) { display in
                Text(display.name).tag(String?.some(display.id))
            }
            if let selected, app.displays.display(id: selected) == nil {
                Text("Disconnected display").tag(String?.some(selected))
            }
        }
        .help("The display whose wallpaper the playlist changes")
    }
}

/// Names a new playlist or renames one. Create/Rename stays disabled until the name has a character
/// other than spaces.
struct PlaylistNameSheet: View {
    @Environment(AppController.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: PlaylistNameRequest
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(isRename ? "Rename Playlist" : "New Playlist").font(.headline)
            TextField("Name", text: $name, prompt: Text("Playlist name"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !trimmed.isEmpty { confirm(trimmed) } }
            if case .create(let items) = request, !items.isEmpty {
                Text("Starts with \(items.count) wallpaper\(items.count == 1 ? "" : "s").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Create") { confirm(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 360)
        .onAppear {
            if case .rename(_, let current) = request { name = current }
            focused = true
        }
    }

    private var isRename: Bool {
        if case .rename = request { return true }
        return false
    }

    private func confirm(_ trimmed: String) {
        switch request {
        case .create(let items):
            if let playlist = app.library.createPlaylist(named: trimmed, items: items) {
                app.navigation.show(.playlist(playlist.id))
                if !items.isEmpty { app.showBanner(.success, "Created “\(playlist.name)”.") }
            } else {
                app.showBanner(.error, "The playlist couldn’t be created.")
            }
        case .rename(let id, _):
            app.library.renamePlaylist(id, to: trimmed)
        }
        dismiss()
    }
}
