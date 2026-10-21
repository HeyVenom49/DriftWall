import AVFoundation
import Foundation
import Observation

/// Converts a wallpaper video into the format of Apple's Aerial files.
public protocol AerialVideoConverter: Sendable {
    func convert(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Real converter: repeats the clip until it is at least `minimumDuration` long (Aerials are long
/// videos; a 12-second loop would otherwise end mid-lock), then exports HEVC at 3840×2160 like Apple's files.
public struct AVAerialVideoConverter: AerialVideoConverter {
    public var minimumDuration: Double
    public var presetName: String
    /// Output frame size. Apple's Aerial files are 3840×2160; export presets never upscale, so the
    /// video is explicitly scaled (aspect fill, centered) to exactly this size.
    public var renderSize: CGSize

    public init(minimumDuration: Double = 120, presetName: String = AVAssetExportPresetHEVC3840x2160,
                renderSize: CGSize = CGSize(width: 3840, height: 2160)) {
        self.minimumDuration = minimumDuration
        self.presetName = presetName
        self.renderSize = renderSize
    }

    public func convert(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw AerialError.conversionFailed("the file has no video track.")
        }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw AerialError.conversionFailed("the video has no duration.") }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AerialError.conversionFailed("could not create a composition.")
        }
        let (naturalSize, preferredTransform, frameRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let range = CMTimeRange(start: .zero, duration: duration)
        let repeats = max(1, Int((minimumDuration / seconds).rounded(.up)))
        var cursor = CMTime.zero
        for _ in 0..<repeats {
            try track.insertTimeRange(range, of: videoTrack, at: cursor)
            cursor = cursor + duration
        }

        try? FileManager.default.removeItem(at: destination)
        guard let export = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw AerialError.conversionFailed("this Mac can’t encode HEVC at that size.")
        }
        export.outputURL = destination
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = false
        export.videoComposition = Self.scalingComposition(track: track, naturalSize: naturalSize, transform: preferredTransform,
                                                          duration: cursor, renderSize: renderSize, frameRate: frameRate)

        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(export.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await export.export()
        ticker.cancel()
        guard export.status == .completed else {
            throw AerialError.conversionFailed(export.error?.localizedDescription ?? "export ended with status \(export.status.rawValue).")
        }
        progress(1)
    }

    /// Scales the (orientation-corrected) video to fill `renderSize`, cropping the overflow evenly.
    static func scalingComposition(track: AVCompositionTrack, naturalSize: CGSize, transform: CGAffineTransform,
                                   duration: CMTime, renderSize: CGSize, frameRate: Float) -> AVMutableVideoComposition {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let scale = max(renderSize.width / abs(oriented.width), renderSize.height / abs(oriented.height))
        let scaledWidth = abs(oriented.width) * scale, scaledHeight = abs(oriented.height) * scale
        let placement = transform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (renderSize.width - scaledWidth) / 2, y: (renderSize.height - scaledHeight) / 2))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(placement, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate > 0 ? frameRate.rounded() : 30))
        composition.instructions = [instruction]
        return composition
    }
}

/// Makes macOS's wallpaper processes load the Aerial video again (they keep the old one in memory).
public protocol AerialWallpaperReloader: Sendable {
    func reload()
}

/// "Advanced" lock screen: replaces one downloaded Apple Aerial video with the user's wallpaper so that
/// macOS itself animates it on the lock screen. The file is in the user's own Aerial store, so no
/// administrator password is needed. Every change is backed up first and can be restored.
@MainActor
@Observable
public final class AerialLockScreenService {
    public private(set) var slots: [AerialSlot] = []
    public private(set) var status: AerialStatus = .notInstalled
    public private(set) var progress: Double?
    public private(set) var phase: String?

    @ObservationIgnored public let reader: AerialCatalogReader
    @ObservationIgnored public let workDirectory: URL
    @ObservationIgnored private let converter: AerialVideoConverter
    @ObservationIgnored private let reloader: AerialWallpaperReloader
    @ObservationIgnored private let log: DiagnosticsLog

    public var manifestURL: URL { workDirectory.appendingPathComponent("manifest.json") }
    public var backupDirectory: URL { workDirectory.appendingPathComponent("Backup", isDirectory: true) }
    /// The converted video, kept so it can be put back without converting again when macOS
    /// re-downloads Apple's file.
    public var installedCopyURL: URL { workDirectory.appendingPathComponent("installed.mov") }
    var stagingURL: URL { workDirectory.appendingPathComponent("staged.mov") }

    public init(reader: AerialCatalogReader, workDirectory: URL, converter: AerialVideoConverter,
                reloader: AerialWallpaperReloader, log: DiagnosticsLog = .shared) {
        self.reader = reader
        self.workDirectory = workDirectory
        self.converter = converter
        self.reloader = reloader
        self.log = log
    }

    public var isBusy: Bool { phase != nil }

    public var manifest: AerialInstallManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AerialInstallManifest.self, from: data)
    }

    /// Re-reads the catalog and compares the Aerial file with what Driftwall installed.
    public func refresh() {
        do {
            slots = try reader.availableSlots()
        } catch {
            slots = []
            status = .unavailable(error.localizedDescription)
            return
        }
        guard let manifest else { status = .notInstalled; return }
        let file = reader.videoDirectory.appendingPathComponent("\(manifest.slotID).mov")
        status = Self.size(of: file) == manifest.installedSize ? .installed(manifest) : .replacedByMacOS(manifest)
    }

    /// Converts, backs up, then replaces the Aerial file and reloads the wallpaper.
    public func install(wallpaper: Wallpaper, mediaURL: URL, slot: AerialSlot, followsWallpaper: Bool = false) async throws {
        guard !isBusy else { return }
        defer { phase = nil; progress = nil }
        refresh()
        guard let current = slots.first(where: { $0.id == slot.id }) else { throw AerialError.invalidSlot }
        try AerialCatalogReader.validate(destination: current.fileURL, videoDirectory: reader.videoDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        // 1. Convert.
        phase = "Converting video to Apple’s Aerial format…"
        progress = 0
        try await converter.convert(mediaURL, to: stagingURL) { value in
            Task { @MainActor in self.progress = value }
        }
        let converted = try await MediaInspector().inspect(stagingURL)
        guard converted.codec == "HEVC" else { throw AerialError.conversionFailed("the result is not HEVC.") }
        let stagedSize = Self.size(of: stagingURL) ?? -1

        // 2. Back up Apple's original. If a different slot was replaced earlier, that one is restored
        //    first so only one Aerial is ever modified.
        if let previous = manifest, previous.slotID != current.id {
            try await restore()
        }
        let backup = backupDirectory.appendingPathComponent("\(current.id).mov")
        let existingManifest = manifest
        if existingManifest?.slotID != current.id {
            phase = "Backing up Apple’s original video…"
            progress = nil
            try backUp(current.fileURL, to: backup, expectedSize: current.fileSize)
        }
        let originalSize = existingManifest?.slotID == current.id ? (existingManifest?.originalSize ?? current.fileSize) : current.fileSize

        // 3. Replace the file and keep the converted copy for re-applying later.
        phase = "Replacing the Aerial video…"
        try await replace(current.fileURL, with: stagingURL, expectedSize: stagedSize, fallback: backup)
        _ = try? fm.removeItem(at: installedCopyURL)
        try fm.moveItem(at: stagingURL, to: installedCopyURL)

        // 4. Record and reload.
        let manifest = AerialInstallManifest(slotID: current.id, slotName: current.name, wallpaperID: wallpaper.id,
                                             wallpaperTitle: wallpaper.title, originalSize: originalSize,
                                             installedSize: stagedSize, backupPath: backup.path, installedAt: Date(),
                                             followsWallpaper: followsWallpaper)
        try write(manifest)
        reloader.reload()
        log.log(.info, "aerial", "Replaced Aerial “\(current.name)” with “\(wallpaper.title)” (backup at \(backup.path))")
        refresh()
    }

    /// When macOS has put its own file back (re-downloaded the Aerial), backs that file up as the new
    /// original and puts Driftwall's converted video back. Returns whether anything was re-applied.
    @discardableResult
    public func reapplyIfReplaced() async throws -> Bool {
        refresh()
        guard !isBusy, case .replacedByMacOS(var manifest) = status,
              Self.size(of: installedCopyURL) == manifest.installedSize else { return false }
        let destination = reader.videoDirectory.appendingPathComponent("\(manifest.slotID).mov")
        try AerialCatalogReader.validate(destination: destination, videoDirectory: reader.videoDirectory)
        // A missing file means macOS removed the download; a new file wouldn't carry its download
        // metadata, so wait until macOS downloads it again.
        guard let currentSize = Self.size(of: destination) else { return false }
        phase = "Re-applying your video to the Aerial…"
        defer { phase = nil }
        let backup = URL(fileURLWithPath: manifest.backupPath)
        try backUp(destination, to: backup, expectedSize: currentSize)
        manifest.originalSize = currentSize
        try write(manifest)
        try await replace(destination, with: installedCopyURL, expectedSize: manifest.installedSize, fallback: backup)
        reloader.reload()
        log.log(.info, "aerial", "macOS restored Apple’s “\(manifest.slotName)”; re-applied “\(manifest.wallpaperTitle)”")
        refresh()
        return true
    }

    /// Puts Apple's original video back from the backup.
    public func restore() async throws {
        guard let manifest else { throw AerialError.nothingToRestore }
        let backup = URL(fileURLWithPath: manifest.backupPath)
        guard Self.size(of: backup) == manifest.originalSize else { throw AerialError.backupMissing }
        let destination = reader.videoDirectory.appendingPathComponent("\(manifest.slotID).mov")
        try AerialCatalogReader.validate(destination: destination, videoDirectory: reader.videoDirectory)
        phase = "Restoring Apple’s original video…"
        defer { phase = nil }
        try await replace(destination, with: backup, expectedSize: manifest.originalSize, fallback: nil)
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.removeItem(at: installedCopyURL)
        try? FileManager.default.removeItem(at: manifestURL)
        reloader.reload()
        log.log(.info, "aerial", "Restored Apple’s original Aerial “\(manifest.slotName)”")
        refresh()
    }

    /// When macOS already put its own file back, Driftwall's record and backup are no longer needed.
    public func forgetReplacedInstall() {
        guard case .replacedByMacOS(let manifest) = status else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: manifest.backupPath))
        try? FileManager.default.removeItem(at: installedCopyURL)
        try? FileManager.default.removeItem(at: manifestURL)
        refresh()
    }

    private func backUp(_ file: URL, to backup: URL, expectedSize: Int64) throws {
        let fm = FileManager.default
        do {
            _ = try? fm.removeItem(at: backup)
            try fm.copyItem(at: file, to: backup)
        } catch {
            throw AerialError.backupFailed(error.localizedDescription)
        }
        guard Self.size(of: backup) == expectedSize else {
            try? fm.removeItem(at: backup)
            throw AerialError.backupFailed("the backup copy is incomplete.")
        }
    }

    /// Writes `source` over `destination` and checks the size. If that fails and a `fallback` is
    /// given, the fallback (Apple's original) is written back so the Aerial is never left half-written.
    /// The copy runs off the main actor: Aerial videos are hundreds of megabytes.
    private func replace(_ destination: URL, with source: URL, expectedSize: Int64, fallback: URL?) async throws {
        do {
            try await Task.detached(priority: .userInitiated) { try Self.overwriteInPlace(destination, with: source) }.value
            guard Self.size(of: destination) == expectedSize else {
                throw AerialError.verificationFailed("the Aerial file doesn’t match the video that was written.")
            }
        } catch {
            if let fallback {
                _ = await Task.detached(priority: .userInitiated) { try? Self.overwriteInPlace(destination, with: fallback) }.value
            }
            if let error = error as? AerialError { throw error }
            throw AerialError.writeFailed(error.localizedDescription)
        }
    }

    /// Rewrites the file's contents without replacing the file itself, so the download metadata macOS
    /// keeps on it (extended attributes such as the source URL and ETag) stays and macOS keeps treating
    /// it as its downloaded Aerial instead of downloading it again.
    nonisolated static func overwriteInPlace(_ destination: URL, with source: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    private func write(_ manifest: AerialInstallManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    nonisolated static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
