import Foundation
import Testing
@testable import DriftwallCore

/// Integration tests that run real AVFoundation decoding against small generated videos.
@Suite("Media import, metadata and thumbnails")
struct MediaTests {
    @Test func inspectsRealVideoMetadata() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await Fixtures.makeVideo(at: video, width: 320, height: 180, frames: 30, fps: 30)

        let metadata = try await MediaInspector().inspect(video)
        #expect(metadata.pixelWidth == 320)
        #expect(metadata.pixelHeight == 180)
        #expect(abs(metadata.duration - 1.0) < 0.1)
        #expect(metadata.codec == "H.264")
        #expect(metadata.fileSize > 0)
        #expect(metadata.frameRate > 0)
    }

    @Test func rejectsUnsupportedExtension() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        await #expect(throws: MediaValidationError.unsupportedType("notes.txt")) {
            try await MediaInspector().inspect(text)
        }
        let gif = dir.appendingPathComponent("loop.gif")
        FileManager.default.createFile(atPath: gif.path, contents: Data([0]))
        #expect(throws: MediaValidationError.unsupportedType("loop.gif")) { try MediaInspector().preflight(gif) }
    }

    @Test func rejectsMissingFile() async {
        let missing = URL(fileURLWithPath: "/nonexistent/folder/clip.mp4")
        await #expect(throws: MediaValidationError.fileNotFound("clip.mp4")) {
            try await MediaInspector().inspect(missing)
        }
    }

    @Test func rejectsCorruptVideoWithMovieExtension() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("fake.mp4")
        try Data(repeating: 0x7F, count: 2048).write(to: fake)
        await #expect(throws: (any Error).self) {
            try await MediaInspector().inspect(fake)
        }
    }

    @Test func importReferencesOriginalInPlace() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("my_summer-trip.mov")
        try await Fixtures.makeVideo(at: video)
        let importer = MediaImporter(libraryMediaDirectory: dir.appendingPathComponent("Media"))

        let wallpaper = try await importer.importFile(at: video, copyIntoLibrary: false, existing: [])
        #expect(wallpaper.source == .imported)
        #expect(wallpaper.title == "My Summer Trip")
        #expect(!wallpaper.ownsMediaFile)
        #expect(wallpaper.bookmark != nil)
        #expect(URL(fileURLWithPath: wallpaper.mediaPath).resolvingSymlinksInPath() == video.resolvingSymlinksInPath())
        #expect(wallpaper.hasMetadata)
        #expect(wallpaper.tags.contains("imported"))

        await #expect(throws: MediaValidationError.alreadyImported(title: "My Summer Trip")) {
            try await importer.importFile(at: video, copyIntoLibrary: false, existing: [wallpaper])
        }
    }

    @Test func importCanCopyIntoLibrary() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await Fixtures.makeVideo(at: video)
        let mediaDir = dir.appendingPathComponent("Media")
        let wallpaper = try await MediaImporter(libraryMediaDirectory: mediaDir).importFile(at: video, copyIntoLibrary: true, existing: [])
        #expect(wallpaper.ownsMediaFile)
        #expect(wallpaper.mediaPath.hasPrefix(mediaDir.path))
        #expect(FileManager.default.fileExists(atPath: wallpaper.mediaPath))
        #expect(FileManager.default.fileExists(atPath: video.path)) // original untouched
    }

    @Test func titleDerivation() {
        #expect(MediaImporter.title(from: URL(fileURLWithPath: "/a/ocean_waves-4k.mp4")) == "Ocean Waves 4k")
        #expect(MediaImporter.title(from: URL(fileURLWithPath: "/a/___.mov")) == "Untitled Video")
    }

    @Test func generatesAndCachesThumbnails() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await Fixtures.makeVideo(at: video, width: 1280, height: 720, frames: 60)
        let service = ThumbnailService(cacheDirectory: dir.appendingPathComponent("Cache"), maxPixelSize: CGSize(width: 320, height: 320))

        let url = try await service.thumbnail(for: "w/1", mediaURL: video, duration: 2)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "w_1.jpg") // unsafe characters sanitized
        let firstDate = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // Concurrent requests for the same item share a single generation; a cached file is reused.
        async let a = service.thumbnail(for: "w/1", mediaURL: video, duration: 2)
        async let b = service.thumbnail(for: "w/1", mediaURL: video, duration: 2)
        let (ua, ub) = try await (a, b)
        #expect(ua == url && ub == url)
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == firstDate)

        let frame = try await service.posterFrame(for: "w/1", mediaURL: video, duration: 2)
        #expect(FileManager.default.fileExists(atPath: frame.path))
        #expect(service.cacheSize() > 0)

        await service.clearCache()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(service.cacheSize() == 0)
    }

    @Test func thumbnailFailsCleanlyForBrokenMedia() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("broken.mov")
        try Data(repeating: 1, count: 100).write(to: broken)
        let service = ThumbnailService(cacheDirectory: dir.appendingPathComponent("Cache"))
        await #expect(throws: (any Error).self) {
            try await service.thumbnail(for: "x", mediaURL: broken, duration: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: service.thumbnailURL(for: "x").path))
    }

    @Test func manyConcurrentThumbnailRequestsComplete() async throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await Fixtures.makeVideo(at: video)
        let service = ThumbnailService(cacheDirectory: dir.appendingPathComponent("Cache"), maxConcurrent: 2)
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 0..<12 { group.addTask { try await service.thumbnail(for: "item-\(i)", mediaURL: video, duration: 1) } }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(urls).count == 12)
    }

    @Test func resolverReportsAvailability() throws {
        let dir = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.mov")
        FileManager.default.createFile(atPath: file.path, contents: Data([0]))
        let resolver = MediaResolver(bundleResourcesURL: dir)
        #expect(resolver.resolve(Fixtures.wallpaper("x", mediaPath: "x.mov")).isAvailable)
        #expect(resolver.resolve(Fixtures.wallpaper("y", mediaPath: "y.mov")) == .missing)
        #expect(resolver.resolve(Fixtures.wallpaper("i", source: .imported, mediaPath: file.path)) == .available(file))
        #expect(resolver.resolve(Fixtures.wallpaper("j", source: .imported, mediaPath: "/nope/j.mov")) == .missing)
        #expect(MediaResolver(bundleResourcesURL: nil).resolve(Fixtures.wallpaper("x", mediaPath: "x.mov")) == .missing)
    }

    @Test func durationFormatting() {
        #expect(Wallpaper.formatDuration(0) == "—")
        #expect(Wallpaper.formatDuration(12.4) == "12s")
        #expect(Wallpaper.formatDuration(75) == "1:15")
        #expect(Wallpaper.formatDuration(.nan) == "—")
    }
}
