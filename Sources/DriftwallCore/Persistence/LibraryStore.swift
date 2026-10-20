import Foundation

/// Persistence boundary for all user state. The app uses `SQLiteLibraryStore`; tests may use an
/// in-memory SQLite instance through the same type.
public protocol LibraryStore: AnyObject, Sendable {
    func allWallpapers() throws -> [Wallpaper]
    func upsert(_ wallpaper: Wallpaper) throws
    func upsert(_ wallpapers: [Wallpaper]) throws
    func deleteWallpaper(id: WallpaperID) throws
    func markUsed(id: WallpaperID, at date: Date) throws

    func favorites() throws -> [(WallpaperID, Date)]
    func setFavorite(id: WallpaperID, isFavorite: Bool, at date: Date) throws

    func recordHistory(id: WallpaperID, kind: HistoryKind, at date: Date) throws
    func history(limit: Int) throws -> [HistoryEntry]
    func clearHistory() throws

    func playlists() throws -> [Playlist]
    func save(_ playlist: Playlist) throws
    func deletePlaylist(id: String) throws

    func assignments() throws -> [DisplayAssignment]
    func setAssignment(_ assignment: DisplayAssignment) throws
    func removeAssignment(displayID: String) throws

    func loadSettings() throws -> AppSettings
    func saveSettings(_ settings: AppSettings) throws
}

public final class SQLiteLibraryStore: LibraryStore, @unchecked Sendable {
    public static let schemaVersion = 1
    /// History is pruned to this many rows so the table cannot grow without bound.
    public static let historyLimit = 500

    let db: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: SQLiteDatabase) throws {
        db = database
        try migrate()
    }

    /// Opens the store at `url`. If the file exists but is damaged, it is moved aside (never deleted)
    /// and a fresh database is created; `recoveredFrom` reports where the damaged copy went.
    public static func open(at url: URL) throws -> (store: SQLiteLibraryStore, recoveredFrom: URL?) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let database = try SQLiteDatabase(url: url)
            guard database.integrityCheck() else { throw DatabaseError(code: 11, message: "integrity check failed", sql: nil) }
            return (try SQLiteLibraryStore(database: database), nil)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).damaged-\(stamp)")
            try FileManager.default.moveItem(at: url, to: backup)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            let database = try SQLiteDatabase(url: url)
            return (try SQLiteLibraryStore(database: database), backup)
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = db.userVersion
        guard version < Self.schemaVersion else { return }
        try db.transaction {
            if version < 1 {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS wallpapers (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    summary TEXT NOT NULL DEFAULT '',
                    category TEXT NOT NULL,
                    tags TEXT NOT NULL DEFAULT '[]',
                    source TEXT NOT NULL,
                    media_path TEXT NOT NULL,
                    bookmark BLOB,
                    owns_media INTEGER NOT NULL DEFAULT 0,
                    duration REAL NOT NULL DEFAULT 0,
                    pixel_width INTEGER NOT NULL DEFAULT 0,
                    pixel_height INTEGER NOT NULL DEFAULT 0,
                    frame_rate REAL NOT NULL DEFAULT 0,
                    codec TEXT,
                    file_size INTEGER NOT NULL DEFAULT 0,
                    imported_at REAL NOT NULL,
                    last_used_at REAL,
                    use_count INTEGER NOT NULL DEFAULT 0,
                    featured INTEGER NOT NULL DEFAULT 0,
                    popularity INTEGER NOT NULL DEFAULT 0,
                    creator TEXT
                );
                CREATE TABLE IF NOT EXISTS favorites (
                    wallpaper_id TEXT PRIMARY KEY REFERENCES wallpapers(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    wallpaper_id TEXT NOT NULL REFERENCES wallpapers(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS history_at ON history(at DESC);
                CREATE TABLE IF NOT EXISTS playlists (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS playlist_items (
                    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    wallpaper_id TEXT NOT NULL REFERENCES wallpapers(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (playlist_id, wallpaper_id)
                );
                CREATE TABLE IF NOT EXISTS display_assignments (
                    display_id TEXT PRIMARY KEY,
                    wallpaper_id TEXT NOT NULL REFERENCES wallpapers(id) ON DELETE CASCADE,
                    display_name TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value BLOB NOT NULL
                );
                """)
            }
            // Future migrations: `if version < 2 { ALTER TABLE ... }`
            try db.setUserVersion(Self.schemaVersion)
        }
    }

    // MARK: - Wallpapers

    public func allWallpapers() throws -> [Wallpaper] {
        try db.query("SELECT * FROM wallpapers ORDER BY imported_at ASC;").compactMap(wallpaper(from:))
    }

    public func upsert(_ wallpaper: Wallpaper) throws {
        try upsert([wallpaper])
    }

    public func upsert(_ wallpapers: [Wallpaper]) throws {
        guard !wallpapers.isEmpty else { return }
        try db.transaction {
            for w in wallpapers {
                let tags = String(data: try encoder.encode(w.tags), encoding: .utf8) ?? "[]"
                try db.run("""
                INSERT INTO wallpapers (id, title, summary, category, tags, source, media_path, bookmark, owns_media,
                    duration, pixel_width, pixel_height, frame_rate, codec, file_size, imported_at, last_used_at,
                    use_count, featured, popularity, creator)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title, summary=excluded.summary, category=excluded.category, tags=excluded.tags,
                    source=excluded.source, media_path=excluded.media_path, bookmark=excluded.bookmark,
                    owns_media=excluded.owns_media, duration=excluded.duration, pixel_width=excluded.pixel_width,
                    pixel_height=excluded.pixel_height, frame_rate=excluded.frame_rate, codec=excluded.codec,
                    file_size=excluded.file_size, imported_at=excluded.imported_at, last_used_at=excluded.last_used_at,
                    use_count=excluded.use_count, featured=excluded.featured, popularity=excluded.popularity,
                    creator=excluded.creator;
                """, [
                    .text(w.id), .text(w.title), .text(w.summary), .text(w.category), .text(tags),
                    .text(w.source.rawValue), .text(w.mediaPath), SQLValue(w.bookmark), SQLValue(w.ownsMediaFile),
                    .real(w.duration), SQLValue(w.pixelWidth), SQLValue(w.pixelHeight), .real(w.frameRate),
                    SQLValue(w.codec), .integer(w.fileSize), SQLValue(w.importedAt), SQLValue(w.lastUsedAt),
                    SQLValue(w.useCount), SQLValue(w.isFeatured), SQLValue(w.popularity), SQLValue(w.creator),
                ])
            }
        }
    }

    public func deleteWallpaper(id: WallpaperID) throws {
        // Cascades remove favorites, history, playlist entries and display assignments for this row.
        // Media files are never touched here.
        try db.run("DELETE FROM wallpapers WHERE id = ?;", [.text(id)])
    }

    public func markUsed(id: WallpaperID, at date: Date) throws {
        try db.run("UPDATE wallpapers SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?;", [SQLValue(date), .text(id)])
    }

    private func wallpaper(from row: SQLRow) -> Wallpaper? {
        guard let id = row.string("id"), let title = row.string("title"),
              let source = row.string("source").flatMap(WallpaperSource.init(rawValue:)),
              let mediaPath = row.string("media_path") else { return nil }
        let tags = row.string("tags").flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
        return Wallpaper(
            id: id, title: title, summary: row.string("summary") ?? "", category: row.string("category") ?? "Other",
            tags: tags, source: source, mediaPath: mediaPath, bookmark: row.data("bookmark"),
            ownsMediaFile: row.bool("owns_media"), duration: row.double("duration") ?? 0,
            pixelWidth: Int(row.int("pixel_width") ?? 0), pixelHeight: Int(row.int("pixel_height") ?? 0),
            frameRate: row.double("frame_rate") ?? 0, codec: row.string("codec"), fileSize: row.int("file_size") ?? 0,
            importedAt: row.date("imported_at") ?? Date(timeIntervalSince1970: 0), lastUsedAt: row.date("last_used_at"),
            useCount: Int(row.int("use_count") ?? 0), isFeatured: row.bool("featured"),
            popularity: Int(row.int("popularity") ?? 0), creator: row.string("creator")
        )
    }

    // MARK: - Favorites

    public func favorites() throws -> [(WallpaperID, Date)] {
        try db.query("SELECT wallpaper_id, created_at FROM favorites ORDER BY created_at DESC;").compactMap { row in
            guard let id = row.string("wallpaper_id") else { return nil }
            return (id, row.date("created_at") ?? Date())
        }
    }

    public func setFavorite(id: WallpaperID, isFavorite: Bool, at date: Date) throws {
        if isFavorite {
            try db.run("INSERT OR IGNORE INTO favorites (wallpaper_id, created_at) VALUES (?, ?);", [.text(id), SQLValue(date)])
        } else {
            try db.run("DELETE FROM favorites WHERE wallpaper_id = ?;", [.text(id)])
        }
    }

    // MARK: - History

    public func recordHistory(id: WallpaperID, kind: HistoryKind, at date: Date) throws {
        try db.run("INSERT INTO history (wallpaper_id, kind, at) VALUES (?, ?, ?);", [.text(id), .text(kind.rawValue), SQLValue(date)])
        try db.run("""
        DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY at DESC, id DESC LIMIT \(Self.historyLimit));
        """)
    }

    public func history(limit: Int) throws -> [HistoryEntry] {
        try db.query("SELECT * FROM history ORDER BY at DESC, id DESC LIMIT ?;", [SQLValue(limit)]).compactMap { row in
            guard let rowID = row.int("id"), let id = row.string("wallpaper_id"),
                  let kind = row.string("kind").flatMap(HistoryKind.init(rawValue:)), let date = row.date("at") else { return nil }
            return HistoryEntry(id: rowID, wallpaperID: id, kind: kind, date: date)
        }
    }

    public func clearHistory() throws {
        try db.run("DELETE FROM history;")
    }

    // MARK: - Playlists

    public func playlists() throws -> [Playlist] {
        let items = try db.query("SELECT playlist_id, wallpaper_id FROM playlist_items ORDER BY playlist_id, position ASC;")
        var itemsByPlaylist: [String: [WallpaperID]] = [:]
        for row in items {
            guard let pid = row.string("playlist_id"), let wid = row.string("wallpaper_id") else { continue }
            itemsByPlaylist[pid, default: []].append(wid)
        }
        return try db.query("SELECT * FROM playlists ORDER BY created_at ASC;").compactMap { row in
            guard let id = row.string("id"), let name = row.string("name") else { return nil }
            return Playlist(id: id, name: name, createdAt: row.date("created_at") ?? Date(), itemIDs: itemsByPlaylist[id] ?? [])
        }
    }

    public func save(_ playlist: Playlist) throws {
        try db.transaction {
            try db.run("""
            INSERT INTO playlists (id, name, created_at) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name;
            """, [.text(playlist.id), .text(playlist.name), SQLValue(playlist.createdAt)])
            try db.run("DELETE FROM playlist_items WHERE playlist_id = ?;", [.text(playlist.id)])
            var seen = Set<WallpaperID>()
            for (position, wallpaperID) in playlist.itemIDs.enumerated() where seen.insert(wallpaperID).inserted {
                try db.run("INSERT INTO playlist_items (playlist_id, wallpaper_id, position) VALUES (?, ?, ?);",
                           [.text(playlist.id), .text(wallpaperID), SQLValue(position)])
            }
        }
    }

    public func deletePlaylist(id: String) throws {
        try db.run("DELETE FROM playlists WHERE id = ?;", [.text(id)])
    }

    // MARK: - Display assignments

    public func assignments() throws -> [DisplayAssignment] {
        try db.query("SELECT * FROM display_assignments ORDER BY updated_at DESC;").compactMap { row in
            guard let displayID = row.string("display_id"), let wallpaperID = row.string("wallpaper_id") else { return nil }
            return DisplayAssignment(displayID: displayID, wallpaperID: wallpaperID,
                                     displayName: row.string("display_name") ?? "Display",
                                     updatedAt: row.date("updated_at") ?? Date())
        }
    }

    public func setAssignment(_ assignment: DisplayAssignment) throws {
        try db.run("""
        INSERT INTO display_assignments (display_id, wallpaper_id, display_name, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(display_id) DO UPDATE SET wallpaper_id = excluded.wallpaper_id,
            display_name = excluded.display_name, updated_at = excluded.updated_at;
        """, [.text(assignment.displayID), .text(assignment.wallpaperID), .text(assignment.displayName), SQLValue(assignment.updatedAt)])
    }

    public func removeAssignment(displayID: String) throws {
        try db.run("DELETE FROM display_assignments WHERE display_id = ?;", [.text(displayID)])
    }

    // MARK: - Settings

    public func loadSettings() throws -> AppSettings {
        guard let data = try db.query("SELECT value FROM settings WHERE key = 'app';").first?.data("value") else {
            return AppSettings()
        }
        return (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
        try db.run("INSERT INTO settings (key, value) VALUES ('app', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;", [.blob(data)])
    }
}
