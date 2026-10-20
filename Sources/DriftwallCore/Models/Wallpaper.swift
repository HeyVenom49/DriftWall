import Foundation

public typealias WallpaperID = String

/// Where a wallpaper's media came from.
public enum WallpaperSource: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Ships inside the application bundle (original, procedurally generated samples).
    case bundled
    /// Imported by the user from a local file.
    case imported

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bundled: return "Included"
        case .imported: return "Imported"
        }
    }
}

/// A wallpaper in the local library. Favorite state lives in its own table and is not duplicated here.
public struct Wallpaper: Identifiable, Hashable, Codable, Sendable {
    public var id: WallpaperID
    public var title: String
    public var summary: String
    public var category: String
    public var tags: [String]
    public var source: WallpaperSource
    /// For bundled media: a path relative to the bundle's resources. For imported media: the last known absolute path.
    public var mediaPath: String
    /// Bookmark data for imported media, used to follow files that are moved or renamed.
    public var bookmark: Data?
    /// True when the media file was copied into the app's library folder and is therefore owned by the app.
    public var ownsMediaFile: Bool
    public var duration: TimeInterval
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var frameRate: Double
    public var codec: String?
    public var fileSize: Int64
    public var importedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var isFeatured: Bool
    /// Curated baseline popularity (bundled content). Combined with `useCount` for "Popular" ordering.
    public var popularity: Int
    /// Attribution / source information, when known.
    public var creator: String?

    public init(
        id: WallpaperID,
        title: String,
        summary: String = "",
        category: String,
        tags: [String] = [],
        source: WallpaperSource,
        mediaPath: String,
        bookmark: Data? = nil,
        ownsMediaFile: Bool = false,
        duration: TimeInterval = 0,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        frameRate: Double = 0,
        codec: String? = nil,
        fileSize: Int64 = 0,
        importedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        isFeatured: Bool = false,
        popularity: Int = 0,
        creator: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.tags = tags
        self.source = source
        self.mediaPath = mediaPath
        self.bookmark = bookmark
        self.ownsMediaFile = ownsMediaFile
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
        self.codec = codec
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isFeatured = isFeatured
        self.popularity = popularity
        self.creator = creator
    }

    public var hasMetadata: Bool { duration > 0 && pixelWidth > 0 && pixelHeight > 0 }

    public var resolutionClass: ResolutionClass { ResolutionClass(width: pixelWidth, height: pixelHeight) }

    public var isPortrait: Bool { pixelHeight > pixelWidth }

    /// Popularity used for "Popular" sorting: curated baseline plus how often the user applied it.
    public var popularityScore: Int { popularity + useCount * 10 }

    public var resolutionText: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "Unknown" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    public var durationText: String { Self.formatDuration(duration) }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Coarse resolution buckets used for filtering and badges.
public enum ResolutionClass: Int, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case unknown = 0
    case sd
    case hd720
    case hd1080
    case qhd1440
    case uhd4k
    case uhd5kPlus

    public init(width: Int, height: Int) {
        let long = max(width, height)
        let short = min(width, height)
        switch (long, short) {
        case (0, _), (_, 0): self = .unknown
        case (5000..., _): self = .uhd5kPlus
        case (3800..., _), (_, 2100...): self = .uhd4k
        case (2500..., _), (_, 1400...): self = .qhd1440
        case (1900..., _), (_, 1000...): self = .hd1080
        case (1270..., _), (_, 700...): self = .hd720
        default: self = .sd
        }
    }

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .sd: return "SD"
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .qhd1440: return "1440p"
        case .uhd4k: return "4K"
        case .uhd5kPlus: return "5K+"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Playlist: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    /// Ordered wallpaper identifiers. Deleting a playlist never touches the wallpapers or their media.
    public var itemIDs: [WallpaperID]

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), itemIDs: [WallpaperID] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.itemIDs = itemIDs
    }
}

public enum HistoryKind: String, Codable, Sendable {
    case viewed
    case applied
}

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var wallpaperID: WallpaperID
    public var kind: HistoryKind
    public var date: Date

    public init(id: Int64, wallpaperID: WallpaperID, kind: HistoryKind, date: Date) {
        self.id = id
        self.wallpaperID = wallpaperID
        self.kind = kind
        self.date = date
    }
}

/// A persisted wallpaper assignment for a display, keyed by the display's stable UUID so it can be
/// recovered when the display is reconnected.
public struct DisplayAssignment: Hashable, Codable, Sendable {
    public var displayID: String
    public var wallpaperID: WallpaperID
    public var displayName: String
    public var updatedAt: Date

    public init(displayID: String, wallpaperID: WallpaperID, displayName: String, updatedAt: Date = Date()) {
        self.displayID = displayID
        self.wallpaperID = wallpaperID
        self.displayName = displayName
        self.updatedAt = updatedAt
    }
}

/// A curated group of bundled wallpapers shown on the Home screen.
public struct CuratedCollection: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var wallpaperIDs: [WallpaperID]

    public init(id: String, title: String, subtitle: String, wallpaperIDs: [WallpaperID]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.wallpaperIDs = wallpaperIDs
    }
}
