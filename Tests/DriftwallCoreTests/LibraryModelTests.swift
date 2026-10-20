import Foundation
import Testing
@testable import DriftwallCore

@MainActor
@Suite("Library model: favorites, history, playlists, missing media")
struct LibraryModelTests {
    let store: SQLiteLibraryStore
    let model: LibraryModel
    let dir: URL

    init() throws {
        store = try Fixtures.memoryStore()
        dir = try Fixtures.temporaryDirectory()
        // Bundled media resolves under `dir`; create files for a, b, c so they count as available.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Samples"), withIntermediateDirectories: true)
        for id in ["a", "b", "c"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("Samples/\(id).mov").path, contents: Data())
        }
        try store.upsert(["a", "b", "c", "gone"].map { Fixtures.wallpaper($0) })
        model = LibraryModel(store: store, resolver: MediaResolver(bundleResourcesURL: dir), log: DiagnosticsLog(capacity: 10))
        model.load()
    }

    @Test func favoritesToggleAndPersist() throws {
        model.toggleFavorite("a")
        model.toggleFavorite("b")
        #expect(model.favoriteIDs == ["b", "a"]) // newest first
        model.toggleFavorite("a")
        #expect(model.favoriteIDs == ["b"])
        // A fresh model on the same store sees the same favorites ("restart").
        let restarted = LibraryModel(store: store, resolver: model.resolver)
        restarted.load()
        #expect(restarted.favoriteIDs == ["b"])
    }

    @Test func favoritingUnknownIDIsIgnored() {
        model.setFavorite("nope", true)
        #expect(model.favoriteIDs.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test func recentIsDedupedAndNewestFirst() {
        model.recordApplied("a")
        model.recordApplied("b")
        model.recordApplied("a")
        #expect(model.recentWallpapers(kind: .applied).map(\.wallpaper.id) == ["a", "b"])
        #expect(model.wallpaper("a")?.useCount == 2)
        #expect(model.wallpaper("a")?.lastUsedAt != nil)
    }

    @Test func repeatedViewsAreNotFlooded() {
        model.recordViewed("a")
        model.recordViewed("a")
        #expect(model.history.filter { $0.kind == .viewed }.count == 1)
    }

    @Test func clearHistory() {
        model.recordApplied("a")
        model.clearHistory()
        #expect(model.history.isEmpty)
        #expect(model.wallpaper("a") != nil)
    }

    @Test func playlistLifecycle() throws {
        let playlist = try #require(model.createPlaylist(named: "  Focus  ", items: ["a", "b", "unknown"]))
        #expect(playlist.name == "Focus")
        #expect(playlist.itemIDs == ["a", "b"]) // unknown IDs are dropped

        model.addToPlaylist(playlist.id, ["c", "a"])
        #expect(model.playlist(playlist.id)?.itemIDs == ["a", "b", "c"]) // no duplicates

        model.movePlaylistItems(playlist.id, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.playlist(playlist.id)?.itemIDs == ["c", "a", "b"])

        model.removeFromPlaylist(playlist.id, ["a"])
        #expect(model.playlist(playlist.id)?.itemIDs == ["c", "b"])

        model.renamePlaylist(playlist.id, to: "Deep Work")
        model.renamePlaylist(playlist.id, to: "   ") // ignored
        #expect(model.playlist(playlist.id)?.name == "Deep Work")

        let restarted = LibraryModel(store: store, resolver: model.resolver)
        restarted.load()
        #expect(restarted.playlist(playlist.id)?.itemIDs == ["c", "b"])
        #expect(restarted.playlist(playlist.id)?.name == "Deep Work")

        model.deletePlaylist(playlist.id)
        #expect(model.playlists.isEmpty)
        #expect(model.wallpapers.count == 4) // wallpapers untouched
    }

    @Test func untitledPlaylistsGetUniqueNames() {
        let first = model.createPlaylist(named: "")
        let second = model.createPlaylist(named: "")
        #expect(first?.name == "New Playlist")
        #expect(second?.name == "New Playlist 2")
    }

    @Test func moveMatchesArrayMoveSemantics() {
        let items = ["a", "b", "c", "d"]
        #expect(LibraryModel.moving(items, fromOffsets: [0], toOffset: 4) == ["b", "c", "d", "a"])
        #expect(LibraryModel.moving(items, fromOffsets: [3], toOffset: 0) == ["d", "a", "b", "c"])
        #expect(LibraryModel.moving(items, fromOffsets: [0, 2], toOffset: 4) == ["b", "d", "a", "c"])
        #expect(LibraryModel.moving(items, fromOffsets: [1], toOffset: 1) == items)
        #expect(LibraryModel.moving(items, fromOffsets: [9], toOffset: 0) == items)
    }

    @Test func missingMediaIsDetected() {
        #expect(model.isAvailable("a"))
        #expect(!model.isAvailable("gone"))
        #expect(model.missingWallpapers.map(\.id) == ["gone"])
        #expect(model.mediaURL(for: "gone") == nil)
    }

    @Test func bundledWallpapersCannotBeRemoved() {
        #expect(!model.remove("a", ownedMediaDirectory: dir))
        #expect(model.wallpaper("a") != nil)
    }

    @Test func removingImportReferencedInPlaceNeverDeletesOriginal() throws {
        let original = dir.appendingPathComponent("original.mov")
        FileManager.default.createFile(atPath: original.path, contents: Data([1]))
        model.add(Fixtures.wallpaper("user.1", source: .imported, mediaPath: original.path))
        model.toggleFavorite("user.1")
        #expect(model.remove("user.1", ownedMediaDirectory: dir.appendingPathComponent("Media")))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(model.wallpaper("user.1") == nil)
        #expect(!model.favoriteIDs.contains("user.1"))
    }

    @Test func removingOwnedCopyDeletesOnlyInsideLibraryFolder() throws {
        let media = dir.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let copy = media.appendingPathComponent("user.2.mov")
        FileManager.default.createFile(atPath: copy.path, contents: Data([1]))
        var owned = Fixtures.wallpaper("user.2", source: .imported, mediaPath: copy.path)
        owned.ownsMediaFile = true
        model.add(owned)

        // A record that claims ownership of a file outside the library folder must not delete it.
        let outside = dir.appendingPathComponent("outside.mov")
        FileManager.default.createFile(atPath: outside.path, contents: Data([1]))
        var bogus = Fixtures.wallpaper("user.3", source: .imported, mediaPath: outside.path)
        bogus.ownsMediaFile = true
        model.add(bogus)

        model.remove("user.2", ownedMediaDirectory: media)
        model.remove("user.3", ownedMediaDirectory: media)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func catalogSyncPreservesUsageAndUpdatesEditorialFields() throws {
        model.recordApplied("a")
        let catalog = Catalog(version: 1, wallpapers: [
            .init(id: "a", title: "Alpha v2", summary: "New", category: "Space", tags: ["x"], file: "a.mov", featured: true, popularity: 5, creator: nil),
            .init(id: "new", title: "Newcomer", summary: "", category: "Space", tags: [], file: "new.mov", featured: nil, popularity: nil, creator: nil),
        ], collections: [CuratedCollection(id: "c", title: "C", subtitle: "", wallpaperIDs: ["a", "missing-id"])])
        model.syncCatalog(catalog, mediaSubdirectory: "Samples")
        let a = try #require(model.wallpaper("a"))
        #expect(a.title == "Alpha v2")
        #expect(a.isFeatured)
        #expect(a.useCount == 1)
        #expect(model.wallpaper("new")?.mediaPath == "Samples/new.mov")
        #expect(model.collections.first?.wallpaperIDs == ["a"]) // unknown IDs dropped from collections
    }

    @Test func importedFileMovedOnDiskIsRelocated() throws {
        let original = dir.appendingPathComponent("clip.mov")
        FileManager.default.createFile(atPath: original.path, contents: Data([1, 2]))
        var w = Fixtures.wallpaper("user.m", source: .imported, mediaPath: original.path)
        w.bookmark = MediaResolver.makeBookmark(for: original)
        model.add(w)
        let moved = dir.appendingPathComponent("renamed clip.mov")
        try FileManager.default.moveItem(at: original, to: moved)
        model.refreshAvailability()
        #expect(model.isAvailable("user.m"))
        let path = try #require(model.wallpaper("user.m")?.mediaPath)
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
    }
}
