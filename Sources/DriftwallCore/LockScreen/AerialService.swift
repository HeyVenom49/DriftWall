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

/// Runs one shell command as an administrator (asks the user for their password).
public protocol PrivilegedRunner: Sendable {
    func runAsAdministrator(_ shellCommand: String) async throws
}

/// "Advanced" lock screen: replaces one downloaded Apple Aerial video with the user's wallpaper so that
/// macOS itself animates it on the lock screen. Every change is backed up first and can be restored.
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
    @ObservationIgnored private let runner: PrivilegedRunner
    @ObservationIgnored private let log: DiagnosticsLog

    public var manifestURL: URL { workDirectory.appendingPathComponent("manifest.json") }
    public var backupDirectory: URL { workDirectory.appendingPathComponent("Backup", isDirectory: true) }
    var stagingURL: URL { workDirectory.appendingPathComponent("staged.mov") }

    public init(reader: AerialCatalogReader, workDirectory: URL, converter: AerialVideoConverter, runner: PrivilegedRunner, log: DiagnosticsLog = .shared) {
        self.reader = reader
        self.workDirectory = workDirectory
        self.converter = converter
        self.runner = runner
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
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        status = size == manifest.installedSize ? .installed(manifest) : .replacedByMacOS(manifest)
    }

    /// Converts, backs up, then swaps the Aerial file with one administrator prompt.
    public func install(wallpaper: Wallpaper, mediaURL: URL, slot: AerialSlot) async throws {
        guard !isBusy else { return }
        defer { phase = nil; progress = nil }
        refresh()
        guard let current = slots.first(where: { $0.id == slot.id }) else { throw AerialError.invalidSlot }
        try AerialCommandBuilder.validate(destination: current.fileURL, videoDirectory: reader.videoDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        // 1. Convert (as the user).
        phase = "Converting video to Apple’s Aerial format…"
        progress = 0
        try await converter.convert(mediaURL, to: stagingURL) { value in
            Task { @MainActor in self.progress = value }
        }
        let converted = try await MediaInspector().inspect(stagingURL)
        guard converted.codec == "HEVC" else { throw AerialError.conversionFailed("the result is not HEVC.") }
        let stagedSize = Self.size(of: stagingURL) ?? -1

        // 2. Back up Apple's original (as the user; Aerial files are world-readable). If a different slot
        //    was replaced earlier, that one is restored first so only one Aerial is ever modified.
        if let previous = manifest, previous.slotID != current.id {
            try await restore()
        }
        let backup = backupDirectory.appendingPathComponent("\(current.id).mov")
        let existingManifest = manifest
        if existingManifest?.slotID != current.id {
            phase = "Backing up Apple’s original video…"
            progress = nil
            do {
                _ = try? fm.removeItem(at: backup)
                try fm.copyItem(at: current.fileURL, to: backup)
            } catch {
                throw AerialError.backupFailed(error.localizedDescription)
            }
            guard Self.size(of: backup) == current.fileSize else {
                try? fm.removeItem(at: backup)
                throw AerialError.backupFailed("the backup copy is incomplete.")
            }
        }
        let originalSize = existingManifest?.slotID == current.id ? (existingManifest?.originalSize ?? current.fileSize) : current.fileSize

        // 3. Swap the file (administrator).
        phase = "Waiting for your administrator password…"
        let command = try AerialCommandBuilder.installCommand(source: stagingURL, destination: current.fileURL, videoDirectory: reader.videoDirectory)
        try await runner.runAsAdministrator(command)

        // 4. Verify and record.
        guard Self.size(of: current.fileURL) == stagedSize else {
            throw AerialError.verificationFailed("the Aerial file doesn’t match the converted video.")
        }
        let manifest = AerialInstallManifest(slotID: current.id, slotName: current.name, wallpaperID: wallpaper.id,
                                             wallpaperTitle: wallpaper.title, originalSize: originalSize,
                                             installedSize: stagedSize, backupPath: backup.path, installedAt: Date())
        try write(manifest)
        try? fm.removeItem(at: stagingURL)
        log.log(.info, "aerial", "Replaced Aerial “\(current.name)” with “\(wallpaper.title)” (backup at \(backup.path))")
        refresh()
    }

    /// Puts Apple's original video back from the backup (one administrator prompt).
    public func restore() async throws {
        guard let manifest else { throw AerialError.nothingToRestore }
        let backup = URL(fileURLWithPath: manifest.backupPath)
        guard Self.size(of: backup) == manifest.originalSize else { throw AerialError.backupMissing }
        let destination = reader.videoDirectory.appendingPathComponent("\(manifest.slotID).mov")
        phase = "Restoring Apple’s original video…"
        defer { phase = nil }
        let command = try AerialCommandBuilder.installCommand(source: backup, destination: destination, videoDirectory: reader.videoDirectory)
        try await runner.runAsAdministrator(command)
        guard Self.size(of: destination) == manifest.originalSize else {
            throw AerialError.verificationFailed("the restored file doesn’t match the backup.")
        }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.removeItem(at: manifestURL)
        log.log(.info, "aerial", "Restored Apple’s original Aerial “\(manifest.slotName)”")
        refresh()
    }

    /// When macOS already put its own file back, Driftwall's record and backup are no longer needed.
    public func forgetReplacedInstall() {
        guard case .replacedByMacOS(let manifest) = status else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: manifest.backupPath))
        try? FileManager.default.removeItem(at: manifestURL)
        refresh()
    }

    private func write(_ manifest: AerialInstallManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
