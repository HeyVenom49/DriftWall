import AVFoundation
import Foundation
import Testing
@testable import DriftwallCore

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

    @Test func catalogListsOnlyDownloadedValidAerials() throws {
        let fixture = try AerialFixture()
        let slots = try fixture.reader.availableSlots()
        #expect(slots.map(\.name) == ["Antarctica", "London"]) // sorted; missing file, invalid id and duplicate skipped
        #expect(slots.allSatisfy { $0.fileSize > 0 })
    }

    @Test func nothingDownloadedYetIsAnEmptyListNotAnError() throws {
        let reader = AerialCatalogReader(root: URL(fileURLWithPath: "/nonexistent-driftwall-test"))
        #expect(try reader.availableSlots().isEmpty)
    }

    @Test func downloadedAerialsAreListedWithoutTheWallpaperCatalog() throws {
        let fixture = try AerialFixture()
        try FileManager.default.removeItem(at: fixture.reader.catalogURL)
        // Names come from the screen saver's catalog when the wallpaper's own one is missing.
        let fallback = fixture.root.deletingLastPathComponent().appendingPathComponent("saver-entries.json")
        try JSONSerialization.data(withJSONObject: ["assets": [["id": AerialFixture.london, "accessibilityLabel": "London (saver)"]]]).write(to: fallback)
        let reader = AerialCatalogReader(root: fixture.root, fallbackCatalogURLs: [fallback])
        #expect(try reader.availableSlots().map(\.name) == ["Aerial 03EC0F5E", "London (saver)"])
    }

    @Test func skipsFilesThatAreNotAerialVideos() throws {
        let fixture = try AerialFixture()
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

    init() throws {
        let base = try Fixtures.temporaryDirectory().appendingPathComponent("Driftwall's test store", isDirectory: true)
        root = base.appendingPathComponent("aerials", isDirectory: true)
        reader = AerialCatalogReader(root: root)
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
        try Fixtures.makeVideo(at: video, width: 320, height: 180, frames: 30)
    }

    func file(_ id: String) -> URL { reader.videoDirectory.appendingPathComponent("\(id).mov") }

    /// macOS keeps download metadata (source URL, ETag) on each Aerial video as extended attributes.
    func setDownloadMetadata(_ id: String, _ value: String) throws {
        let result = setxattr(file(id).path, "LastETag", value, value.utf8.count, 0, 0)
        if result != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    func downloadMetadata(_ id: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(file(id).path, "LastETag", &buffer, buffer.count, 0, 0)
        return length < 0 ? nil : String(decoding: buffer[..<length], as: UTF8.self)
    }
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

@MainActor
@Suite("Aerial install and restore")
struct AerialServiceTests {
    func makeService(_ fixture: AerialFixture, reloader: CountingReloader = CountingReloader()) -> AerialLockScreenService {
        AerialLockScreenService(reader: fixture.reader, workDirectory: fixture.work,
                                converter: AVAerialVideoConverter(minimumDuration: 3, presetName: AVAssetExportPresetHEVC1920x1080,
                                                                  renderSize: CGSize(width: 640, height: 360)),
                                reloader: reloader, log: DiagnosticsLog(capacity: 10))
    }

    let wallpaper = Fixtures.wallpaper("w", title: "My Clip")

    @Test func installBacksUpReplacesAndRestores() async throws {
        let fixture = try AerialFixture()
        let reloader = CountingReloader()
        let service = makeService(fixture, reloader: reloader)
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.antarctica })
        let original = try Data(contentsOf: fixture.file(AerialFixture.antarctica))
        try fixture.setDownloadMetadata(AerialFixture.antarctica, "\"etag-1\"")

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
        #expect(fixture.downloadMetadata(AerialFixture.antarctica) == "\"etag-1\"") // written in place, so macOS keeps it
        #expect(try Data(contentsOf: service.installedCopyURL) == Data(contentsOf: fixture.file(AerialFixture.antarctica)))
        #expect(reloader.count == 1)

        try await service.restore()
        #expect(service.status == .notInstalled)
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == original)
        #expect(fixture.downloadMetadata(AerialFixture.antarctica) == "\"etag-1\"")
        #expect(!FileManager.default.fileExists(atPath: manifest.backupPath))
        #expect(!FileManager.default.fileExists(atPath: service.installedCopyURL.path))
        #expect(service.manifest == nil)
        #expect(reloader.count == 2)
    }

    @Test func detectsWhenMacOSPutsTheOriginalBack() async throws {
        let fixture = try AerialFixture()
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

    @Test func recordsWhetherTheAerialFollowsTheWallpaper() async throws {
        let fixture = try AerialFixture()
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
        let fixture = try AerialFixture()
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
        let fixture = try AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        try FileManager.default.removeItem(at: fixture.file(AerialFixture.london))
        #expect(try await service.reapplyIfReplaced() == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(AerialFixture.london).path))
    }

    @Test func switchingToAnotherAerialRestoresTheFirst() async throws {
        let fixture = try AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let antarcticaOriginal = try Data(contentsOf: fixture.file(AerialFixture.antarctica))
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.antarctica }))
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.london }))
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == antarcticaOriginal)
        #expect(service.manifest?.slotID == AerialFixture.london)
    }

    @Test func reinstallingSameAerialKeepsTheOriginalBackup() async throws {
        let fixture = try AerialFixture()
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
        let fixture = try AerialFixture()
        let service = makeService(fixture)
        await #expect(throws: AerialError.nothingToRestore) { try await service.restore() }
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.antarctica })
        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)
        try FileManager.default.removeItem(atPath: try #require(service.manifest).backupPath)
        await #expect(throws: AerialError.backupMissing) { try await service.restore() }
    }

    @Test func invalidSourceVideoFailsBeforeAnythingChanges() async throws {
        let fixture = try AerialFixture()
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
