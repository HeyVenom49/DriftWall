import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailError: LocalizedError {
    case encodingFailed
    public var errorDescription: String? { "The preview image could not be saved." }
}

/// Generates and caches still frames for wallpapers.
///
/// - Grid thumbnails are small JPEGs in `cacheDirectory/Thumbnails`, generated once and read from disk afterwards.
/// - Full-resolution poster frames (used to sync the static system wallpaper) live in `cacheDirectory/Frames`.
/// - At most `maxConcurrent` generations run at once and duplicate requests for the same item share one task,
///   so scrolling a large library never fans out into hundreds of decoders.
public actor ThumbnailService {
    public nonisolated let thumbnailsDirectory: URL
    public nonisolated let framesDirectory: URL
    private let maxPixelSize: CGSize
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(cacheDirectory: URL, maxPixelSize: CGSize = CGSize(width: 640, height: 640), maxConcurrent: Int = 2) {
        thumbnailsDirectory = cacheDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        framesDirectory = cacheDirectory.appendingPathComponent("Frames", isDirectory: true)
        self.maxPixelSize = maxPixelSize
        self.maxConcurrent = max(1, maxConcurrent)
        for dir in [thumbnailsDirectory, framesDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public nonisolated func thumbnailURL(for id: WallpaperID) -> URL {
        thumbnailsDirectory.appendingPathComponent(Self.safeName(id) + ".jpg")
    }

    public nonisolated func frameURL(for id: WallpaperID) -> URL {
        framesDirectory.appendingPathComponent(Self.safeName(id) + ".png")
    }

    /// Returns a cached thumbnail, generating it if needed.
    public func thumbnail(for id: WallpaperID, mediaURL: URL, duration: TimeInterval) async throws -> URL {
        let output = thumbnailURL(for: id)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        return try await generate(key: "thumb:" + id, output: output, mediaURL: mediaURL, time: Self.posterTime(duration), maxSize: maxPixelSize, jpeg: true)
    }

    /// Returns a full-resolution PNG frame, generating it if needed.
    public func posterFrame(for id: WallpaperID, mediaURL: URL, duration: TimeInterval) async throws -> URL {
        let output = frameURL(for: id)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        return try await generate(key: "frame:" + id, output: output, mediaURL: mediaURL, time: Self.posterTime(duration), maxSize: .zero, jpeg: false)
    }

    public func removeCachedImages(for id: WallpaperID) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: id))
        try? FileManager.default.removeItem(at: frameURL(for: id))
    }

    public nonisolated func cacheSize() -> Int64 {
        [thumbnailsDirectory, framesDirectory].reduce(0) { $0 + Self.directorySize($1) }
    }

    public func clearCache() {
        for dir in [thumbnailsDirectory, framesDirectory] {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Private

    private func generate(key: String, output: URL, mediaURL: URL, time: Double, maxSize: CGSize, jpeg: Bool) async throws -> URL {
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task<URL, Error> {
            await acquire()
            defer { release() }
            let image = try await Self.extractFrame(from: mediaURL, at: time, maxSize: maxSize)
            try Self.write(image, to: output, jpeg: jpeg)
            return output
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    static func posterTime(_ duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(duration * 0.25, 2.0)
    }

    static func extractFrame(from url: URL, at seconds: Double, maxSize: CGSize) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }

    static func write(_ image: CGImage, to url: URL, jpeg: Bool) throws {
        let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { throw ThumbnailError.encodingFailed }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.82] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            throw ThumbnailError.encodingFailed
        }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }

    static func safeName(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? String($0) : "_" }.joined()
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
