import AVFoundation
import CoreVideo
import Foundation
@testable import DriftwallCore

enum Fixtures {
    static func wallpaper(_ id: String, title: String? = nil, category: String = "Nature", tags: [String] = [],
                          summary: String = "", source: WallpaperSource = .bundled, width: Int = 1920, height: Int = 1080,
                          duration: TimeInterval = 10, importedAt: Date = Date(timeIntervalSince1970: 1_000),
                          featured: Bool = false, popularity: Int = 0, mediaPath: String? = nil) -> Wallpaper {
        Wallpaper(id: id, title: title ?? id.capitalized, summary: summary, category: category, tags: tags, source: source,
                  mediaPath: mediaPath ?? "Samples/\(id).mov", duration: duration, pixelWidth: width, pixelHeight: height,
                  importedAt: importedAt, isFeatured: featured, popularity: popularity)
    }

    static func memoryStore() throws -> SQLiteLibraryStore {
        try SQLiteLibraryStore(database: SQLiteDatabase(url: nil))
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("driftwall-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a short, real H.264 QuickTime movie so media tests exercise actual AVFoundation decoding.
    /// Each size is encoded once and later calls get a copy. Encoding awaits the writer instead of
    /// blocking a thread: tests run in parallel, and blocked threads left AVFoundation none to finish on.
    static func makeVideo(at url: URL, width: Int = 320, height: Int = 180, frames: Int = 30, fps: Int32 = 30) async throws {
        let template = try await VideoTemplates.shared.url(for: "\(width)x\(height)-\(frames)@\(fps)") {
            let template = try temporaryDirectory().appendingPathComponent("template-\(width)x\(height)-\(frames)@\(fps).mov")
            try await encodeVideo(at: template, width: width, height: height, frames: frames, fps: fps)
            return template
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: template, to: url)
    }

    private static func encodeVideo(at url: URL, width: Int, height: Int, frames: Int, fps: Int32) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixels = buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32(frame * 8 % 255), CVPixelBufferGetDataSize(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

/// Encodes each fixture video once, even when many tests ask for it at the same time.
private actor VideoTemplates {
    static let shared = VideoTemplates()
    private var templates: [String: Task<URL, Error>] = [:]

    func url(for key: String, make: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let existing = templates[key] { return try await existing.value }
        let task = Task { try await make() }
        templates[key] = task
        return try await task.value
    }
}

/// A sleeper for `RotationScheduler` that only returns when the test calls `tick()`.
actor ManualTicker {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private(set) var sleepCalls = 0

    func sleep() async throws {
        sleepCalls += 1
        try await withCheckedThrowingContinuation { waiters.append($0) }
        try Task.checkCancellation()
    }

    /// Wakes every pending sleeper. Returns how many were woken.
    @discardableResult
    func tick() -> Int {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        return pending.count
    }

    var pendingCount: Int { waiters.count }
}
