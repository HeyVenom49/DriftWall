import Foundation
import Testing
@testable import DriftwallCore

@Suite("Persistence")
struct PersistenceTests {
    @Test func wallpaperRoundTrip() throws {
        let store = try Fixtures.memoryStore()
        var w = Fixtures.wallpaper("a", tags: ["one", "two"], source: .imported)
        w.bookmark = Data([1, 2, 3])
        w.codec = "HEVC"
        w.lastUsedAt = Date(timeIntervalSince1970: 5_000)
        try store.upsert(w)
        let loaded = try #require(try store.allWallpapers().first)
        #expect(loaded == w)
    }

    @Test func upsertUpdatesInPlaceWithoutDroppingRelatedRows() throws {
        // INSERT OR REPLACE would delete-then-insert and cascade away favorites; ON CONFLICT UPDATE must not.
        let store = try Fixtures.memoryStore()
        try store.upsert(Fixtures.wallpaper("a"))
        try store.setFavorite(id: "a", isFavorite: true, at: Date())
        try store.save(Playlist(id: "p", name: "P", itemIDs: ["a"]))
        try store.upsert(Fixtures.wallpaper("a", title: "Renamed"))
        #expect(try store.allWallpapers().first?.title == "Renamed")
        #expect(try store.favorites().map(\.0) == ["a"])
        #expect(try store.playlists().first?.itemIDs == ["a"])
    }

    @Test func deletingWallpaperCascadesToFavoritesHistoryPlaylistsAndAssignments() throws {
        let store = try Fixtures.memoryStore()
        try store.upsert([Fixtures.wallpaper("a"), Fixtures.wallpaper("b")])
        try store.setFavorite(id: "a", isFavorite: true, at: Date())
        try store.recordHistory(id: "a", kind: .applied, at: Date())
        try store.save(Playlist(id: "p", name: "P", itemIDs: ["a", "b"]))
        try store.setAssignment(DisplayAssignment(displayID: "D1", wallpaperID: "a", displayName: "Display"))
        try store.deleteWallpaper(id: "a")
        #expect(try store.favorites().isEmpty)
        #expect(try store.history(limit: 10).isEmpty)
        #expect(try store.playlists().first?.itemIDs == ["b"])
        #expect(try store.assignments().isEmpty)
    }

    @Test func deletingPlaylistKeepsWallpapers() throws {
        let store = try Fixtures.memoryStore()
        try store.upsert([Fixtures.wallpaper("a"), Fixtures.wallpaper("b")])
        try store.save(Playlist(id: "p", name: "P", itemIDs: ["a", "b"]))
        try store.deletePlaylist(id: "p")
        #expect(try store.playlists().isEmpty)
        #expect(try store.allWallpapers().count == 2)
    }

    @Test func playlistOrderIsPreservedAndDuplicatesIgnored() throws {
        let store = try Fixtures.memoryStore()
        try store.upsert(["a", "b", "c"].map { Fixtures.wallpaper($0) })
        try store.save(Playlist(id: "p", name: "P", itemIDs: ["c", "a", "b", "a"]))
        #expect(try store.playlists().first?.itemIDs == ["c", "a", "b"])
    }

    @Test func historyIsPrunedAndNewestFirst() throws {
        let store = try Fixtures.memoryStore()
        try store.upsert(Fixtures.wallpaper("a"))
        for i in 0..<(SQLiteLibraryStore.historyLimit + 20) {
            try store.recordHistory(id: "a", kind: .viewed, at: Date(timeIntervalSince1970: Double(i)))
        }
        let all = try store.history(limit: 10_000)
        #expect(all.count == SQLiteLibraryStore.historyLimit)
        #expect(all.first?.date == Date(timeIntervalSince1970: Double(SQLiteLibraryStore.historyLimit + 19)))
    }

    @Test func settingsRoundTripAndDefaults() throws {
        let store = try Fixtures.memoryStore()
        #expect(try store.loadSettings() == AppSettings())
        var settings = AppSettings()
        settings.videoGravity = .fit
        settings.displayMode = .mirror
        settings.defaultTarget = .display(id: "XYZ")
        settings.rotation.isEnabled = true
        settings.rotation.interval = 300
        settings.rotation.targetDisplayID = "UUID-EXT"
        try store.saveSettings(settings)
        #expect(try store.loadSettings() == settings)
    }

    @Test func settingsDecodingToleratesMissingAndBadKeys() throws {
        // Simulates settings written by an older version plus one corrupted value.
        let json = #"{"videoGravity":"fit","displayMode":"nonsense","rotation":{"interval":2}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.videoGravity == .fit)
        #expect(settings.displayMode == .perDisplay) // bad value falls back to default
        #expect(settings.rotation.interval == 10) // clamped to the minimum
        #expect(settings.showDesktopIcons == true) // missing key uses default
    }

    @Test func dataSurvivesReopeningTheDatabaseFile() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        do {
            let store = try SQLiteLibraryStore.open(at: url).store
            try store.upsert(Fixtures.wallpaper("a"))
            try store.setFavorite(id: "a", isFavorite: true, at: Date())
            try store.save(Playlist(id: "p", name: "Evening", itemIDs: ["a"]))
            try store.setAssignment(DisplayAssignment(displayID: "D", wallpaperID: "a", displayName: "Studio Display"))
            var settings = AppSettings()
            settings.pauseOnBattery = true
            try store.saveSettings(settings)
        }
        let reopened = try SQLiteLibraryStore.open(at: url)
        #expect(reopened.recoveredFrom == nil)
        #expect(try reopened.store.allWallpapers().map(\.id) == ["a"])
        #expect(try reopened.store.favorites().map(\.0) == ["a"])
        #expect(try reopened.store.playlists().first?.name == "Evening")
        #expect(try reopened.store.assignments().first?.displayName == "Studio Display")
        #expect(try reopened.store.loadSettings().pauseOnBattery)
    }

    @Test func damagedDatabaseIsMovedAsideNotDeleted() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Library.sqlite")
        try Data(repeating: 0x42, count: 4096).write(to: url)
        let result = try SQLiteLibraryStore.open(at: url)
        let backup = try #require(result.recoveredFrom)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try result.store.allWallpapers().isEmpty)
    }

    @Test func schemaVersionIsRecorded() throws {
        let db = try SQLiteDatabase(url: nil)
        _ = try SQLiteLibraryStore(database: db)
        #expect(db.userVersion == SQLiteLibraryStore.schemaVersion)
    }

    @Test func transactionRollsBackOnError() throws {
        let db = try SQLiteDatabase(url: nil)
        try db.execute("CREATE TABLE t (x INTEGER);")
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (1);")
                throw Boom()
            }
        }
        #expect(try db.query("SELECT COUNT(*) AS n FROM t;").first?.int("n") == 0)
    }
}
