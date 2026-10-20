import Foundation
import Observation

/// Observable source of truth for wallpapers, favorites, history and playlists.
/// Every mutation is written through to the `LibraryStore` before in-memory state changes, so the UI
/// never shows state that was not persisted. Failures are surfaced through `lastError`.
@MainActor
@Observable
public final class LibraryModel {
    public private(set) var wallpapers: [Wallpaper] = []
    public private(set) var favoriteIDs: [WallpaperID] = []
    public private(set) var history: [HistoryEntry] = []
    public private(set) var playlists: [Playlist] = []
    public private(set) var collections: [CuratedCollection] = []
    public private(set) var availability: [WallpaperID: MediaAvailability] = [:]
    public private(set) var isLoaded = false
    public var lastError: String?

    @ObservationIgnored private var index: [WallpaperID: Int] = [:]
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored public let resolver: MediaResolver
    @ObservationIgnored public var searchEngine: WallpaperSearchEngine = KeywordSearchEngine()
    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let now: () -> Date

    public init(store: LibraryStore, resolver: MediaResolver, log: DiagnosticsLog = .shared, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.resolver = resolver
        self.log = log
        self.now = now
    }

    // MARK: - Loading

    public func load() {
        do {
            setWallpapers(try store.allWallpapers())
            favoriteIDs = try store.favorites().map(\.0)
            history = try store.history(limit: 200)
            playlists = try store.playlists()
            isLoaded = true
        } catch {
            report(error, "Loading library")
        }
        refreshAvailability()
    }

    /// Adds or updates bundled wallpapers from the catalog without disturbing user data.
    public func syncCatalog(_ catalog: Catalog, mediaSubdirectory: String) {
        let bundledIDs = Set(catalog.wallpapers.map(\.id))
        let existing = wallpapers.filter { bundledIDs.contains($0.id) }
        let merged = catalog.merged(into: existing, mediaSubdirectory: mediaSubdirectory, now: now())
        do {
            try store.upsert(merged)
            setWallpapers(try store.allWallpapers())
        } catch {
            report(error, "Syncing bundled catalog")
        }
        collections = catalog.collections.map { collection in
            var c = collection
            c.wallpaperIDs = collection.wallpaperIDs.filter { index[$0] != nil }
            return c
        }.filter { !$0.wallpaperIDs.isEmpty }
        refreshAvailability()
    }

    // MARK: - Lookup

    public func wallpaper(_ id: WallpaperID?) -> Wallpaper? {
        guard let id, let position = index[id] else { return nil }
        return wallpapers[position]
    }

    public func wallpapers(_ ids: [WallpaperID]) -> [Wallpaper] { ids.compactMap { wallpaper($0) } }

    public func isFavorite(_ id: WallpaperID) -> Bool { favoriteIDs.contains(id) }

    public var favoriteWallpapers: [Wallpaper] { wallpapers(favoriteIDs) }

    public var importedWallpapers: [Wallpaper] {
        wallpapers.filter { $0.source == .imported }.sorted { $0.importedAt > $1.importedAt }
    }

    public var featuredWallpapers: [Wallpaper] { wallpapers.filter(\.isFeatured).sorted { $0.popularityScore > $1.popularityScore } }

    public var popularWallpapers: [Wallpaper] {
        search(SearchQuery(sort: .popular))
    }

    public var categories: [String] {
        Array(Set(wallpapers.map(\.category))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func availabilityOf(_ id: WallpaperID) -> MediaAvailability {
        if let known = availability[id] { return known }
        guard let wallpaper = wallpaper(id) else { return .missing }
        return resolver.resolve(wallpaper)
    }

    public func isAvailable(_ id: WallpaperID) -> Bool { availabilityOf(id).isAvailable }

    public func mediaURL(for id: WallpaperID) -> URL? { availabilityOf(id).url }

    public var missingWallpapers: [Wallpaper] { wallpapers.filter { !(availability[$0.id]?.isAvailable ?? true) } }

    /// Recently viewed/applied wallpapers, most recent first, without duplicates.
    public func recentWallpapers(limit: Int = 20, kind: HistoryKind? = nil) -> [(wallpaper: Wallpaper, entry: HistoryEntry)] {
        var seen = Set<WallpaperID>()
        var result: [(Wallpaper, HistoryEntry)] = []
        for entry in history where kind == nil || entry.kind == kind {
            guard !seen.contains(entry.wallpaperID), let wallpaper = wallpaper(entry.wallpaperID) else { continue }
            seen.insert(entry.wallpaperID)
            result.append((wallpaper, entry))
            if result.count >= limit { break }
        }
        return result
    }

    public func search(_ query: SearchQuery) -> [Wallpaper] {
        searchEngine.search(query, in: wallpapers, context: SearchContext(favoriteIDs: Set(favoriteIDs)))
    }

    // MARK: - Availability

    /// Re-checks every media file. Files the bookmark located at a new path are updated in place.
    public func refreshAvailability() {
        var result: [WallpaperID: MediaAvailability] = [:]
        var relocated: [Wallpaper] = []
        for wallpaper in wallpapers {
            let status = resolver.resolve(wallpaper)
            if case .relocated(let url, let bookmark) = status {
                var updated = wallpaper
                updated.mediaPath = url.path
                if let bookmark { updated.bookmark = bookmark }
                relocated.append(updated)
                result[wallpaper.id] = .available(url)
                log.log(.info, "library", "“\(wallpaper.title)” was moved; now at \(url.path)")
            } else {
                result[wallpaper.id] = status
            }
        }
        if !relocated.isEmpty {
            do {
                try store.upsert(relocated)
                for item in relocated { replaceInMemory(item) }
            } catch { report(error, "Updating moved files") }
        }
        availability = result
        let missing = result.values.filter { !$0.isAvailable }.count
        if missing > 0 { log.log(.warning, "library", "\(missing) wallpaper file(s) are missing or unreadable") }
    }

    // MARK: - Favorites

    public func setFavorite(_ id: WallpaperID, _ isFavorite: Bool) {
        guard index[id] != nil else { return }
        do {
            try store.setFavorite(id: id, isFavorite: isFavorite, at: now())
            if isFavorite {
                if !favoriteIDs.contains(id) { favoriteIDs.insert(id, at: 0) }
            } else {
                favoriteIDs.removeAll { $0 == id }
            }
        } catch { report(error, "Updating favorites") }
    }

    public func toggleFavorite(_ id: WallpaperID) { setFavorite(id, !isFavorite(id)) }

    // MARK: - History

    public func recordViewed(_ id: WallpaperID) {
        // Avoid flooding history when the same item is re-opened repeatedly.
        if let latest = history.first, latest.wallpaperID == id, latest.kind == .viewed, now().timeIntervalSince(latest.date) < 60 { return }
        record(id, .viewed)
    }

    public func recordApplied(_ id: WallpaperID) {
        guard var wallpaper = wallpaper(id) else { return }
        do {
            let date = now()
            try store.markUsed(id: id, at: date)
            wallpaper.lastUsedAt = date
            wallpaper.useCount += 1
            replaceInMemory(wallpaper)
        } catch { report(error, "Updating usage") }
        record(id, .applied)
    }

    public func clearHistory() {
        do {
            try store.clearHistory()
            history = []
        } catch { report(error, "Clearing history") }
    }

    private func record(_ id: WallpaperID, _ kind: HistoryKind) {
        do {
            try store.recordHistory(id: id, kind: kind, at: now())
            history = try store.history(limit: 200)
        } catch { report(error, "Recording history") }
    }

    // MARK: - Library edits

    public func add(_ wallpaper: Wallpaper) {
        do {
            try store.upsert(wallpaper)
            replaceInMemory(wallpaper)
            availability[wallpaper.id] = resolver.resolve(wallpaper)
        } catch { report(error, "Saving “\(wallpaper.title)”") }
    }

    public func update(_ wallpaper: Wallpaper) {
        guard index[wallpaper.id] != nil else { return }
        add(wallpaper)
    }

    /// Removes a wallpaper from the library. The user's original file is never deleted; only a copy the
    /// app made inside its own library folder is removed. Bundled items cannot be removed.
    @discardableResult
    public func remove(_ id: WallpaperID, ownedMediaDirectory: URL?) -> Bool {
        guard let wallpaper = wallpaper(id), wallpaper.source == .imported else { return false }
        do {
            try store.deleteWallpaper(id: id)
        } catch {
            report(error, "Removing “\(wallpaper.title)”")
            return false
        }
        if wallpaper.ownsMediaFile, let directory = ownedMediaDirectory {
            let file = URL(fileURLWithPath: wallpaper.mediaPath).standardizedFileURL
            // Only delete files that are provably inside the app-owned media folder.
            if file.path.hasPrefix(directory.standardizedFileURL.path + "/") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        setWallpapers(wallpapers.filter { $0.id != id })
        favoriteIDs.removeAll { $0 == id }
        history.removeAll { $0.wallpaperID == id }
        playlists = playlists.map { var p = $0; p.itemIDs.removeAll { $0 == id }; return p }
        availability[id] = nil
        log.log(.info, "library", "Removed “\(wallpaper.title)” from library")
        return true
    }

    /// Points a (missing) imported wallpaper at a new file after validating it.
    public func relink(_ id: WallpaperID, to url: URL, inspector: MediaInspector = MediaInspector()) async throws {
        guard var wallpaper = wallpaper(id) else { return }
        let metadata = try await inspector.inspect(url)
        wallpaper.mediaPath = url.path
        wallpaper.bookmark = MediaResolver.makeBookmark(for: url)
        wallpaper.ownsMediaFile = false
        wallpaper.duration = metadata.duration
        wallpaper.pixelWidth = metadata.pixelWidth
        wallpaper.pixelHeight = metadata.pixelHeight
        wallpaper.frameRate = metadata.frameRate
        wallpaper.codec = metadata.codec
        wallpaper.fileSize = metadata.fileSize
        add(wallpaper)
    }

    // MARK: - Playlists

    @discardableResult
    public func createPlaylist(named name: String, items: [WallpaperID] = []) -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? uniquePlaylistName() : trimmed, createdAt: now(), itemIDs: items.filter { index[$0] != nil })
        return persist(playlist) ? playlist : nil
    }

    public func renamePlaylist(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var playlist = playlist(id) else { return }
        playlist.name = trimmed
        persist(playlist)
    }

    public func deletePlaylist(_ id: String) {
        do {
            try store.deletePlaylist(id: id)
            playlists.removeAll { $0.id == id }
        } catch { report(error, "Deleting playlist") }
    }

    public func addToPlaylist(_ playlistID: String, _ ids: [WallpaperID]) {
        guard var playlist = playlist(playlistID) else { return }
        for id in ids where index[id] != nil && !playlist.itemIDs.contains(id) { playlist.itemIDs.append(id) }
        persist(playlist)
    }

    public func removeFromPlaylist(_ playlistID: String, _ ids: Set<WallpaperID>) {
        guard var playlist = playlist(playlistID) else { return }
        playlist.itemIDs.removeAll { ids.contains($0) }
        persist(playlist)
    }

    /// Moves items like `Array.move(fromOffsets:toOffset:)` (List drag-to-reorder semantics).
    public func movePlaylistItems(_ playlistID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var playlist = playlist(playlistID) else { return }
        playlist.itemIDs = Self.moving(playlist.itemIDs, fromOffsets: source, toOffset: destination)
        persist(playlist)
    }

    public func playlist(_ id: String?) -> Playlist? {
        guard let id else { return nil }
        return playlists.first { $0.id == id }
    }

    public static func moving<T>(_ array: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let valid = source.filter { array.indices.contains($0) }
        let moved = valid.map { array[$0] }
        var remaining: [T] = []
        var insertion = min(max(destination, 0), array.count)
        for (offset, element) in array.enumerated() {
            if valid.contains(offset) {
                if offset < destination { insertion -= 1 }
            } else {
                remaining.append(element)
            }
        }
        remaining.insert(contentsOf: moved, at: min(max(insertion, 0), remaining.count))
        return remaining
    }

    @discardableResult
    private func persist(_ playlist: Playlist) -> Bool {
        do {
            try store.save(playlist)
            if let position = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[position] = playlist
            } else {
                playlists.append(playlist)
            }
            return true
        } catch {
            report(error, "Saving playlist")
            return false
        }
    }

    private func uniquePlaylistName() -> String {
        let names = Set(playlists.map(\.name))
        var n = 1
        while names.contains(n == 1 ? "New Playlist" : "New Playlist \(n)") { n += 1 }
        return n == 1 ? "New Playlist" : "New Playlist \(n)"
    }

    // MARK: - Helpers

    private func setWallpapers(_ list: [Wallpaper]) {
        wallpapers = list
        index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func replaceInMemory(_ wallpaper: Wallpaper) {
        if let position = index[wallpaper.id] {
            wallpapers[position] = wallpaper
        } else {
            index[wallpaper.id] = wallpapers.count
            wallpapers.append(wallpaper)
        }
    }

    private func report(_ error: Error, _ context: String) {
        lastError = "\(context) failed: \(error.localizedDescription)"
        log.log(.error, "library", "\(context) failed: \(error.localizedDescription)")
    }
}
