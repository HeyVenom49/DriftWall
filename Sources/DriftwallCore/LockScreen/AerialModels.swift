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
    case unsafePath(String)
    case conversionFailed(String)
    case backupFailed(String)
    case cancelled
    case privilegedStepFailed(String)
    case verificationFailed(String)
    case nothingToRestore
    case backupMissing

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable(let why): return "Apple’s Aerial videos aren’t available on this Mac: \(why)"
        case .invalidSlot: return "That Aerial isn’t downloaded on this Mac. Choose another one."
        case .unsafePath(let path): return "Refusing to write outside Apple’s Aerial folder (\(path))."
        case .conversionFailed(let why): return "The video couldn’t be converted to Apple’s Aerial format: \(why)"
        case .backupFailed(let why): return "Apple’s original video couldn’t be backed up, so nothing was changed: \(why)"
        case .cancelled: return "Cancelled. Nothing was changed."
        case .privilegedStepFailed(let why): return "macOS didn’t allow the change: \(why)"
        case .verificationFailed(let why): return "The change couldn’t be verified: \(why)"
        case .nothingToRestore: return "No Aerial has been replaced by Driftwall."
        case .backupMissing: return "The backup of Apple’s original video is missing. macOS can re-download the original: remove the file in Wallpaper settings or wait for the next Aerial update."
        }
    }
}

/// Reads Apple's Aerial catalog (`Customer/entries.json`) and the downloaded videos. Read-only.
public struct AerialCatalogReader: Sendable {
    public var root: URL   // /Library/Application Support/com.apple.idleassetsd/Customer
    public static let videoFolder = "4KSDR240FPS"

    public init(root: URL) { self.root = root }

    public static let systemRoot = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)

    public var videoDirectory: URL { root.appendingPathComponent(Self.videoFolder, isDirectory: true) }

    public func availableSlots() throws -> [AerialSlot] {
        let entriesURL = root.appendingPathComponent("entries.json")
        guard let data = try? Data(contentsOf: entriesURL) else {
            throw AerialError.storeUnavailable("its catalog (entries.json) was not found.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw AerialError.storeUnavailable("its catalog has an unexpected format.")
        }
        var slots: [AerialSlot] = []
        for asset in assets {
            guard let id = asset["id"] as? String, Self.isValidAssetID(id) else { continue }
            let file = videoDirectory.appendingPathComponent("\(id).mov")
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else { continue }
            let name = (asset["accessibilityLabel"] as? String) ?? (asset["localizedNameKey"] as? String) ?? id
            slots.append(AerialSlot(id: id, name: name, fileURL: file, fileSize: size))
        }
        return slots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apple asset IDs are uppercase UUIDs. Anything else is rejected before it can reach a file path.
    public static func isValidAssetID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id.count == 36 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

/// Builds the one privileged shell command. Kept pure so quoting and path checks are unit-tested.
public enum AerialCommandBuilder {
    /// Shell single-quote quoting: safe for any byte except NUL.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for use inside an AppleScript string literal.
    public static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Copies `source` over the Aerial file `destination` atomically, owned by root like Apple's files.
    public static func installCommand(source: URL, destination: URL, videoDirectory: URL) throws -> String {
        try validate(destination: destination, videoDirectory: videoDirectory)
        let dest = destination.standardizedFileURL.path
        let temp = dest + ".driftwall-incoming"
        return [
            "/bin/cp -f \(shellQuote(source.path)) \(shellQuote(temp))",
            "/usr/sbin/chown root:wheel \(shellQuote(temp))",
            "/bin/chmod 644 \(shellQuote(temp))",
            "/bin/mv -f \(shellQuote(temp)) \(shellQuote(dest))",
        ].joined(separator: " && ")
    }

    /// The destination must be exactly `<videoDirectory>/<valid asset UUID>.mov`.
    public static func validate(destination: URL, videoDirectory: URL) throws {
        let dest = destination.standardizedFileURL
        let name = dest.deletingPathExtension().lastPathComponent
        guard dest.deletingLastPathComponent().path == videoDirectory.standardizedFileURL.path,
              dest.pathExtension == "mov", AerialCatalogReader.isValidAssetID(name) else {
            throw AerialError.unsafePath(dest.path)
        }
    }

    public static func appleScript(forShellCommand command: String) -> String {
        "do shell script \(appleScriptLiteral(command)) with administrator privileges"
    }
}
