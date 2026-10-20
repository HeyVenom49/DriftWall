import Foundation

public enum MediaAvailability: Equatable, Sendable {
    case available(URL)
    /// The bookmark located the file at a new path (moved or renamed); the record should be updated.
    case relocated(URL, refreshedBookmark: Data?)
    case missing
    case unreadable

    public var url: URL? {
        switch self {
        case .available(let url), .relocated(let url, _): return url
        case .missing, .unreadable: return nil
        }
    }

    public var isAvailable: Bool { url != nil }

    public var statusText: String {
        switch self {
        case .available: return "Available"
        case .relocated: return "Available (file moved)"
        case .missing: return "File missing"
        case .unreadable: return "File not readable"
        }
    }
}

/// Locates a wallpaper's media on disk without opening it.
public struct MediaResolver: Sendable {
    public var bundleResourcesURL: URL?

    public init(bundleResourcesURL: URL?) {
        self.bundleResourcesURL = bundleResourcesURL
    }

    public func resolve(_ wallpaper: Wallpaper) -> MediaAvailability {
        let fm = FileManager.default
        switch wallpaper.source {
        case .bundled:
            guard let base = bundleResourcesURL else { return .missing }
            let url = base.appendingPathComponent(wallpaper.mediaPath)
            return fm.fileExists(atPath: url.path) ? .available(url) : .missing

        case .imported:
            let recorded = URL(fileURLWithPath: wallpaper.mediaPath)
            if fm.fileExists(atPath: recorded.path) {
                return fm.isReadableFile(atPath: recorded.path) ? .available(recorded) : .unreadable
            }
            // The file is not where we last saw it: let the bookmark find it (handles moves/renames on the same volume).
            guard let bookmark = wallpaper.bookmark else { return .missing }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale),
                  fm.fileExists(atPath: url.path) else { return .missing }
            guard fm.isReadableFile(atPath: url.path) else { return .unreadable }
            let refreshed = isStale || url.path != recorded.path ? Self.makeBookmark(for: url) : nil
            return .relocated(url, refreshedBookmark: refreshed)
        }
    }

    public static func makeBookmark(for url: URL) -> Data? {
        // The app is not sandboxed, so a regular (non security-scoped) bookmark is sufficient and
        // lets us follow files that are renamed or moved within a volume.
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
