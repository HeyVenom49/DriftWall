import Foundation

/// The bundled catalog (`Resources/Catalog.json`): metadata for included sample wallpapers and
/// the curated collections shown on Home.
public struct Catalog: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var id: WallpaperID
        public var title: String
        public var summary: String
        public var category: String
        public var tags: [String]
        public var file: String
        public var featured: Bool?
        public var popularity: Int?
        public var creator: String?
    }

    public var version: Int
    public var wallpapers: [Entry]
    public var collections: [CuratedCollection]

    public static func load(from url: URL) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    /// Merges catalog entries into existing library records. Editorial fields come from the catalog;
    /// user-derived fields (usage, metadata already extracted) are preserved.
    public func merged(into existing: [Wallpaper], mediaSubdirectory: String, now: Date = Date()) -> [Wallpaper] {
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return wallpapers.enumerated().map { offset, entry in
            var wallpaper = byID[entry.id] ?? Wallpaper(
                id: entry.id, title: entry.title, category: entry.category, source: .bundled,
                mediaPath: "", importedAt: now.addingTimeInterval(TimeInterval(-offset))
            )
            wallpaper.title = entry.title
            wallpaper.summary = entry.summary
            wallpaper.category = entry.category
            wallpaper.tags = entry.tags
            wallpaper.source = .bundled
            wallpaper.mediaPath = mediaSubdirectory.isEmpty ? entry.file : "\(mediaSubdirectory)/\(entry.file)"
            wallpaper.isFeatured = entry.featured ?? false
            wallpaper.popularity = entry.popularity ?? 0
            wallpaper.creator = entry.creator
            return wallpaper
        }
    }
}
