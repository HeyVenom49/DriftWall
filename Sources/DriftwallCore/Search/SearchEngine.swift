import Foundation

public enum WallpaperSortOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case relevance, title, newest, recentlyUsed, popular, duration
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .relevance: return "Relevance"
        case .title: return "Title"
        case .newest: return "Recently Added"
        case .recentlyUsed: return "Recently Used"
        case .popular: return "Popular"
        case .duration: return "Duration"
        }
    }
}

public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var category: String?
    public var source: WallpaperSource?
    public var favoritesOnly: Bool
    public var minimumResolution: ResolutionClass?
    public var sort: WallpaperSortOrder

    public init(text: String = "", category: String? = nil, source: WallpaperSource? = nil,
                favoritesOnly: Bool = false, minimumResolution: ResolutionClass? = nil,
                sort: WallpaperSortOrder = .relevance) {
        self.text = text
        self.category = category
        self.source = source
        self.favoritesOnly = favoritesOnly
        self.minimumResolution = minimumResolution
        self.sort = sort
    }

    /// True when no filter other than sort order is active.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && category == nil && source == nil
            && !favoritesOnly && minimumResolution == nil
    }
}

/// Extra state needed to evaluate a query that does not live on `Wallpaper` itself.
public struct SearchContext: Sendable {
    public var favoriteIDs: Set<WallpaperID>
    public init(favoriteIDs: Set<WallpaperID> = []) { self.favoriteIDs = favoriteIDs }
}

/// Search abstraction. `KeywordSearchEngine` is the only implementation today: it performs local,
/// deterministic keyword matching. A future semantic engine (for example one backed by on-device
/// embeddings) can conform to this protocol without changing any callers.
public protocol WallpaperSearchEngine: Sendable {
    func search(_ query: SearchQuery, in wallpapers: [Wallpaper], context: SearchContext) -> [Wallpaper]
}

/// Local keyword search over title, description, category and tags.
///
/// Matching rules:
/// - The query is split into tokens; matching is case- and diacritic-insensitive.
/// - Every token must match some field (AND semantics), so adding words narrows results.
/// - A token matches a word when the word starts with it, so incomplete input like "auro" finds "Aurora".
/// - Tokens of three or more characters also match anywhere inside the title.
/// - Results are ranked by where tokens matched: title > tags > category > description.
public struct KeywordSearchEngine: WallpaperSearchEngine {
    public init() {}

    public func search(_ query: SearchQuery, in wallpapers: [Wallpaper], context: SearchContext) -> [Wallpaper] {
        let tokens = Self.tokenize(query.text)
        var scored: [(wallpaper: Wallpaper, score: Int)] = []
        scored.reserveCapacity(wallpapers.count)

        for wallpaper in wallpapers {
            if let category = query.category, wallpaper.category.caseInsensitiveCompare(category) != .orderedSame { continue }
            if let source = query.source, wallpaper.source != source { continue }
            if query.favoritesOnly, !context.favoriteIDs.contains(wallpaper.id) { continue }
            if let minimum = query.minimumResolution, wallpaper.resolutionClass < minimum { continue }

            if tokens.isEmpty {
                scored.append((wallpaper, 0))
            } else if let score = Self.score(wallpaper, tokens: tokens) {
                scored.append((wallpaper, score))
            }
        }

        let sort = (query.sort == .relevance && tokens.isEmpty) ? WallpaperSortOrder.popular : query.sort
        scored.sort { lhs, rhs in
            switch sort {
            case .relevance:
                if lhs.score != rhs.score { return lhs.score > rhs.score }
            case .title:
                break
            case .newest:
                if lhs.wallpaper.importedAt != rhs.wallpaper.importedAt { return lhs.wallpaper.importedAt > rhs.wallpaper.importedAt }
            case .recentlyUsed:
                let l = lhs.wallpaper.lastUsedAt ?? .distantPast, r = rhs.wallpaper.lastUsedAt ?? .distantPast
                if l != r { return l > r }
            case .popular:
                if lhs.wallpaper.isFeatured != rhs.wallpaper.isFeatured { return lhs.wallpaper.isFeatured }
                if lhs.wallpaper.popularityScore != rhs.wallpaper.popularityScore {
                    return lhs.wallpaper.popularityScore > rhs.wallpaper.popularityScore
                }
            case .duration:
                if lhs.wallpaper.duration != rhs.wallpaper.duration { return lhs.wallpaper.duration > rhs.wallpaper.duration }
            }
            // Stable, deterministic tie-breaker.
            let order = lhs.wallpaper.title.localizedStandardCompare(rhs.wallpaper.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.wallpaper.id < rhs.wallpaper.id
        }
        return scored.map(\.wallpaper)
    }

    public static func tokenize(_ text: String) -> [String] {
        normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
    }

    /// Returns nil when any token fails to match.
    static func score(_ wallpaper: Wallpaper, tokens: [String]) -> Int? {
        let titleText = normalize(wallpaper.title)
        let titleWords = tokenize(wallpaper.title)
        let tagWords = wallpaper.tags.flatMap(tokenize)
        let categoryWords = tokenize(wallpaper.category)
        let summaryWords = tokenize(wallpaper.summary)

        var total = 0
        for token in tokens {
            var best = 0
            if titleWords.contains(token) { best = max(best, 120) }
            if titleWords.contains(where: { $0.hasPrefix(token) }) { best = max(best, 100) }
            if token.count >= 3, titleText.contains(token) { best = max(best, 60) }
            if tagWords.contains(where: { $0.hasPrefix(token) }) { best = max(best, 50) }
            if categoryWords.contains(where: { $0.hasPrefix(token) }) { best = max(best, 40) }
            if summaryWords.contains(where: { $0.hasPrefix(token) }) { best = max(best, 15) }
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }
}
