import AVFoundation
import Foundation
import Testing
@testable import DriftwallCore

/// Executes the real generated command with /bin/sh inside a temporary folder. Only the `chown root`
/// step is replaced (tests don't run as root), so quoting and paths are exercised for real.
struct ShellTestRunner: PrivilegedRunner {
    var cancel = false
    func runAsAdministrator(_ shellCommand: String) async throws {
        if cancel { throw AerialError.cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand.replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw AerialError.privilegedStepFailed("exit \(process.terminationStatus)") }
    }
}

@Suite("Aerial catalog and command safety")
struct AerialSafetyTests {
    @Test func validAssetIDs() {
        #expect(AerialCatalogReader.isValidAssetID("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182"))
        #expect(!AerialCatalogReader.isValidAssetID("../../etc/passwd"))
        #expect(!AerialCatalogReader.isValidAssetID("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE15118"))
        #expect(!AerialCatalogReader.isValidAssetID("03EC0F5E CCA8 4E0A 9FEC 5BD1CE151182"))
    }

    @Test func destinationMustBeAnAerialFileInsideTheStore() throws {
        let dir = URL(fileURLWithPath: "/tmp/store/4KSDR240FPS")
        let good = dir.appendingPathComponent("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.mov")
        try AerialCommandBuilder.validate(destination: good, videoDirectory: dir)
        for bad in [
            dir.appendingPathComponent("../03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.mov"),
            dir.appendingPathComponent("notes.mov"),
            dir.appendingPathComponent("03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.sh"),
            URL(fileURLWithPath: "/System/Library/03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182.mov"),
        ] {
            #expect(throws: AerialError.self) { try AerialCommandBuilder.validate(destination: bad, videoDirectory: dir) }
        }
    }

    @Test func quoting() {
        #expect(AerialCommandBuilder.shellQuote("a b") == "'a b'")
        #expect(AerialCommandBuilder.shellQuote("it's") == "'it'\\''s'")
        #expect(AerialCommandBuilder.appleScriptLiteral(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
        let script = AerialCommandBuilder.appleScript(forShellCommand: "/bin/cp 'a' 'b'")
        #expect(script == #"do shell script "/bin/cp 'a' 'b'" with administrator privileges"#)
    }

    @Test func catalogListsOnlyDownloadedValidAerials() throws {
        let fixture = try AerialFixture()
        let slots = try fixture.reader.availableSlots()
        #expect(slots.map(\.name) == ["Antarctica", "London"]) // sorted; missing file and invalid id skipped
        #expect(slots.allSatisfy { $0.fileSize > 0 })
    }

    @Test func missingCatalogIsReported() {
        let reader = AerialCatalogReader(root: URL(fileURLWithPath: "/nonexistent-driftwall-test"))
        #expect(throws: AerialError.self) { try reader.availableSlots() }
    }
}

/// A fake Aerial store in a temporary folder, with a path containing spaces and a quote.
struct AerialFixture {
    static let antarctica = "03EC0F5E-CCA8-4E0A-9FEC-5BD1CE151182"
    static let london = "F604AF56-EA77-4960-AEF7-82533CC1A8B3"
    let root: URL
    let reader: AerialCatalogReader
    let work: URL
    let video: URL

    init() throws {
        let base = try Fixtures.temporaryDirectory().appendingPathComponent("Driftwall's test store", isDirectory: true)
        root = base.appendingPathComponent("Customer", isDirectory: true)
        reader = AerialCatalogReader(root: root)
        work = base.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: reader.videoDirectory, withIntermediateDirectories: true)
        let entries: [String: Any] = ["version": 1, "assets": [
            ["id": Self.london, "accessibilityLabel": "London"],
            ["id": Self.antarctica, "accessibilityLabel": "Antarctica"],
            ["id": "A1B2C3D4-0000-0000-0000-000000000000", "accessibilityLabel": "Not downloaded"],
            ["id": "../../evil", "accessibilityLabel": "Evil"],
        ]]
        try JSONSerialization.data(withJSONObject: entries).write(to: root.appendingPathComponent("entries.json"))
        try Data(repeating: 0xA1, count: 5000).write(to: reader.videoDirectory.appendingPathComponent("\(Self.antarctica).mov"))
        try Data(repeating: 0xB2, count: 7000).write(to: reader.videoDirectory.appendingPathComponent("\(Self.london).mov"))
        video = base.appendingPathComponent("clip.mov")
        try Fixtures.makeVideo(at: video, width: 320, height: 180, frames: 30)
    }

    func file(_ id: String) -> URL { reader.videoDirectory.appendingPathComponent("\(id).mov") }
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
    func makeService(_ fixture: AerialFixture, runner: PrivilegedRunner = ShellTestRunner()) -> AerialLockScreenService {
        AerialLockScreenService(reader: fixture.reader, workDirectory: fixture.work,
                                converter: AVAerialVideoConverter(minimumDuration: 3, presetName: AVAssetExportPresetHEVC1920x1080,
                                                                  renderSize: CGSize(width: 640, height: 360)),
                                runner: runner, log: DiagnosticsLog(capacity: 10))
    }

    let wallpaper = Fixtures.wallpaper("w", title: "My Clip")

    @Test func installBacksUpReplacesAndRestores() async throws {
        let fixture = try AerialFixture()
        let service = makeService(fixture)
        service.refresh()
        let slot = try #require(service.slots.first { $0.id == AerialFixture.antarctica })
        let original = try Data(contentsOf: fixture.file(AerialFixture.antarctica))

        try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: slot)

        guard case .installed(let manifest) = service.status else { Issue.record("expected installed, got \(service.status)"); return }
        #expect(manifest.slotName == "Antarctica")
        #expect(manifest.wallpaperTitle == "My Clip")
        #expect(try Data(contentsOf: URL(fileURLWithPath: manifest.backupPath)) == original) // exact backup
        let replaced = try await MediaInspector().inspect(fixture.file(AerialFixture.antarctica))
        #expect(replaced.codec == "HEVC")
        #expect(replaced.duration >= 3) // short clip was looped
        #expect(replaced.pixelWidth == 640 && replaced.pixelHeight == 360) // upscaled to the exact render size
        #expect(try Data(contentsOf: fixture.file(AerialFixture.london)).count == 7000) // other Aerials untouched

        try await service.restore()
        #expect(service.status == .notInstalled)
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == original)
        #expect(!FileManager.default.fileExists(atPath: manifest.backupPath))
        #expect(service.manifest == nil)
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

    @Test func cancellingThePasswordChangesNothing() async throws {
        let fixture = try AerialFixture()
        let service = makeService(fixture, runner: ShellTestRunner(cancel: true))
        service.refresh()
        let original = try Data(contentsOf: fixture.file(AerialFixture.antarctica))
        await #expect(throws: AerialError.cancelled) {
            try await service.install(wallpaper: wallpaper, mediaURL: fixture.video, slot: try #require(service.slots.first { $0.id == AerialFixture.antarctica }))
        }
        #expect(try Data(contentsOf: fixture.file(AerialFixture.antarctica)) == original)
        #expect(service.manifest == nil)
        #expect(service.status == .notInstalled)
        #expect(!service.isBusy)
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
