import AppKit
import DriftwallCore
import ImageIO

/// Memory cache in front of the on-disk `ThumbnailService`. Grid cells request images here; full
/// videos are never opened for grid display (only a single frame is decoded, once, then cached).
/// JPEGs are decoded to bitmaps off the main thread: `NSImage(contentsOf:)` would defer decoding to
/// the first draw, which happens on the main thread while the grid scrolls.
@MainActor
final class ThumbnailLoader {
    private let service: ThumbnailService
    private let cache = NSCache<NSString, NSImage>()
    /// One load per wallpaper at a time; the same item often appears in several shelves at once.
    private var inFlight: [WallpaperID: Task<Decoded?, Never>] = [:]

    /// A decoded thumbnail and the memory its bitmap occupies, the NSCache cost.
    struct Decoded: @unchecked Sendable {
        let image: NSImage
        let bytes: Int
    }

    init(service: ThumbnailService) {
        self.service = service
        cache.countLimit = 300
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func cachedImage(for id: WallpaperID) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    func image(for wallpaper: Wallpaper, mediaURL: URL?) async -> NSImage? {
        if let cached = cachedImage(for: wallpaper.id) { return cached }
        if let running = inFlight[wallpaper.id] { return await running.value?.image }
        let service = service
        let task = Task<Decoded?, Never> {
            let fileURL: URL
            let existing = service.thumbnailURL(for: wallpaper.id)
            if await Self.fileExists(existing) {
                fileURL = existing
            } else {
                guard let mediaURL else { return nil }
                do {
                    fileURL = try await service.thumbnail(for: wallpaper.id, mediaURL: mediaURL, duration: wallpaper.duration)
                } catch {
                    DiagnosticsLog.shared.log(.warning, "thumbnails", "No thumbnail for “\(wallpaper.title)”: \(error.localizedDescription)")
                    return nil
                }
            }
            return await Task.detached(priority: .userInitiated) { Self.decodedImage(at: fileURL) }.value
        }
        inFlight[wallpaper.id] = task
        let decoded = await task.value
        inFlight[wallpaper.id] = nil
        if let decoded { cache.setObject(decoded.image, forKey: wallpaper.id as NSString, cost: decoded.bytes) }
        return decoded?.image
    }

    func invalidate(_ id: WallpaperID) {
        cache.removeObject(forKey: id as NSString)
    }

    func clearMemory() {
        cache.removeAllObjects()
    }

    private nonisolated static func fileExists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads and fully decodes the image now, so drawing it later is a plain bitmap copy.
    nonisolated static func decodedImage(at url: URL) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        // Cost is the real bitmap size in bytes; an image's point size depends on its DPI.
        return Decoded(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                       bytes: image.bytesPerRow * image.height)
    }
}
