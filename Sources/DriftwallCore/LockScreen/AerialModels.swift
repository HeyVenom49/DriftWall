import Foundation

/// One of Apple's Aerial videos that is downloaded on this Mac and can therefore be replaced.
public struct AerialSlot: Identifiable, Hashable, Codable, Sendable {
    public var id: String          // Apple's asset UUID; the file is "<id>.mov"
    public var name: String        // e.g. "Sequoia Night"
    public var fileURL: URL
    public var fileSize: Int64
}

/// Written next to the backup whenever Driftwall replaces an Aerial. It is the source of truth for
/// what was changed, so a restore never depends on in-memory state.
public struct AerialInstallManifest: Codable, Equatable, Sendable {
    public var slotID: String
    public var slotName: String
    public var wallpaperID: WallpaperID
    public var wallpaperTitle: String
    public var originalSize: Int64
    public var installedSize: Int64
    public var backupPath: String
    public var installedAt: Date
    /// Whether the Aerial follows the lock-screen wallpaper when it changes (one-click setup). nil for
    /// installs made before this existed, which are treated as a fixed choice.
    public var followsWallpaper: Bool?
}

public enum AerialStatus: Equatable, Sendable {
    /// Nothing replaced (or everything restored).
    case notInstalled
    /// Driftwall's video is in place.
    case installed(AerialInstallManifest)
    /// macOS (an update or its Aerial downloader) put a different file back. The backup is kept.
    case replacedByMacOS(AerialInstallManifest)
    /// The Aerial store or its catalog is missing; the feature can't be used on this Mac.
    case unavailable(String)
}

public enum AerialError: LocalizedError, Equatable {
    case storeUnavailable(String)
    case invalidSlot
    case busy
    case unsafePath(String)
    case conversionFailed(String)
    case backupFailed(String)
    case originalModified(String)
    case writeFailed(String)
    case verificationFailed(String)
    case nothingToRestore
    case backupMissing

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable(let why): return "Apple’s Aerial videos aren’t available on this Mac: \(why)"
        case .invalidSlot: return "That Aerial isn’t downloaded on this Mac. Choose it once in Wallpaper settings so macOS downloads it, then try again."
        case .busy: return "Driftwall is already changing an Aerial. Wait for it to finish, then try again."
        case .unsafePath(let path): return "Refusing to write outside the Aerial video folder (\(path))."
        case .conversionFailed(let why): return "The video couldn’t be converted to Apple’s Aerial format: \(why)"
        case .backupFailed(let why): return "Apple’s original video couldn’t be backed up, so nothing was changed: \(why)"
        case .originalModified(let name): return "“\(name)” no longer contains Apple’s original video (it was changed earlier), and no original copy was found, so it can’t be backed up. Repair it in Options › Check Apple’s Aerials, or choose another Aerial."
        case .writeFailed(let why): return "The Aerial video couldn’t be replaced: \(why)"
        case .verificationFailed(let why): return "The change couldn’t be verified: \(why)"
        case .nothingToRestore: return "No Aerial has been replaced by Driftwall."
        case .backupMissing: return "The backup of Apple’s original video is missing. macOS downloads the original again if you delete the Aerial’s video in ~/Library/Application Support/com.apple.wallpaper/aerials/videos."
        }
    }
}

/// Reads the per-user Aerial wallpaper store that `WallpaperAerialsExtension` plays from:
/// `<root>/videos/<id>.mov` (downloaded videos) and `<root>/manifest/entries.json` (names). Read-only.
///
/// This is not the screen saver's store in `/Library/Application Support/com.apple.idleassetsd`: on
/// macOS 27 the wallpaper (and so the lock screen) downloads and plays its own copy from here.
public struct AerialCatalogReader: Sendable {
    public var root: URL   // ~/Library/Application Support/com.apple.wallpaper/aerials
    /// Other catalogs used only for names, for when the wallpaper's own catalog hasn't been downloaded.
    public var fallbackCatalogURLs: [URL]
    /// Other folders that may hold a copy of the same Aerial (`<id>.mov`), read only to find Apple's
    /// original when the wallpaper's own copy was changed.
    public var originalCopyDirectories: [URL]

    public init(root: URL, fallbackCatalogURLs: [URL] = [], originalCopyDirectories: [URL] = []) {
        self.root = root
        self.fallbackCatalogURLs = fallbackCatalogURLs
        self.originalCopyDirectories = originalCopyDirectories
    }

    public static var userRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    /// The screen saver's catalog. It lists the same Aerials, so it can name them.
    public static let systemCatalogURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/entries.json")
    /// The screen saver's own (world-readable) copies of the same Aerials.
    public static let systemVideoDirectory = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS", isDirectory: true)

    public var catalogURL: URL { root.appendingPathComponent("manifest/entries.json") }
    public var videoDirectory: URL { root.appendingPathComponent("videos", isDirectory: true) }

    /// Every downloaded Aerial video. The list comes from the video folder itself, so a missing or
    /// unreadable catalog only costs the names, never the Aerials. No folder (nothing downloaded for
    /// this user yet) is an empty list, not an error.
    public func availableSlots() throws -> [AerialSlot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: videoDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        let names = assetNames()
        var slots: [AerialSlot] = []
        for file in files where file.pathExtension == "mov" {
            let id = file.deletingPathExtension().lastPathComponent
            guard Self.isValidAssetID(id),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
            let name = names[id] ?? "Aerial \(id.prefix(8))"
            slots.append(AerialSlot(id: id, name: name, fileURL: file, fileSize: Int64(size)))
        }
        return slots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Asset ID → display name from the first catalog that names it.
    public func assetNames() -> [String: String] {
        var names: [String: String] = [:]
        for url in [catalogURL] + fallbackCatalogURLs {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else { continue }
            for asset in assets {
                guard let id = asset["id"] as? String, names[id] == nil,
                      let name = (asset["accessibilityLabel"] as? String) ?? (asset["localizedNameKey"] as? String) else { continue }
                names[id] = name
            }
        }
        return names
    }

    /// Apple asset IDs are uppercase UUIDs. Anything else is rejected before it can reach a file path.
    public static func isValidAssetID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id.count == 36 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The destination must be exactly `<videoDirectory>/<valid asset UUID>.mov`.
    public static func validate(destination: URL, videoDirectory: URL) throws {
        let dest = destination.standardizedFileURL
        let name = dest.deletingPathExtension().lastPathComponent
        guard dest.deletingLastPathComponent().path == videoDirectory.standardizedFileURL.path,
              dest.pathExtension == "mov", isValidAssetID(name) else {
            throw AerialError.unsafePath(dest.path)
        }
    }
}

/// Reads which Aerials are chosen as a *desktop* wallpaper (what macOS animates on the lock screen)
/// from the wallpaper store's `Index.plist`. The format isn't documented, so this only looks for the
/// given asset IDs anywhere under a "Desktop" entry, including inside nested property lists.
public enum AerialWallpaperStore {
    public static var indexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// The IDs from `known` chosen as a desktop wallpaper on any display or Space. nil when the store
    /// can't be read.
    public static func selectedAssetIDs(among known: Set<String>, indexURL: URL = indexURL) -> Set<String>? {
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return selectedAssetIDs(inIndex: root, among: known)
    }

    public static func selectedAssetIDs(inIndex root: Any, among known: Set<String>) -> Set<String> {
        var found = Set<String>()
        collect(root, known: known, inDesktop: false, depth: 0, into: &found)
        return found
    }

    /// Which of the given displays (by CoreGraphics UUID) show `assetID` as their desktop wallpaper
    /// right now, and so play it on the lock screen. `currentSpaces` maps a display to the Space it
    /// shows (see `currentSpaces(inSpacesPreferences:mainDisplayID:)`). nil when the store can't be read.
    public static func displays(showing assetID: String, among displayIDs: [String], currentSpaces: [String: String],
                                indexURL: URL = indexURL) -> Set<String>? {
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return displays(showing: assetID, among: displayIDs, currentSpaces: currentSpaces, inIndex: root)
    }

    /// For each display, its most specific entry with a desktop choice wins:
    /// 1. "Spaces/<current Space>/Displays/<UUID>" — what Wallpaper settings writes for a display while
    ///    "Show on all Spaces" is off (seen on macOS 27.0.1 for an external display),
    /// 2. "Displays/<UUID>",
    /// 3. "Spaces/<current Space>/Default",
    /// 4. "AllSpacesAndDisplays" (one wallpaper everywhere) for displays with no entry of their own.
    /// The order was inferred from one Mac, not documented. Most-specific-first means a stale or
    /// non-Aerial "AllSpacesAndDisplays" choice can't hide a display's own Aerial choice.
    public static func displays(showing assetID: String, among displayIDs: [String], currentSpaces: [String: String] = [:],
                                inIndex root: Any) -> Set<String> {
        guard let root = root as? [String: Any] else { return [] }
        func entry(_ dict: Any?, _ key: String) -> [String: Any]? {
            (dict as? [String: Any])?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value as? [String: Any]
        }
        func desktop(_ entry: [String: Any]?) -> Any? { entry?["Desktop"] }
        func shows(_ desktop: Any) -> Bool {
            !selectedAssetIDs(inIndex: ["Desktop": desktop], among: [assetID]).isEmpty
        }
        let everywhere = desktop(root["AllSpacesAndDisplays"] as? [String: Any])
        return Set(displayIDs.filter { id in
            let space = currentSpaces.first { $0.key.caseInsensitiveCompare(id) == .orderedSame }.flatMap { entry(root["Spaces"], $0.value) }
            let choice = desktop(entry(space?["Displays"], id))
                ?? desktop(entry(root["Displays"], id))
                ?? desktop(space?["Default"] as? [String: Any])
                ?? everywhere
            return choice.map(shows) ?? false
        })
    }

    /// The Space each display shows now, from the `com.apple.spaces` preference
    /// "SpacesDisplayConfiguration" › "Management Data" › "Monitors". Each monitor has a "Display
    /// Identifier" (a display UUID, or "Main" for the main display) and a "Current Space" with a "uuid"
    /// (empty for the original desktop, matching the "" key in the wallpaper store).
    public static func currentSpaces(inSpacesPreferences configuration: Any, mainDisplayID: String?) -> [String: String] {
        guard let management = (configuration as? [String: Any])?["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for monitor in monitors {
            guard var display = monitor["Display Identifier"] as? String,
                  let space = (monitor["Current Space"] as? [String: Any])?["uuid"] as? String else { continue }
            if display == "Main" {
                guard let mainDisplayID else { continue }
                display = mainDisplayID
            }
            result[display] = space
        }
        return result
    }

    private static func collect(_ value: Any, known: Set<String>, inDesktop: Bool, depth: Int, into found: inout Set<String>) {
        guard depth < 24 else { return }
        switch value {
        case let string as String:
            if inDesktop, let id = known.first(where: { string.caseInsensitiveCompare($0) == .orderedSame }) { found.insert(id) }
        case let data as Data:
            guard inDesktop else { return }
            if let nested = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                collect(nested, known: known, inDesktop: true, depth: depth + 1, into: &found)
            } else {
                for id in known where data.range(of: Data(id.utf8)) != nil { found.insert(id) }
            }
        case let dict as [String: Any]:
            for (key, child) in dict where key != "Idle" { // "Idle" holds the screen saver, not the wallpaper
                collect(child, known: known, inDesktop: inDesktop || key == "Desktop", depth: depth + 1, into: &found)
            }
        case let array as [Any]:
            for child in array { collect(child, known: known, inDesktop: inDesktop, depth: depth + 1, into: &found) }
        default:
            break
        }
    }
}
