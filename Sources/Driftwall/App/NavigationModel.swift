import DriftwallCore
import Observation

enum SidebarItem: Hashable {
    case home, explore, favorites, recent, library, displays, lockScreen, playlists
    case playlist(String)

    var title: String {
        switch self {
        case .home: return "Home"
        case .explore: return "Explore"
        case .favorites: return "Favorites"
        case .recent: return "Recent"
        case .library: return "My Videos"
        case .displays: return "Displays"
        case .lockScreen: return "Lock Screen"
        case .playlists: return "Playlists"
        case .playlist: return "Playlist"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .explore: return "square.grid.2x2"
        case .favorites: return "heart"
        case .recent: return "clock.arrow.circlepath"
        case .library: return "film.stack"
        case .displays: return "display.2"
        case .lockScreen: return "lock.display"
        case .playlists: return "list.bullet.rectangle"
        case .playlist: return "music.note.list"
        }
    }
}

/// UI navigation state: sidebar selection, the pushed detail stack and the shared search query.
@MainActor
@Observable
final class NavigationModel {
    var selection: SidebarItem? = .home {
        didSet { if selection != oldValue { path.removeAll() } }
    }
    var path: [WallpaperID] = []
    var query = SearchQuery()
    var showOnboarding = false

    var detailWallpaperID: WallpaperID? {
        get { path.last }
        set {
            if let newValue { path.append(newValue) } else { path.removeAll() }
        }
    }

    func open(_ id: WallpaperID) {
        if path.last != id { path.append(id) }
    }

    func show(_ item: SidebarItem) {
        selection = item
    }

    /// Opens Explore filtered to a category.
    func explore(category: String?) {
        query = SearchQuery(text: "", category: category)
        selection = .explore
    }
}
