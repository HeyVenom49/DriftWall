import AVFoundation
import Foundation
import UniformTypeIdentifiers

public struct MediaMetadata: Equatable, Sendable {
    public var duration: TimeInterval
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var frameRate: Double
    public var codec: String?
    public var fileSize: Int64

    public init(duration: TimeInterval, pixelWidth: Int, pixelHeight: Int, frameRate: Double, codec: String?, fileSize: Int64) {
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameRate = frameRate
        self.codec = codec
        self.fileSize = fileSize
    }
}

public enum MediaValidationError: LocalizedError, Equatable {
    case unsupportedType(String)
    case fileNotFound(String)
    case notReadable(String)
    case noVideoTrack(String)
    case notPlayable(String)
    case invalidDuration(String)
    case alreadyImported(title: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "“\(name)” is not a supported video. Use a QuickTime (.mov), MPEG-4 (.mp4) or .m4v file."
        case .fileNotFound(let name):
            return "“\(name)” could not be found. It may have been moved or deleted."
        case .notReadable(let name):
            return "“\(name)” could not be read. Check that you have permission to open it."
        case .noVideoTrack(let name):
            return "“\(name)” does not contain a video track."
        case .notPlayable(let name):
            return "“\(name)” uses a format or codec this Mac cannot play."
        case .invalidDuration(let name):
            return "“\(name)” has no playable duration."
        case .alreadyImported(let title):
            return "This video is already in your library as “\(title)”."
        }
    }
}

/// Reads and validates video metadata using AVFoundation. Never loads more than the asset header.
public struct MediaInspector: Sendable {
    public static let supportedExtensions: Set<String> = ["mov", "mp4", "m4v"]
    public static let supportedTypes: [UTType] = [.quickTimeMovie, .mpeg4Movie, UTType("com.apple.m4v-video") ?? .movie]

    public init() {}

    /// Cheap pre-check before any AVFoundation work: extension / UTType and file presence.
    public func preflight(_ url: URL) throws {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let isMovie = type.map { $0.conforms(to: .movie) } ?? false
        guard Self.supportedExtensions.contains(ext), isMovie else { throw MediaValidationError.unsupportedType(name) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MediaValidationError.fileNotFound(name)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaValidationError.notReadable(name) }
    }

    public func inspect(_ url: URL) async throws -> MediaMetadata {
        try preflight(url)
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let (isPlayable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
        guard let track = tracks.first(where: { $0.mediaType == .video }) else { throw MediaValidationError.noVideoTrack(name) }
        guard isPlayable else { throw MediaValidationError.notPlayable(name) }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw MediaValidationError.invalidDuration(name) }

        let (naturalSize, transform, frameRate, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let oriented = naturalSize.applying(transform)
        let codec = formats.first.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        return MediaMetadata(
            duration: seconds,
            pixelWidth: Int(abs(oriented.width).rounded()),
            pixelHeight: Int(abs(oriented.height).rounded()),
            frameRate: Double(frameRate),
            codec: codec,
            fileSize: size
        )
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch text {
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": return "ProRes"
        case "": return "Unknown"
        default: return text
        }
    }
}
