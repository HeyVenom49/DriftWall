import Foundation

public struct ImportOutcome: Sendable {
    public var url: URL
    public var result: Result<Wallpaper, Error>

    public var wallpaper: Wallpaper? { try? result.get() }
    public var errorMessage: String? {
        if case .failure(let error) = result { return error.localizedDescription }
        return nil
    }
}

/// Validates local video files and turns them into library records.
/// Original files are referenced in place (with a bookmark) unless copying into the library is requested;
/// the importer never modifies or deletes the user's original file.
public struct MediaImporter: Sendable {
    public var inspector: MediaInspector
    public var libraryMediaDirectory: URL

    public init(inspector: MediaInspector = MediaInspector(), libraryMediaDirectory: URL) {
        self.inspector = inspector
        self.libraryMediaDirectory = libraryMediaDirectory
    }

    /// Imports a single file. `existing` is used to reject duplicates of the same file.
    public func importFile(at url: URL, copyIntoLibrary: Bool, existing: [Wallpaper], now: Date = Date()) async throws -> Wallpaper {
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        if let duplicate = existing.first(where: { $0.source == .imported && URL(fileURLWithPath: $0.mediaPath).standardizedFileURL.resolvingSymlinksInPath() == source }) {
            throw MediaValidationError.alreadyImported(title: duplicate.title)
        }

        let metadata = try await inspector.inspect(source)
        let id = "user." + UUID().uuidString.lowercased()

        var mediaURL = source
        if copyIntoLibrary {
            try FileManager.default.createDirectory(at: libraryMediaDirectory, withIntermediateDirectories: true)
            let destination = libraryMediaDirectory.appendingPathComponent("\(id).\(source.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: source, to: destination)
            mediaURL = destination
        }

        return Wallpaper(
            id: id,
            title: Self.title(from: source),
            summary: "Imported from “\(source.lastPathComponent)”.",
            category: "Imported",
            tags: Self.derivedTags(for: metadata),
            source: .imported,
            mediaPath: mediaURL.path,
            bookmark: MediaResolver.makeBookmark(for: mediaURL),
            ownsMediaFile: copyIntoLibrary,
            duration: metadata.duration,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            frameRate: metadata.frameRate,
            codec: metadata.codec,
            fileSize: metadata.fileSize,
            importedAt: now,
            creator: "You"
        )
    }

    /// Builds a readable title from a file name: "my_cool-clip_4k.mp4" → "My Cool Clip 4k".
    public static func title(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let words = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map { word -> String in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
        let title = words.joined(separator: " ")
        return title.isEmpty ? "Untitled Video" : title
    }

    static func derivedTags(for metadata: MediaMetadata) -> [String] {
        var tags = ["imported"]
        let resolution = ResolutionClass(width: metadata.pixelWidth, height: metadata.pixelHeight)
        if resolution != .unknown { tags.append(resolution.label.lowercased()) }
        if metadata.pixelHeight > metadata.pixelWidth { tags.append("portrait") }
        if let codec = metadata.codec { tags.append(codec.lowercased()) }
        if metadata.duration < 15 { tags.append("short loop") }
        return tags
    }
}
