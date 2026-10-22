import AVFoundation
import Foundation
import Observation
import VideoToolbox

/// Converts a wallpaper video into the format of Apple's Aerial files.
public protocol AerialVideoConverter: Sendable {
    func convert(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Real converter: repeats the clip until it is at least `minimumDuration` long (Aerials are long
/// videos; a 12-second loop would otherwise end mid-lock), scales it to fill 3840×2160 like Apple's
/// files, and encodes HEVC with VideoToolbox.
///
/// The encoder is driven directly, rather than through an export preset, to get a **closed GOP**:
/// every keyframe is an IDR frame and no frame depends on frames before it. Export presets produce an
/// open GOP (CRA keyframes followed by RASL frames, which reference the previous GOP). macOS's Aerial
/// player restarts reading at keyframes when it ramps the video up or down around lock and unlock; with
/// an open GOP it then logged `VideoSampleReadingErrors` and the affected screens stayed black. Apple's
/// own Aerials have closed GOPs (checked on macOS 27.0.1). 8-bit HEVC at the source's frame rate and a
/// 600 track timescale are kept from the export preset, which macOS plays.
///
/// Every frame is also tagged with HEVC temporal-layer information (all frames are layer 0, and every
/// frame allows switching layers), which the movie writer stores as `tscl`, `tsas` and `stsa` sample
/// groups. Apple's Aerials carry these groups. Without them the player still logged read errors when it
/// began slowing the video down on unlock.
public struct AVAerialVideoConverter: AerialVideoConverter {
    public var minimumDuration: Double
    /// Output frame size. Apple's Aerial files are 3840×2160; the video is explicitly scaled (aspect
    /// fill, centered) to exactly this size.
    public var renderSize: CGSize
    public var averageBitRate: Int
    /// How long any step may wait for the encoder or the movie writer before the attempt counts as
    /// stalled. A stalled attempt is retried once from scratch.
    var stallTimeout: TimeInterval = 20
    /// Tests only: in this many attempts, encoder output is dropped to simulate a stalled encoder.
    var simulatedStalls = 0

    public init(minimumDuration: Double = 120, renderSize: CGSize = CGSize(width: 3840, height: 2160),
                averageBitRate: Int = 30_000_000) {
        self.minimumDuration = minimumDuration
        self.renderSize = renderSize
        self.averageBitRate = averageBitRate
    }

    public func convert(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // VideoToolbox's encoder runs in a separate service and very occasionally stops delivering
        // frames. Every wait is bounded; a stalled attempt is retried once with everything rebuilt.
        for attempt in 1...2 {
            do {
                try await convertOnce(source, to: destination, dropsOutput: attempt <= simulatedStalls, progress: progress)
                return
            } catch is EncoderStalled {
                try? FileManager.default.removeItem(at: destination)
                if attempt == 2 {
                    throw AerialError.conversionFailed("the video encoder stopped responding. Try again; restarting the Mac helps if it keeps happening.")
                }
                DiagnosticsLog.shared.log(.warning, "aerial", "The video encoder stalled; retrying the conversion")
            }
        }
    }

    private func convertOnce(_ source: URL, to destination: URL, dropsOutput: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
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
        let (naturalSize, preferredTransform, nominalFrameRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let range = CMTimeRange(start: .zero, duration: duration)
        let repeats = max(1, Int((minimumDuration / seconds).rounded(.up)))
        var cursor = CMTime.zero
        for _ in 0..<repeats {
            try track.insertTimeRange(range, of: videoTrack, at: cursor)
            cursor = cursor + duration
        }
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.videoComposition = Self.scalingComposition(track: track, naturalSize: naturalSize, transform: preferredTransform,
                                                          duration: cursor, renderSize: renderSize, frameRate: frameRate)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AerialError.conversionFailed("the video can’t be read for conversion.") }
        reader.add(output)

        let encoder = ClosedGOPEncoder(reader: reader, output: output, destination: destination, size: renderSize,
                                       frameRate: frameRate, averageBitRate: averageBitRate, total: cursor.seconds,
                                       stallTimeout: stallTimeout, dropsOutput: dropsOutput, progress: progress)
        try await withTaskCancellationHandler {
            try await encoder.run()
        } onCancel: {
            encoder.cancel()
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
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        composition.instructions = [instruction]
        return composition
    }
}

/// The encoder or the movie writer made no progress within the stall timeout.
struct EncoderStalled: Error {}

/// Reads frames, encodes them with a VideoToolbox HEVC session (closed GOP) and writes the encoded
/// samples unchanged into a QuickTime movie. Runs on its own dispatch queue: it blocks while the
/// encoder or the writer catch up, which must not happen on Swift's shared concurrency threads.
/// Every such wait is bounded by `stallTimeout` and ends the attempt with `EncoderStalled`.
private final class ClosedGOPEncoder: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderOutput
    let destination: URL
    let size: CGSize
    let frameRate: Float
    let averageBitRate: Int
    let total: Double
    let stallTimeout: TimeInterval
    let dropsOutput: Bool
    let progress: @Sendable (Double) -> Void

    private let queue = DispatchQueue(label: "local.driftwall.aerial-conversion")
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var temporalLevel: [CFString: Any]?
    private var failure: Error?
    private var cancelled = false

    init(reader: AVAssetReader, output: AVAssetReaderOutput, destination: URL, size: CGSize, frameRate: Float,
         averageBitRate: Int, total: Double, stallTimeout: TimeInterval, dropsOutput: Bool,
         progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader
        self.output = output
        self.destination = destination
        self.size = size
        self.frameRate = frameRate
        self.averageBitRate = averageBitRate
        self.total = total
        self.stallTimeout = stallTimeout
        self.dropsOutput = dropsOutput
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try encodeAll()
                    done.resume()
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    done.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    private func fail(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    private func encodeAll() throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            throw AerialError.conversionFailed("this Mac can’t encode HEVC at that size (\(status)).")
        }
        defer { VTCompressionSessionInvalidate(session) }
        let properties: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: averageBitRate as CFNumber,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate as CFNumber,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2 as CFNumber,
            kVTCompressionPropertyKey_AllowOpenGOP: kCFBooleanFalse,
            kVTCompressionPropertyKey_RealTime: kCFBooleanFalse,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value)
            // A closed GOP is the point of this encoder; the rest are preferences.
            if result != noErr, key == kVTCompressionPropertyKey_AllowOpenGOP {
                throw AerialError.conversionFailed("the encoder can’t produce a closed GOP (\(result)).")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        guard reader.startReading() else {
            throw AerialError.conversionFailed(reader.error?.localizedDescription ?? "reading failed.")
        }
        // Bounds memory: 4K frames are 12 MB each. Created empty and filled, because libdispatch traps
        // when a semaphore is released below its initial value, which a stalled attempt leaves it at.
        let inFlight = DispatchSemaphore(value: 0)
        for _ in 0..<8 { inFlight.signal() }
        var lastReported = -1.0
        while let sample = output.copyNextSampleBuffer() {
            if lock.withLock({ cancelled || failure != nil }) { break }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard inFlight.wait(timeout: .now() + stallTimeout) == .success else {
                fail(EncoderStalled())
                break
            }
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time,
                                                         duration: CMSampleBufferGetDuration(sample), frameProperties: nil,
                                                         infoFlagsOut: nil) { [self] status, _, encoded in
                if dropsOutput { return }
                defer { inFlight.signal() }
                if status != noErr { fail(AerialError.conversionFailed("encoding failed (\(status)).")); return }
                if let encoded { write(encoded) }
            }
            if result != noErr { inFlight.signal(); fail(AerialError.conversionFailed("encoding failed (\(result)).")) }
            if time.seconds - lastReported >= 0.5 {
                lastReported = time.seconds
                progress(min(0.99, time.seconds / total))
            }
        }
        if !(lock.withLock { failure is EncoderStalled }) {
            // Waits for every frame still inside the encoder, so it is bounded as well.
            let flushed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                flushed.signal()
            }
            if flushed.wait(timeout: .now() + stallTimeout) == .timedOut { fail(EncoderStalled()) }
        }

        if lock.withLock({ cancelled }) {
            reader.cancelReading()
            writer?.cancelWriting()
            throw AerialError.conversionFailed("cancelled.")
        }
        if reader.status == .failed { fail(AerialError.conversionFailed(reader.error?.localizedDescription ?? "reading failed.")) }
        if let failure = lock.withLock({ failure }) {
            writer?.cancelWriting()
            throw failure
        }
        guard let writer, let input else { throw AerialError.conversionFailed("no frames were encoded.") }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + max(60, stallTimeout)) == .success else {
            writer.cancelWriting()
            throw EncoderStalled()
        }
        guard writer.status == .completed else {
            throw AerialError.conversionFailed(writer.error?.localizedDescription ?? "writing ended with status \(writer.status.rawValue).")
        }
    }

    /// Marks the sample as temporal layer 0 with (stepwise) temporal sub-layer access. The encoder only
    /// produces layer 0, so this describes the stream truthfully; the profile fields come from its hvcC.
    private func tagTemporalLayer(_ sample: CMSampleBuffer) {
        if temporalLevel == nil {
            var level: [CFString: Any] = [kCMHEVCTemporalLevelInfoKey_TemporalLevel: 0]
            if let format = CMSampleBufferGetFormatDescription(sample),
               let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
               let hvcC = atoms["hvcC"] as? Data, hvcC.count >= 13 {
                let bytes = [UInt8](hvcC)
                level[kCMHEVCTemporalLevelInfoKey_ProfileSpace] = Int(bytes[1] >> 6)
                level[kCMHEVCTemporalLevelInfoKey_TierFlag] = Int((bytes[1] >> 5) & 1)
                level[kCMHEVCTemporalLevelInfoKey_ProfileIndex] = Int(bytes[1] & 0x1F)
                level[kCMHEVCTemporalLevelInfoKey_ProfileCompatibilityFlags] = Data(bytes[2..<6])
                level[kCMHEVCTemporalLevelInfoKey_ConstraintIndicatorFlags] = Data(bytes[6..<12])
                level[kCMHEVCTemporalLevelInfoKey_LevelIndex] = Int(bytes[12])
            }
            temporalLevel = level
        }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
              let first = attachments.first else { return }
        first[kCMSampleAttachmentKey_HEVCTemporalLevelInfo] = temporalLevel
        first[kCMSampleAttachmentKey_HEVCTemporalSubLayerAccess] = true
        first[kCMSampleAttachmentKey_HEVCStepwiseTemporalSubLayerAccess] = true
    }

    /// Called by VideoToolbox in decode order. The writer is created with the first sample's format.
    private func write(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            if writer == nil {
                try? FileManager.default.removeItem(at: destination)
                let newWriter = try AVAssetWriter(outputURL: destination, fileType: .mov)
                newWriter.movieTimeScale = 600
                let newInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                                  sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
                newInput.expectsMediaDataInRealTime = false
                newInput.mediaTimeScale = 600
                guard newWriter.canAdd(newInput) else { throw AerialError.conversionFailed("the movie can’t be written.") }
                newWriter.add(newInput)
                guard newWriter.startWriting() else {
                    throw AerialError.conversionFailed(newWriter.error?.localizedDescription ?? "writing failed.")
                }
                newWriter.startSession(atSourceTime: .zero)
                writer = newWriter
                input = newInput
            }
            guard let writer, let input else { return }
            tagTemporalLayer(sample)
            let deadline = Date().addingTimeInterval(stallTimeout)
            while !input.isReadyForMoreMediaData, writer.status == .writing {
                if Date() > deadline { throw EncoderStalled() }
                usleep(500)
            }
            if !input.append(sample) {
                throw AerialError.conversionFailed(writer.error?.localizedDescription ?? "writing failed.")
            }
        } catch {
            if failure == nil { failure = error }
        }
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
        guard !isBusy else { throw AerialError.busy }
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
            try await restoreOriginal()
        }
        let backup = backupDirectory.appendingPathComponent("\(current.id).mov")
        let originalSize: Int64
        phase = "Checking Apple’s original video…"
        progress = nil
        if let existing = manifest, existing.slotID == current.id {
            // Replacing the video again: the backup made the first time is still the original.
            originalSize = await verifiedBackupSize(for: existing) ?? existing.originalSize
        } else {
            // Never back up a file that isn't Apple's original (for example one changed by hand or by an
            // earlier version): a restore would then put the wrong video back. Use a verified copy instead.
            var original = current.fileURL
            if let expected = AerialChecksum.recordedETag(of: current.fileURL) {
                guard let verified = await firstMatching([current.fileURL] + originalCopies(of: current.id), expectedETag: expected) else {
                    throw AerialError.originalModified(current.name)
                }
                original = verified
            }
            phase = "Backing up Apple’s original video…"
            originalSize = Self.size(of: original) ?? current.fileSize
            try backUp(original, to: backup, expectedSize: originalSize)
        }

        // 3. Replace the file, then keep the converted copy and record the install. The Aerial's previous
        //    contents are kept until all of that succeeded, so a failure at any step puts them back and
        //    the Aerial never disagrees with Driftwall's record.
        phase = "Replacing the Aerial video…"
        let rollback = try snapshot(current.fileURL)
        defer { try? fm.removeItem(at: rollback) }
        try await replace(current.fileURL, with: stagingURL, expectedSize: stagedSize, rollback: rollback)
        let manifest = AerialInstallManifest(slotID: current.id, slotName: current.name, wallpaperID: wallpaper.id,
                                             wallpaperTitle: wallpaper.title, originalSize: originalSize,
                                             installedSize: stagedSize, backupPath: backup.path, installedAt: Date(),
                                             followsWallpaper: followsWallpaper)
        do {
            _ = try? fm.removeItem(at: installedCopyURL)
            try fm.moveItem(at: stagingURL, to: installedCopyURL)
            try write(manifest)
        } catch {
            await putBack(rollback, into: current.fileURL)
            throw AerialError.writeFailed("Driftwall couldn’t record the install, so the Aerial was put back: \(error.localizedDescription)")
        }
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
        guard let backup = backupURL(for: manifest) else { throw AerialError.unsafePath(manifest.backupPath) }
        phase = "Re-applying your video to the Aerial…"
        defer { phase = nil }
        let isOriginal = await Task.detached(priority: .utility) { AerialChecksum.isAppleOriginal(destination) }.value
        if isOriginal != false {
            try backUp(destination, to: backup, expectedSize: currentSize)
            manifest.originalSize = currentSize
            try write(manifest)
        } else {
            log.log(.warning, "aerial", "“\(manifest.slotName)” changed but isn’t Apple’s original; keeping the existing backup")
        }
        let rollback = try snapshot(destination)
        defer { try? FileManager.default.removeItem(at: rollback) }
        try await replace(destination, with: installedCopyURL, expectedSize: manifest.installedSize, rollback: rollback)
        reloader.reload()
        log.log(.info, "aerial", "macOS restored Apple’s “\(manifest.slotName)”; re-applied “\(manifest.wallpaperTitle)”")
        refresh()
        return true
    }

    /// Puts Apple's original video back. Uses the backup when it is verifiably Apple's original, or
    /// another verified copy of the same Aerial if the backup isn't (or is missing).
    public func restore() async throws {
        guard !isBusy else { throw AerialError.busy }
        try await restoreOriginal()
    }

    /// The restore itself; also used by `install` when switching Aerials (while it is busy).
    private func restoreOriginal() async throws {
        guard let manifest else { throw AerialError.nothingToRestore }
        guard let backup = backupURL(for: manifest) else { throw AerialError.unsafePath(manifest.backupPath) }
        let destination = reader.videoDirectory.appendingPathComponent("\(manifest.slotID).mov")
        try AerialCatalogReader.validate(destination: destination, videoDirectory: reader.videoDirectory)
        phase = "Restoring Apple’s original video…"
        defer { phase = nil }
        var source: URL? = Self.size(of: backup) == manifest.originalSize ? backup : nil
        if let expected = AerialChecksum.recordedETag(of: destination) {
            source = await firstMatching([backup] + originalCopies(of: manifest.slotID), expectedETag: expected)
        }
        guard let source, let sourceSize = Self.size(of: source) else { throw AerialError.backupMissing }
        let rollback = try snapshot(destination)
        defer { try? FileManager.default.removeItem(at: rollback) }
        try await replace(destination, with: source, expectedSize: sourceSize, rollback: rollback)
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.removeItem(at: installedCopyURL)
        try? FileManager.default.removeItem(at: manifestURL)
        reloader.reload()
        log.log(.info, "aerial", "Restored Apple’s original Aerial “\(manifest.slotName)”")
        refresh()
    }

    /// Last resort when no copy of Apple's original is left on the Mac: removes Driftwall's video and
    /// its record so macOS downloads the Aerial again.
    public func removeAndRedownload() throws {
        guard let manifest else { throw AerialError.nothingToRestore }
        let destination = reader.videoDirectory.appendingPathComponent("\(manifest.slotID).mov")
        try AerialCatalogReader.validate(destination: destination, videoDirectory: reader.videoDirectory)
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        } catch {
            throw AerialError.writeFailed(error.localizedDescription)
        }
        if let backup = backupURL(for: manifest) { try? FileManager.default.removeItem(at: backup) }
        try? FileManager.default.removeItem(at: installedCopyURL)
        try? FileManager.default.removeItem(at: manifestURL)
        reloader.reload()
        log.log(.info, "aerial", "Removed “\(manifest.slotName)” so macOS downloads Apple’s original again")
        refresh()
    }

    /// When macOS already put its own file back, Driftwall's record and backup are no longer needed.
    public func forgetReplacedInstall() {
        guard case .replacedByMacOS(let manifest) = status else { return }
        if let backup = backupURL(for: manifest) { try? FileManager.default.removeItem(at: backup) }
        try? FileManager.default.removeItem(at: installedCopyURL)
        try? FileManager.default.removeItem(at: manifestURL)
        refresh()
    }

    // MARK: - Apple's originals

    /// Copies of the Aerial elsewhere on the Mac (the screen saver's store), to recover Apple's original.
    func originalCopies(of id: String) -> [URL] {
        reader.originalCopyDirectories.map { $0.appendingPathComponent("\(id).mov") }
    }

    /// The first existing file whose contents match `expectedETag`. Hashing runs off the main actor.
    func firstMatching(_ candidates: [URL], expectedETag: String) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            candidates.first { FileManager.default.fileExists(atPath: $0.path) && AerialChecksum.matches($0, expectedETag: expectedETag) }
        }.value
    }

    /// Makes sure the backup of an installed Aerial is Apple's original, replacing it with a verified
    /// copy if it isn't. Returns the original's size, or nil when it can't be checked or fixed.
    private func verifiedBackupSize(for manifest: AerialInstallManifest) async -> Int64? {
        let file = reader.videoDirectory.appendingPathComponent("\(manifest.slotID).mov")
        guard let backup = backupURL(for: manifest),
              let expected = AerialChecksum.recordedETag(of: file) else { return nil }
        if await firstMatching([backup], expectedETag: expected) != nil { return Self.size(of: backup) }
        guard let copy = await firstMatching(originalCopies(of: manifest.slotID), expectedETag: expected),
              let size = Self.size(of: copy), (try? backUp(copy, to: backup, expectedSize: size)) != nil else {
            log.log(.warning, "aerial", "The backup of “\(manifest.slotName)” isn’t Apple’s original and no original copy was found")
            return nil
        }
        log.log(.info, "aerial", "Replaced the backup of “\(manifest.slotName)” with a verified original")
        return size
    }

    /// Downloaded Aerials whose video is no longer what macOS downloaded, apart from the one Driftwall
    /// replaced on purpose. Aerials without a recorded ETag can't be checked and aren't listed.
    public func findModifiedAerials() async -> [AerialSlot] {
        refresh()
        let managed = manifest?.slotID
        let candidates = slots.filter { $0.id != managed }
        return await Task.detached(priority: .utility) {
            candidates.filter { AerialChecksum.isAppleOriginal($0.fileURL) == false }
        }.value
    }

    public enum RepairResult: Equatable, Sendable {
        /// Apple's original was found elsewhere on the Mac and written back.
        case restoredFromCopy
        /// No original was on the Mac: the changed file was removed so macOS downloads it again.
        case willRedownload
    }

    /// Puts Apple's original back into an Aerial that was changed outside Driftwall: from a verified
    /// copy when there is one, otherwise by removing the file so macOS downloads it again (macOS keeps
    /// these files in the user's own Library and fetches a missing Aerial when it's needed).
    public func repairModifiedAerial(_ slot: AerialSlot) async throws -> RepairResult {
        guard slot.id != manifest?.slotID else { throw AerialError.invalidSlot } // use restore() for that one
        guard !isBusy else { throw AerialError.busy }
        try AerialCatalogReader.validate(destination: slot.fileURL, videoDirectory: reader.videoDirectory)
        phase = "Repairing “\(slot.name)”…"
        defer { phase = nil }
        let result: RepairResult
        if let expected = AerialChecksum.recordedETag(of: slot.fileURL),
           let copy = await firstMatching(originalCopies(of: slot.id), expectedETag: expected),
           let size = Self.size(of: copy) {
            let rollback = try snapshot(slot.fileURL)
            defer { try? FileManager.default.removeItem(at: rollback) }
            try await replace(slot.fileURL, with: copy, expectedSize: size, rollback: rollback)
            result = .restoredFromCopy
        } else {
            do {
                try FileManager.default.removeItem(at: slot.fileURL)
            } catch {
                throw AerialError.writeFailed(error.localizedDescription)
            }
            result = .willRedownload
        }
        reloader.reload()
        log.log(.info, "aerial", "Repaired Aerial “\(slot.name)” (\(result == .restoredFromCopy ? "original copy written back" : "removed so macOS downloads it again"))")
        refresh()
        return result
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

    /// Writes `source` over `destination` and checks the size. The write happens in place (see
    /// `overwriteInPlace`), so it truncates first; if it fails, `rollback` (a snapshot of the previous
    /// contents) is written back, so the Aerial is never left empty or half-written.
    /// The copy runs off the main actor: Aerial videos are hundreds of megabytes.
    private func replace(_ destination: URL, with source: URL, expectedSize: Int64, rollback: URL) async throws {
        do {
            try await Task.detached(priority: .userInitiated) { try Self.overwriteInPlace(destination, with: source) }.value
            guard Self.size(of: destination) == expectedSize else {
                throw AerialError.verificationFailed("the Aerial file doesn’t match the video that was written.")
            }
        } catch {
            await putBack(rollback, into: destination)
            if let error = error as? AerialError { throw error }
            throw AerialError.writeFailed(error.localizedDescription)
        }
    }

    /// A copy of the file's current contents to roll back to. On APFS this is a clone: instant, and it
    /// takes no extra space until one of the two changes.
    private func snapshot(_ file: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let copy = workDirectory.appendingPathComponent("rollback-\(UUID().uuidString).mov")
        do {
            try fm.copyItem(at: file, to: copy)
        } catch {
            throw AerialError.writeFailed("the Aerial’s current video couldn’t be kept for a rollback, so nothing was changed: \(error.localizedDescription)")
        }
        return copy
    }

    /// Writes a snapshot back after a failed change. If even that fails, the file is left for macOS to
    /// replace (it downloads an unreadable Aerial again) and the failure is logged.
    private func putBack(_ rollback: URL, into destination: URL) async {
        let restored = await Task.detached(priority: .userInitiated) { () -> Bool in
            (try? Self.overwriteInPlace(destination, with: rollback)) != nil
        }.value
        if restored {
            log.log(.warning, "aerial", "A change to \(destination.lastPathComponent) failed; its previous video was put back")
        } else {
            log.log(.error, "aerial", "A change to \(destination.lastPathComponent) failed and its previous video couldn’t be put back")
        }
    }

    /// The manifest's backup path, only if it is exactly `<backupDirectory>/<slotID>.mov`. A damaged or
    /// edited manifest can never make Driftwall read, overwrite or delete a file anywhere else.
    func backupURL(for manifest: AerialInstallManifest) -> URL? {
        let expected = backupDirectory.appendingPathComponent("\(manifest.slotID).mov").standardizedFileURL
        let recorded = URL(fileURLWithPath: manifest.backupPath).standardizedFileURL
        guard AerialCatalogReader.isValidAssetID(manifest.slotID), recorded.path == expected.path else {
            log.log(.error, "aerial", "Ignoring an unexpected backup path in the Aerial record: \(manifest.backupPath)")
            return nil
        }
        return expected
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
