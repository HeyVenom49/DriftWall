import AppKit
import DriftwallCore

/// Memory cache in front of the on-disk `ThumbnailService`. Grid cells request images here; full
/// videos are never opened for grid display (only a single frame is decoded, once, then cached).
@MainActor
final class ThumbnailLoader {
    private let service: ThumbnailService
    private let cache = NSCache<NSString, NSImage>()

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
        let fileURL: URL
        let existing = service.thumbnailURL(for: wallpaper.id)
        if FileManager.default.fileExists(atPath: existing.path) {
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
        let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: fileURL) }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: wallpaper.id as NSString, cost: cost)
        }
        return image
    }

    func invalidate(_ id: WallpaperID) {
        cache.removeObject(forKey: id as NSString)
    }

    func clearMemory() {
        cache.removeAllObjects()
    }
}
