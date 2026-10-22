import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import DriftwallCore

extension Data {
    var md5: Data { Data(Insecure.MD5.hash(data: self)) }
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}

/// Counts reloads instead of restarting macOS's wallpaper processes.
final class CountingReloader: AerialWallpaperReloader, @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func reload() { lock.withLock { value += 1 } }
}

@Suite("Aerial catalog and path safety")
struct AerialSafetyTests {
    @Test func validAssetIDs() {
        #expect(AerialCatalogReader.isValidAssetID("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182"))
        #expect(!AerialCatalogReader.isValidAssetID("../../etc/passwd"))
        #expect(!AerialCatalogReader.isValidAssetID("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE15118"))
        #expect(!AerialCatalogReader.isValidAssetID("03EC0F5E CCA8 4E0A 9FEC 5BD1CE151182"))
    }

    @Test func destinationMustBeAnAerialFileInsideTheStore() throws {
        let dir = URL(fileURLWithPath: "/tmp/store/videos")
        let good = dir.appendingPathComponent("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.mov")
        try AerialCatalogReader.validate(destination: good, videoDirectory: dir)
        for bad in [
            dir.appendingPathComponent("../03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.mov"),
            dir.appendingPathComponent("notes.mov"),
            dir.appendingPathComponent("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.sh"),
            URL(fileURLWithPath: "/System/Library/03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.mov"),
        ] {
            #expect(throws: AerialError.self) { try AerialCatalogReader.validate(destination: bad, videoDirectory: dir) }
        }
    }

    @Test func catalogListsOnlyDownloadedValidAerials() async throws {
        let fixture = try await AerialFixture()
        let slots = try fixture.reader.availableSlots()
        #expect(slots.map(\.name) == ["Antarctica", "London"]) // sorted; missing file, invalid id and duplicate skipped
        #expect(slots.allSatisfy { $0.fileSize > 0 })
    }

    @Test func nothingDownloadedYetIsAnEmptyListNotAnError() throws {
        let reader = AerialCatalogReader(root: URL(fileURLWithPath: "/nonexistent-driftwall-test"))
        #expect(try reader.availableSlots().isEmpty)
    }

    @Test func downloadedAerialsAreListedWithoutTheWallpaperCatalog() async throws {
        let fixture = try await AerialFixture()
        try FileManager.default.removeItem(at: fixture.reader.catalogURL)
        // Names come from the screen saver's catalog when the wallpaper's own one is missing.
        let fallback = fixture.root.deletingLastPathComponent().appendingPathComponent("saver-entries.json")
        try JSONSerialization.data(withJSONObject: ["assets": [["id": AerialFixture.london, "accessibilityLabel": "London (saver)"]]]).write(to: fallback)
        let reader = AerialCatalogReader(root: fixture.root, fallbackCatalogURLs: [fallback])
        #expect(try reader.availableSlots().map(\.name) == ["Aerial 03EC0F5E", "London (saver)"])
    }

    @Test func skipsFilesThatAreNotAerialVideos() async throws {
        let fixture = try await AerialFixture()
        let videos = fixture.reader.videoDirectory
        try Data([1]).write(to: videos.appendingPathComponent("notes.mov"))
        try Data([1]).write(to: videos.appendingPathComponent("\(AerialFixture.london).mov.download"))
        try Data().write(to: videos.appendingPathComponent("A1B2C3D4-0000-0000-0000-000000000000.mov")) // empty
        try FileManager.default.createDirectory(at: videos.appendingPathComponent("F439B0A7-D18C-4B14-9681-6520E6A74FE9.mov"), withIntermediateDirectories: true)
        #expect(try fixture.reader.availableSlots().map(\.name) == ["Antarctica", "London"])
    }
}

@Suite("Aerial wallpaper selection")
struct AerialWallpaperStoreTests {
    let sunrise = "6D6834A4-2F0F-479A-B053-7D4DC5CB8EB7"
    let london = AerialFixture.london

    /// Shaped like macOS 27's Index.plist: choices per display, configuration as a nested plist.
    func index(desktopConfiguration: [String: Any], idleConfiguration: [String: Any]) throws -> Any {
        func choice(_ provider: String, _ configuration: [String: Any]) throws -> [String: Any] {
            ["Provider": provider,
             "Configuration": try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)]
        }
        return ["Displays": ["37D8832A-2D66-02CA-B9F7-8F30A301B230": [
            "Desktop": ["Content": ["Choices": [try choice("com.apple.wallpaper.choice.aerials", desktopConfiguration)]]],
            "Idle": ["Content": ["Choices": [try choice("com.apple.wallpaper.choice.screen-saver", idleConfiguration)]]],
        ]]]
    }

    @Test func findsTheAerialChosenAsDesktopWallpaper() throws {
        let root = try index(desktopConfiguration: ["assetID": sunrise], idleConfiguration: ["assetID": london])
        #expect(AerialWallpaperStore.selectedAssetIDs(inIndex: root, among: [sunrise, london]) == [sunrise]) // not the screen saver's
    }

    @Test func ignoresIDsThatAreNotKnownAerials() throws {
        // e.g. a Photos picture whose path contains a UUID
        let root = try index(desktopConfiguration: ["url": "file:///Photos/\(london)/Photos Desktop.jpg"], idleConfiguration: [:])
        #expect(AerialWallpaperStore.selectedAssetIDs(inIndex: root, among: [sunrise]).isEmpty)
    }

    @Test func reportsEachDisplaySeparately() throws {
        let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230", external = "653240F3-BB73-4DAB-A1F9-D0C13D00CFCF"
        let aerial = try PropertyListSerialization.data(fromPropertyList: ["assetID": sunrise], format: .binary, options: 0)
        let image = try PropertyListSerialization.data(fromPropertyList: ["type": "imageFile", "url": ["relative": "file:///a.png"]], format: .binary, options: 0)
        func desktop(_ configuration: Data, _ provider: String) -> [String: Any] {
            ["Desktop": ["Content": ["Choices": [["Provider": provider, "Configuration": configuration]]]]]
        }
        let perDisplay: [String: Any] = [
            "AllSpacesAndDisplays": ["Idle": ["Content": ["Choices": []]], "Type": "idle"],
            "Displays": [builtIn: desktop(aerial, "com.apple.wallpaper.choice.aerials"),
                         external: desktop(image, "com.apple.wallpaper.choice.image")],
        ]
        #expect(AerialWallpaperStore.displays(showing: sunrise, among: [builtIn, external], inIndex: perDisplay) == [builtIn])

        // A choice for all displays applies to displays without a choice of their own…
        let onlyEverywhere: [String: Any] = ["AllSpacesAndDisplays": desktop(aerial, "com.apple.wallpaper.choice.aerials")]
        #expect(AerialWallpaperStore.displays(showing: sunrise, among: [builtIn, external], inIndex: onlyEverywhere) == [builtIn, external])

        // …but never hides a display's own choice: a non-Aerial "everywhere" picture doesn't stop the
        // built-in display from counting, and its per-display image still wins over an Aerial everywhere.
        var imageEverywhere = perDisplay
        imageEverywhere["AllSpacesAndDisplays"] = desktop(image, "com.apple.wallpaper.choice.image")
        #expect(AerialWallpaperStore.displays(showing: sunrise, among: [builtIn, external], inIndex: imageEverywhere) == [builtIn])
        var aerialEverywhere = perDisplay
        aerialEverywhere["AllSpacesAndDisplays"] = desktop(aerial, "com.apple.wallpaper.choice.aerials")
        #expect(AerialWallpaperStore.displays(showing: sunrise, among: [builtIn, external], inIndex: aerialEverywhere) == [builtIn])
    }

    @Test func usesEachDisplaysCurrentSpace() throws {
        // macOS 27.0.1 with "Show on all Spaces" off: choosing the Aerial for the external display wrote
        // it for that display's current Space only, while its per-display entry kept the old picture.
        let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230", external = "653240F3-BB73-4DAB-A1F9-D0C13D00CFCF"
        let aerial = try PropertyListSerialization.data(fromPropertyList: ["assetID": sunrise], format: .binary, options: 0)
        let image = try PropertyListSerialization.data(fromPropertyList: ["type": "imageFile"], format: .binary, options: 0)
        func desktop(_ configuration: Data) -> [String: Any] {
            ["Desktop": ["Content": ["Choices": [["Provider": "p", "Configuration": configuration]]]]]
        }
        let index: [String: Any] = [
            "AllSpacesAndDisplays": ["Type": "idle"],
            "Displays": [builtIn: desktop(aerial), external: desktop(image)],
            "Spaces": [
                "F41C5FE9-EF1A-3BCA-00A2-93DCA82C5232": ["Displays": [external: desktop(aerial)], "Default": desktop(aerial)],
                "OTHER-SPACE": ["Displays": [external: desktop(image)]],
                "": ["Default": desktop(image)],
            ],
        ]
        let spacesPreferences: [String: Any] = ["Management Data": ["Monitors": [
            ["Display Identifier": "Main", "Current Space": ["uuid": "", "ManagedSpaceID": 3]],
            ["Display Identifier": external, "Current Space": ["uuid": "F41C5FE9-EF1A-3BCA-00A2-93DCA82C5232", "ManagedSpaceID": 1527]],
            ["Display Identifier": "4973ED72-2C19-4E22-9229-ADC076355670"], // disconnected: no current Space
        ]]]
        let current = AerialWallpaperStore.currentSpaces(inSpacesPreferences: spacesPreferences, mainDisplayID: builtIn)
        #expect(current == [builtIn: "", external: "F41C5FE9-EF1A-3BCA-00A2-93DCA82C5232"])
        #expect(AerialWallpaperStore.displays(showing: sunrise, among: [builtIn, external], currentSpaces: current, inIndex: index) == [builtIn, external])

        // On another Space the external display shows its picture again.
        let elsewhere = [builtIn: "", external: "OTHER-SPACE"]
        #expect(AerialWallpaperStore.displays(showing: sunrise, among: [builtIn, external], currentSpaces: elsewhere, inIndex: index) == [builtIn])
    }

    @Test func unreadableStoreIsUnknown() {
        #expect(AerialWallpaperStore.selectedAssetIDs(among: [sunrise], indexURL: URL(fileURLWithPath: "/nonexistent-driftwall-test/Index.plist")) == nil)
    }
}

/// A fake per-user Aerial store in a temporary folder, with a path containing spaces and a quote.
struct AerialFixture {
    static let antarctica = "03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182"
    static let london = "F604AF56-EA77-4960-AEF7-82533CC1A8B3"
    let root: URL
    let reader: AerialCatalogReader
    let work: URL
    let video: URL
    /// Stands in for the screen saver's store, which may hold Apple's original of the same Aerial.
    let copies: URL

    init() async throws {
        let base = try Fixtures.temporaryDirectory().appendingPathComponent("Driftwall's test store", isDirectory: true)
        root = base.appendingPathComponent("aerials", isDirectory: true)
        copies = base.appendingPathComponent("4KSDR240FPS", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        reader = AerialCatalogReader(root: root, originalCopyDirectories: [copies])
        work = base.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: reader.videoDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reader.catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entries: [String: Any] = ["version": 1, "assets": [
            ["id": Self.london, "accessibilityLabel": "London"],
            ["id": Self.antarctica, "accessibilityLabel": "Antarctica"],
            ["id": Self.antarctica, "accessibilityLabel": "Antarctica (portrait)"],
            ["id": "A1B2C3D4-0000-0000-0000-000000000000", "accessibilityLabel": "Not downloaded"],
            ["id": "../../evil", "accessibilityLabel": "Evil"],
        ]]
        try JSONSerialization.data(withJSONObject: entries).write(to: reader.catalogURL)
        try Data(repeating: 0xA1, count: 5000).write(to: reader.videoDirectory.appendingPathComponent("\(Self.antarctica).mov"))
        try Data(repeating: 0xB2, count: 7000).write(to: reader.videoDirectory.appendingPathComponent("\(Self.london).mov"))
        video = base.appendingPathComponent("clip.mov")
        try await Fixtures.makeVideo(at: video, width: 320, height: 180, frames: 30)
    }

    func file(_ id: String) -> URL { reader.videoDirectory.appendingPathComponent("\(id).mov") }

    /// macOS keeps download metadata (source URL, ETag) on each Aerial video as extended attributes.
    func setDownloadMetadata(_ id: String, _ value: String) throws {
        let result = setxattr(file(id).path, "LastETag", value, value.utf8.count, 0, 0)
        if result != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    /// Records the file's real ETag, as macOS does when it downloads an Aerial.
    func markAsDownloaded(_ id: String) throws -> Data {
        let contents = try Data(contentsOf: file(id))
        try setDownloadMetadata(id, "\"\(try AerialChecksum.etag(of: file(id)))\"")
        return contents
    }

    /// Changes the Aerial's contents in place (keeping its download metadata), as an edit by hand would.
    func tamper(_ id: String) throws {
        let handle = try FileHandle(forWritingTo: file(id))
        try handle.write(contentsOf: Data([0x00, 0x11, 0x22]))
        try handle.close()
    }

    func putCopy(_ data: Data, of id: String) throws {
        try data.write(to: copies.appendingPathComponent("\(id).mov"))
    }

    func downloadMetadata(_ id: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(file(id).path, "LastETag", &buffer, buffer.count, 0, 0)
        return length < 0 ? nil : String(decoding: buffer[..<length], as: UTF8.self)
    }
}

/// The HEVC NAL unit types of every frame, read from the encoded samples (4-byte length prefixes).
func hevcNALTypes(of url: URL) async throws -> Set<Int> {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var types = Set<Int>()
    while let sample = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        var offset = 0
        while offset + 6 <= data.count {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            types.insert(Int(data[offset + 4] >> 1) & 0x3F)
            offset += 4 + length
        }
    }
    return types
}

@Test func convertsWithAClosedGOP() async throws {
    // macOS's Aerial player restarts at keyframes; open-GOP leading frames (RASL) can't be decoded
    // from there. Only IDR keyframes and ordinary frames may appear.
    let directory = try Fixtures.temporaryDirectory()
    let source = directory.appendingPathComponent("clip.mov"), output = directory.appendingPathComponent("aerial.mov")
    try await Fixtures.makeVideo(at: source, width: 320, height: 180, frames: 90)
    try await AVAerialVideoConverter(minimumDuration: 7, renderSize: CGSize(width: 640, height: 360), averageBitRate: 1_000_000)
        .convert(source, to: output) { _ in }
    let types = try await hevcNALTypes(of: output)
    let openGOP: Set<Int> = [8, 9, 16, 17, 18, 21]   // RASL_N, RASL_R, BLA_*, CRA
    #expect(types.isDisjoint(with: openGOP), "NAL types \(types.sorted())")
    #expect(!types.isDisjoint(with: [19, 20]))         // IDR keyframes
    let metadata = try await MediaInspector().inspect(output)
    #expect(metadata.codec == "HEVC" && metadata.pixelWidth == 640 && metadata.duration >= 7)
    // Temporal-layer sample groups, as in Apple's Aerials.
    let file = try Data(contentsOf: output)
    for group in ["tscl", "tsas"] {
        #expect(file.range(of: Data(group.utf8)) != nil, "missing \(group) sample group")
    }
}

/// A stalled encoder (no output callbacks) must end the attempt within the stall timeout, not hang,
/// and one stall is recovered by retrying from scratch.
@Test func stalledEncoderIsRetriedOnce() async throws {
    let directory = try Fixtures.temporaryDirectory()
    let source = directory.appendingPathComponent("clip.mov"), output = directory.appendingPathComponent("aerial.mov")
    try await Fixtures.makeVideo(at: source, width: 320, height: 180, frames: 60)
    var converter = AVAerialVideoConverter(minimumDuration: 2, renderSize: CGSize(width: 640, height: 360), averageBitRate: 1_000_000)
    converter.stallTimeout = 1
    converter.simulatedStalls = 1
    let start = Date()
    try await converter.convert(source, to: output) { _ in }
    #expect(Date().timeIntervalSince(start) < 30)
    let metadata = try await MediaInspector().inspect(output)
    #expect(metadata.codec == "HEVC" && metadata.duration >= 2)
}

@Test func encoderThatKeepsStallingFailsWithAClearError() async throws {
    let directory = try Fixtures.temporaryDirectory()
    let source = directory.appendingPathComponent("clip.mov"), output = directory.appendingPathComponent("aerial.mov")
    try await Fixtures.makeVideo(at: source, width: 320, height: 180, frames: 60)
    var converter = AVAerialVideoConverter(minimumDuration: 2, renderSize: CGSize(width: 640, height: 360), averageBitRate: 1_000_000)
    converter.stallTimeout = 1
    converter.simulatedStalls = 2
    let start = Date()
    await #expect {
        try await converter.convert(source, to: output) { _ in }
    } throws: { error in
        (error as? AerialError).map { "\($0.localizedDescription)".contains("stopped responding") } ?? false
    }
    #expect(Date().timeIntervalSince(start) < 30)
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

/// Opt-in (DRIFTWALL_SLOW_TESTS=1 DRIFTWALL_SAMPLE=<path to a sample .mov>): converts with the exact
/// production settings, 3840×2160 HEVC, at least 120 s, and reports how long it took.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DRIFTWALL_SLOW_TESTS"] == "1"))
func productionAerialConversion() async throws {
    let sample = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DRIFTWALL_SAMPLE"]))
    let output = try Fixtures.temporaryDirectory().appendingPathComponent("aerial.mov")
    let start = Date()
    try await AVAerialVideoConverter().convert(sample, to: output) { _ in }
    let metadata = try await MediaInspector().inspect(output)
    print("AERIAL-CONVERSION: \(metadata.pixelWidth)x\(metadata.pixelHeight) \(metadata.codec ?? "?") \(Int(metadata.duration))s \(metadata.fileSize / 1_000_000) MB in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    #expect(metadata.pixelWidth == 3840 && metadata.pixelHeight == 2160)
    #expect(metadata.codec == "HEVC")
    #expect(metadata.duration >= 120)
}

/// Serialized: every install converts a video, and many hardware encoder sessions started at once
/// (one per parallel test) stalled and then failed with -17691.
@MainActor
@Suite("Aerial install and restore", .serialized)
struct AerialServiceTests {
    func makeService(_ fixture: AerialFixture, reloader: CountingReloader = CountingReloader()) -> AerialLockScreenService {
        AerialLockScreenService(reader: fixture.reader, workDirectory: fixture.work,
                                converter: AVAerialVideoConverter(minimumDuration: 3, renderSize: CGSize(width: 640, height: 360),
                                                                  averageBitRate: 1_000_000),
                                reloader: reloader, log: DiagnosticsLog(capacity: 10))
    }

    let wallpaper = Fixtures.wallpaper("w", title: "My Clip")

    @Test func installBacksUpReplacesAndRestores() async throws {
        let fixture = try await AerialFixture()
        let reloader = CountingReloader()
        let service = makeService(fixture, reloader: reloader)
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.antarctica })
        let original = try fixture.markAsDownloaded(AerialFixture.antarctica)
        let etag = try #require(fixture.downloadMetadata(AerialFixture.antarctica))

        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)

        guard case .installed(let manifest) = service.status else { Issue.record("expected installed, got \(service.status)"); return }
        #expect(manifest.slotName == "Antarctica")
        #expect(manifest.followsWallpaper == false) // a manual choice unless asked to follow
        #expect(manifest.wallpaperTitle == "My Clip")
        #expect(try Data(contentsOf: URL(fileURLWithPath: manifest.backupPath)) == original) // exact backup
        let replaced = try await MediaInspector().inspect(fixture.file(AerialFixture.antarctica))
        #expect(replaced.codec == "HEVC")
        #expect(replaced.duration >= 3) // short clip was looped
        #expect(replaced.pixelWidth == 640 && replaced.pixelHeight == 360) // upscaled to the exact render size
        #expect(try Data(contentsOf: fixture.file(AerialFixture.london)).count == 7000) // other Aerials untouched
        #expect(fixture.downloadMetadata(AerialFixture.antarctica) == etag) // written in place, so macOS keeps it
        #expect(try Data(contentsOf: service.installedCopyURL) == Data(contentsOf: fixture.file(AerialFixture.antarctica)))
        #expect(reloader.count == 1)

        try await service.restore()
        #expect(service.status == .notInstalled)
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == original)
        #expect(fixture.downloadMetadata(AerialFixture.antarctica) == etag)
        #expect(!FileManager.default.fileExists(atPath: manifest.backupPath))
        #expect(!FileManager.default.fileExists(atPath: service.installedCopyURL.path))
        #expect(service.manifest == nil)
        #expect(reloader.count == 2)
    }

    @Test func detectsWhenMacOSPutsTheOriginalBack() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.london })
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        try Data(repeating: 0xCC, count: 9999).write(to: fixture.file(AerialFixture.london)) // "macOS update"
        service.refresh()
        guard case .replacedByMacOS = service.status else { Issue.record("expected replacedByMacOS, got \(service.status)"); return }
        service.forgetReplacedInstall()
        #expect(service.status == .notInstalled)
    }

    @Test func refusesToBackUpAnAerialThatIsNoLongerApplesOriginal() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        _ = try fixture.markAsDownloaded(AerialFixture.antarctica)
        try fixture.tamper(AerialFixture.antarctica) // e.g. replaced by hand earlier
        let tampered = try Data(contentsOf: fixture.file(AerialFixture.antarctica))
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.antarctica })
        await #expect(throws: AerialError.originalModified("Antarctica")) {
            try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        }
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == tampered) // untouched
        #expect(service.manifest == nil)
    }

    @Test func backsUpAVerifiedCopyWhenTheAerialWasChanged() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        let original = try fixture.markAsDownloaded(AerialFixture.antarctica)
        try fixture.tamper(AerialFixture.antarctica)
        try fixture.putCopy(Data(repeating: 0x99, count: 5000), of: AerialFixture.antarctica) // not the original
        try fixture.putCopy(original, of: AerialFixture.antarctica)                            // the original
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video,
                                  slot: try #require(service.slots.first { $0.id == AerialFixture.antarctica }))
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(service.manifest).backupPath)) == original)
        try await service.restore()
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == original)
    }

    @Test func restoreUsesAVerifiedCopyWhenTheBackupIsWrong() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        let original = try fixture.markAsDownloaded(AerialFixture.london)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        let backup = URL(fileURLWithPath: try #require(service.manifest).backupPath)
        try Data(repeating: 0xEE, count: original.count).write(to: backup) // right size, wrong video

        await #expect(throws: AerialError.backupMissing) { try await service.restore() } // no verified original anywhere
        try fixture.putCopy(original, of: AerialFixture.london)
        try await service.restore()
        #expect(try Data(contentsOf: fixture.file(AerialFixture.london)) == original)
        #expect(service.manifest == nil)
    }

    @Test func reinstallingReplacesAWrongBackupWithAVerifiedCopy() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        let original = try fixture.markAsDownloaded(AerialFixture.london)
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.london })
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        let backup = URL(fileURLWithPath: try #require(service.manifest).backupPath)
        try Data(repeating: 0xEE, count: 123).write(to: backup)
        try fixture.putCopy(original, of: AerialFixture.london)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        #expect(try Data(contentsOf: backup) == original)
        #expect(service.manifest?.originalSize == Int64(original.count))
    }

    @Test func findsAndRepairsAerialsChangedOutsideDriftwall() async throws {
        let fixture = try await AerialFixture()
        let reloader = CountingReloader()
        let service = makeService(fixture, reloader: reloader)
        let antarctica = try fixture.markAsDownloaded(AerialFixture.antarctica)
        _ = try fixture.markAsDownloaded(AerialFixture.london)
        #expect(await service.findModifiedAerials().isEmpty)

        try fixture.tamper(AerialFixture.antarctica)
        try fixture.tamper(AerialFixture.london)
        try fixture.putCopy(antarctica, of: AerialFixture.antarctica) // only Antarctica has an original copy
        let modified = await service.findModifiedAerials()
        #expect(Set(modified.map(\.name)) == ["Antarctica", "London"])

        let antarcticaSlot = try #require(modified.first { $0.id == AerialFixture.antarctica })
        #expect(try await service.repairModifiedAerial(antarcticaSlot) == .restoredFromCopy)
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == antarctica)

        let londonSlot = try #require(modified.first { $0.id == AerialFixture.london })
        #expect(try await service.repairModifiedAerial(londonSlot) == .willRedownload)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(AerialFixture.london).path))
        #expect(await service.findModifiedAerials().isEmpty)
        #expect(reloader.count == 2)
    }

    @Test func theAerialDriftwallReplacedIsNotReportedAsModified() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        _ = try fixture.markAsDownloaded(AerialFixture.london)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        #expect(await service.findModifiedAerials().isEmpty)
    }

    @Test func removeAndRedownloadIsTheLastResort() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        try service.removeAndRedownload()
        #expect(!FileManager.default.fileExists(atPath: fixture.file(AerialFixture.london).path))
        #expect(service.manifest == nil)
        #expect(!FileManager.default.fileExists(atPath: service.installedCopyURL.path))
    }

    @Test func checksumMatchesAppleMultipartFormat() throws {
        // Multipart ETags are the MD5 of the parts' MD5s plus "-<parts>".
        let file = try Fixtures.temporaryDirectory().appendingPathComponent("a.mov")
        try Data("hello".utf8).write(to: file)
        #expect(try AerialChecksum.etag(of: file) == "5D41402ABC4B2A76B9719D911017C592") // md5("hello")
        let parts = Data([UInt8]("hel".utf8)).md5 + Data([UInt8]("lo".utf8)).md5
        #expect(try AerialChecksum.etag(of: file, partSize: 3) == parts.md5.hex + "-2")
        #expect(AerialChecksum.matches(file, expectedETag: "5D41402ABC4B2A76B9719D911017C592"))
        #expect(!AerialChecksum.matches(file, expectedETag: "5D41402ABC4B2A76B9719D911017C592-2"))
    }

    @Test func checksumTriesEveryPartSizeThatFitsThePartCount() throws {
        // Apple's files were uploaded with different part sizes (64 MiB, 100,000,000 bytes, …).
        let file = try Fixtures.temporaryDirectory().appendingPathComponent("b.mov")
        try Data((0..<250).map { UInt8($0) }).write(to: file)
        let withHundred = try AerialChecksum.etag(of: file, partSize: 100) // 3 parts
        #expect(try AerialChecksum.etag(of: file, partSize: 64) != withHundred)
        #expect(AerialChecksum.matches(file, expectedETag: withHundred, partSizes: [64, 100]))
        #expect(!AerialChecksum.matches(file, expectedETag: withHundred, partSizes: [64]))
        // The one-pass result equals hashing each part size separately, across 1 MiB read boundaries.
        let big = try Fixtures.temporaryDirectory().appendingPathComponent("c.mov")
        try Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: big)
        let both = try AerialChecksum.etags(of: big, partSizes: [1_000_000, 1 << 20])
        #expect(both[1_000_000] == (try AerialChecksum.etag(of: big, partSize: 1_000_000)))
        #expect(both[1 << 20]!.hasSuffix("-4"))
    }

    @Test func aFailedRecordPutsTheAerialBack() async throws {
        let fixture = try await AerialFixture()
        let reloader = CountingReloader()
        let service = makeService(fixture, reloader: reloader)
        let original = try Data(contentsOf: fixture.file(AerialFixture.london))
        // A directory where the manifest goes makes recording the install fail after the Aerial was written.
        try FileManager.default.createDirectory(at: service.manifestURL, withIntermediateDirectories: true)
        service.refresh()
        await #expect(throws: AerialError.self) {
            try await service.install(wallpaper: wallpaper, mediaURL: fixture.video,
                                      slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        }
        #expect(try Data(contentsOf: fixture.file(AerialFixture.london)) == original) // rolled back
        #expect(service.manifest == nil)
        #expect(reloader.count == 0)
        #expect(!service.isBusy)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.work.path).filter { $0.hasPrefix("rollback-") }
        #expect(leftovers.isEmpty)
    }

    @Test func aSecondInstallWhileBusyIsAnErrorNotASilentSuccess() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.london })
        let first = Task { try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot) }
        while !service.isBusy { await Task.yield() }
        await #expect(throws: AerialError.busy) {
            try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        }
        await #expect(throws: AerialError.busy) { try await service.restore() }
        try await first.value
        #expect(service.manifest?.slotID == AerialFixture.london)
    }

    @Test func aTamperedBackupPathIsNeverUsedOrDeleted() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        // Point the record at a file outside Driftwall's backup folder.
        let outside = fixture.work.deletingLastPathComponent().appendingPathComponent("precious.mov")
        try Data(repeating: 7, count: 7000).write(to: outside)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: service.manifestURL)) as! [String: Any]
        json["backupPath"] = outside.path
        json["originalSize"] = 7000
        try JSONSerialization.data(withJSONObject: json).write(to: service.manifestURL)
        let installed = try Data(contentsOf: fixture.file(AerialFixture.london))

        await #expect(throws: AerialError.unsafePath(outside.path)) { try await service.restore() }
        #expect(try Data(contentsOf: fixture.file(AerialFixture.london)) == installed) // untouched
        try service.removeAndRedownload()
        #expect(FileManager.default.fileExists(atPath: outside.path)) // not deleted
    }

    @Test func recordsWhetherTheAerialFollowsTheWallpaper() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.london })
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot, followsWallpaper: true)
        #expect(service.manifest?.followsWallpaper == true)
        // Manifests written before the flag existed still load.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: service.manifestURL)) as! [String: Any]
        json.removeValue(forKey: "followsWallpaper")
        try JSONSerialization.data(withJSONObject: json).write(to: service.manifestURL)
        #expect(service.manifest?.followsWallpaper == nil)
        #expect(service.manifest?.slotID == AerialFixture.london)
    }

    @Test func reappliesAfterMacOSDownloadsTheOriginalAgain() async throws {
        let fixture = try await AerialFixture()
        let reloader = CountingReloader()
        let service = makeService(fixture, reloader: reloader)
        #expect(try await service.reapplyIfReplaced() == false) // nothing installed
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.london })
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        let installed = try Data(contentsOf: fixture.file(AerialFixture.london))
        #expect(try await service.reapplyIfReplaced() == false) // still in place

        let redownloaded = Data(repeating: 0xCC, count: 9999)
        try redownloaded.write(to: fixture.file(AerialFixture.london)) // macOS downloads Apple's file again
        #expect(try await service.reapplyIfReplaced())
        #expect(try Data(contentsOf: fixture.file(AerialFixture.london)) == installed)
        guard case .installed(let manifest) = service.status else { Issue.record("expected installed, got \(service.status)"); return }
        #expect(manifest.originalSize == 9999)
        #expect(reloader.count == 2)

        try await service.restore() // gives back the newest download
        #expect(try Data(contentsOf: fixture.file(AerialFixture.london)) == redownloaded)
    }

    @Test func doesNotReapplyWhenMacOSRemovedTheDownload() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        try FileManager.default.removeItem(at: fixture.file(AerialFixture.london))
        #expect(try await service.reapplyIfReplaced() == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(AerialFixture.london).path))
    }

    @Test func switchingToAnotherAerialRestoresTheFirst() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let antarcticaOriginal = try Data(contentsOf: fixture.file(AerialFixture.antarctica))
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.antarctica }))
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == antarcticaOriginal)
        #expect(service.manifest?.slotID == AerialFixture.london)
    }

    @Test func reinstallingSameAerialKeepsTheOriginalBackup() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let original = try Data(contentsOf: fixture.file(AerialFixture.antarctica))
        let slot = try #require(service.slots.first { $0.id == AerialFixture.antarctica })
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.antarctica }))
        try await service.restore()
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == original) // not the first replacement
    }

    @Test func restoreRefusesWithoutAValidBackup() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        await #expect(throws: AerialError.nothingToRestore) { try await service.restore() }
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.antarctica })
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        try FileManager.default.removeItem(atPath: try #require(service.manifest).backupPath)
        await #expect(throws: AerialError.backupMissing) { try await service.restore() }
    }

    @Test func invalidSourceVideoFailsBeforeAnythingChanges() async throws {
        let fixture = try await AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let broken = fixture.work.deletingLastPathComponent().appendingPathComponent("broken.mov")
        try Data(repeating: 1, count: 100).write(to: broken)
        let original = try Data(contentsOf: fixture.file(AerialFixture.antarctica))
        await #expect(throws: (any Error).self) {
            try await service.install(wallpaper: wallpaper, mediaURL: broken, slot: try #require(service.slots.first { $0.id == AerialFixture.antarctica }))
        }
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == original)
        #expect(service.manifest == nil)
    }
}
