import Foundation
import Testing
@testable import DriftwallCore

@Suite("Search and filtering")
struct SearchTests {
    let engine = KeywordSearchEngine()
    let library: [Wallpaper] = [
        Fixtures.wallpaper("aurora", title: "Aurora Drift", category: "Nature", tags: ["night", "green"], summary: "Northern lights over snow",
                           width: 3840, height: 2160, importedAt: Date(timeIntervalSince1970: 100), popularity: 90),
        Fixtures.wallpaper("tide", title: "Deep Tide", category: "Nature", tags: ["ocean", "blue"], summary: "Rolling waves",
                           importedAt: Date(timeIntervalSince1970: 300), popularity: 50),
        Fixtures.wallpaper("grid", title: "Neon Horizon", category: "Retro", tags: ["synthwave", "grid"], summary: "A café at night",
                           width: 1280, height: 720, importedAt: Date(timeIntervalSince1970: 200), popularity: 70),
        Fixtures.wallpaper("mine", title: "Holiday Clip", category: "Imported", tags: ["imported"], source: .imported,
                           importedAt: Date(timeIntervalSince1970: 400)),
    ]

    func ids(_ query: SearchQuery, favorites: Set<WallpaperID> = []) -> [WallpaperID] {
        engine.search(query, in: library, context: SearchContext(favoriteIDs: favorites)).map(\.id)
    }

    @Test func matchesTitleDescriptionCategoryAndTags() {
        #expect(ids(SearchQuery(text: "tide")) == ["tide"])
        #expect(ids(SearchQuery(text: "waves")) == ["tide"])           // description
        #expect(ids(SearchQuery(text: "retro")) == ["grid"])           // category
        #expect(ids(SearchQuery(text: "synthwave")) == ["grid"])       // tag
    }

    @Test func incompleteWordsMatchByPrefix() {
        #expect(ids(SearchQuery(text: "auro")) == ["aurora"])
        #expect(ids(SearchQuery(text: "Oce")) == ["tide"])
    }

    @Test func allTokensMustMatch() {
        #expect(ids(SearchQuery(text: "night green")) == ["aurora"])
        #expect(ids(SearchQuery(text: "night ocean")).isEmpty)
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(ids(SearchQuery(text: "CAFE")) == ["grid"])
        #expect(ids(SearchQuery(text: "café")) == ["grid"])
    }

    @Test func titleMatchesRankAboveDescriptionMatches() {
        // "night" is a tag of aurora and in the description of grid: the tag match ranks higher.
        #expect(ids(SearchQuery(text: "night")) == ["aurora", "grid"])
    }

    @Test func emptyAndWhitespaceQueriesReturnEverything() {
        #expect(ids(SearchQuery(text: "")).count == library.count)
        #expect(ids(SearchQuery(text: "   ")).count == library.count)
        #expect(ids(SearchQuery(text: " - ,")).count == library.count)
    }

    @Test func noResults() {
        #expect(ids(SearchQuery(text: "xylophone")).isEmpty)
    }

    @Test func filters() {
        #expect(ids(SearchQuery(category: "nature")).sorted() == ["aurora", "tide"])
        #expect(ids(SearchQuery(source: .imported)) == ["mine"])
        #expect(ids(SearchQuery(favoritesOnly: true), favorites: ["tide"]) == ["tide"])
        #expect(ids(SearchQuery(minimumResolution: .uhd4k)) == ["aurora"])
        #expect(ids(SearchQuery(text: "a", category: "Retro")) == ["grid"])
    }

    @Test func sortOrders() {
        #expect(ids(SearchQuery(sort: .title)) == ["aurora", "tide", "mine", "grid"])
        #expect(ids(SearchQuery(sort: .newest)) == ["mine", "tide", "grid", "aurora"])
        #expect(ids(SearchQuery(sort: .popular)).prefix(3) == ["aurora", "grid", "tide"])
    }

    @Test func queryEmptiness() {
        #expect(SearchQuery().isEmpty)
        #expect(SearchQuery(sort: .title).isEmpty)
        #expect(!SearchQuery(text: "x").isEmpty)
        #expect(!SearchQuery(favoritesOnly: true).isEmpty)
    }

    @Test func resolutionClasses() {
        #expect(ResolutionClass(width: 3840, height: 2160) == .uhd4k)
        #expect(ResolutionClass(width: 2160, height: 3840) == .uhd4k) // portrait
        #expect(ResolutionClass(width: 1920, height: 1080) == .hd1080)
        #expect(ResolutionClass(width: 2560, height: 1440) == .qhd1440)
        #expect(ResolutionClass(width: 5120, height: 2880) == .uhd5kPlus)
        #expect(ResolutionClass(width: 640, height: 360) == .sd)
        #expect(ResolutionClass(width: 0, height: 0) == .unknown)
    }
}
