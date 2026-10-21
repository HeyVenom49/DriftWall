import Foundation
import Testing
@testable import DriftwallCore

/// Runs the real generated cleanup script with /bin/bash against a fake setup in a temporary folder.
/// The wallpaper reload is replaced by touching a file, and no desktop pictures are recorded, so the
/// tests never touch the real Aerial store, screen savers, LaunchAgents or desktop.
struct CleanupFixture {
    static let slot = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    let root: URL
    let app: URL
    let support: URL
    let videos: URL
    let saver: URL
    let plist: URL
    let reloaded: URL
    let original = Data(repeating: 0xA1, count: 4000)   // Apple's Aerial
    let installed = Data(repeating: 0xB2, count: 6000)  // Driftwall's video

    init(appPath: String? = nil, gracePeriod: Int = 0, backupSize: Int? = nil, slotID: String = slot) throws {
        root = try Fixtures.temporaryDirectory()
        app = appPath.map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent("Applications/Driftwall.app", isDirectory: true)
        support = root.appendingPathComponent("Support/Driftwall", isDirectory: true)
        videos = root.appendingPathComponent("aerials/videos", isDirectory: true)
        saver = root.appendingPathComponent("Screen Savers/Driftwall.saver", isDirectory: true)
        plist = root.appendingPathComponent("LaunchAgents/test.cleanup.plist")
        reloaded = root.appendingPathComponent("reloaded")
        let fm = FileManager.default
        if appPath == nil { try fm.createDirectory(at: app, withIntermediateDirectories: true) }
        for dir in [videos, saver, support.appendingPathComponent("Aerial/Backup"), support.appendingPathComponent("LockScreen/Media"),
                    plist.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try installed.write(to: videos.appendingPathComponent("\(Self.slot).mov"))
        _ = setxattr(videos.appendingPathComponent("\(Self.slot).mov").path, "LastETag", "\"etag\"", 6, 0, 0)
        try original.write(to: support.appendingPathComponent("Aerial/Backup/\(Self.slot).mov"))
        let manifest: [String: Any] = ["slotID": slotID, "originalSize": backupSize ?? original.count, "installedSize": installed.count]
        try JSONSerialization.data(withJSONObject: manifest).write(to: support.appendingPathComponent("Aerial/manifest.json"))
        try Data([1]).write(to: support.appendingPathComponent("LockScreen/Media/video.mov"))

        let agent = CleanupAgent(label: "test.driftwall.cleanup.\(UUID().uuidString)", appPath: app.path,
                                 bundleIdentifier: "test.driftwall.\(UUID().uuidString)",
                                 supportDirectory: support, aerialVideoDirectory: videos, screenSaverPath: saver,
                                 launchAgentPath: plist, reloadCommand: "/usr/bin/touch \(CleanupAgent.quote(reloaded.path))",
                                 gracePeriod: gracePeriod)
        try fm.createDirectory(at: agent.scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(agent.script().utf8).write(to: agent.scriptURL)
        try agent.launchAgentPlist().write(to: plist)
        scriptURL = agent.scriptURL
    }

    let scriptURL: URL

    func run() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    var aerial: Data? { try? Data(contentsOf: videos.appendingPathComponent("\(Self.slot).mov")) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    var log: String { (try? String(contentsOf: support.appendingPathComponent("Cleanup/cleanup.log"), encoding: .utf8)) ?? "" }

    func etag() -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(videos.appendingPathComponent("\(Self.slot).mov").path, "LastETag", &buffer, buffer.count, 0, 0)
        return length < 0 ? nil : String(decoding: buffer[..<length], as: UTF8.self)
    }
}

@Suite("Cleanup after Driftwall is deleted")
struct CleanupAgentTests {
    @Test func doesNothingWhileTheAppExists() throws {
        let fixture = try CleanupFixture()
        try fixture.run()
        try fixture.run()
        #expect(fixture.aerial == fixture.installed)
        #expect(fixture.exists(fixture.saver) && fixture.exists(fixture.plist))
    }

    @Test func undoesEverythingOnceTheAppHasBeenGoneForTheGracePeriod() throws {
        let fixture = try CleanupFixture()
        try FileManager.default.removeItem(at: fixture.app)

        try fixture.run() // first sighting: only remembers when the app went missing
        #expect(fixture.aerial == fixture.installed)
        #expect(fixture.exists(fixture.saver))

        try fixture.run()
        #expect(fixture.aerial == fixture.original)          // Apple's Aerial is back…
        #expect(fixture.etag() == "\"etag\"")                // …in place, keeping macOS's download info
        #expect(fixture.exists(fixture.reloaded))            // and the wallpaper was reloaded
        #expect(!fixture.exists(fixture.saver))
        #expect(!fixture.exists(fixture.support.appendingPathComponent("LockScreen")))
        #expect(!fixture.exists(fixture.support.appendingPathComponent("Aerial")))
        #expect(!fixture.exists(fixture.plist))              // and the task removed itself
        #expect(!fixture.exists(fixture.scriptURL))
        #expect(fixture.log.contains("Put Apple's original Aerial"))
    }

    @Test func waitsOutTheGracePeriod() throws {
        // A rebuild or an update removes the app for a moment.
        let fixture = try CleanupFixture(gracePeriod: 3600)
        try FileManager.default.removeItem(at: fixture.app)
        try fixture.run()
        try fixture.run()
        #expect(fixture.aerial == fixture.installed)
        #expect(fixture.exists(fixture.saver) && fixture.exists(fixture.plist))
        // The app comes back: the pending state is cleared.
        try FileManager.default.createDirectory(at: fixture.app, withIntermediateDirectories: true)
        try fixture.run()
        #expect(!fixture.exists(fixture.support.appendingPathComponent("Cleanup/app-missing-since")))
    }

    @Test func anUnpluggedDriveIsNotADeletion() throws {
        let fixture = try CleanupFixture(appPath: "/Volumes/Driftwall-Test-\(UUID().uuidString)/Driftwall.app")
        try fixture.run()
        try fixture.run()
        #expect(fixture.aerial == fixture.installed)
        #expect(fixture.exists(fixture.saver) && fixture.exists(fixture.plist))
    }

    @Test func withoutAUsableBackupTheVideoIsRemovedSoMacOSDownloadsTheOriginal() throws {
        let fixture = try CleanupFixture(backupSize: 1234) // recorded size doesn't match the backup
        try FileManager.default.removeItem(at: fixture.app)
        try fixture.run()
        try fixture.run()
        #expect(fixture.aerial == nil)
        #expect(!fixture.exists(fixture.plist))
    }

    @Test func aTamperedRecordTouchesNoAerial() throws {
        let fixture = try CleanupFixture(slotID: "../../etc/passwd")
        try FileManager.default.removeItem(at: fixture.app)
        try fixture.run()
        try fixture.run()
        #expect(fixture.aerial == fixture.installed)
        #expect(fixture.log.contains("Ignoring an unexpected Aerial record"))
    }

    @Test func theDesktopRestoreScriptCompiles() throws {
        // Compiled only (never run), so the test can't change the real desktop picture.
        let directory = try Fixtures.temporaryDirectory()
        let source = directory.appendingPathComponent("restore.js")
        try Data(CleanupAgent.desktopRestoreScript.utf8).write(to: source)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-l", "JavaScript", "-o", directory.appendingPathComponent("restore.scpt").path, source.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func originalPicturesAreRecordedOnceAndNeverADriftwallFrame() {
        let frames = URL(fileURLWithPath: "/Users/x/Library/Caches/Driftwall/Frames")
        var originals = OriginalDesktopPictures()
        let frame = originals.recordIfNeeded(displayID: "A", name: "Built-in", picture: frames.appendingPathComponent("a.png"), driftwallFramesDirectory: frames)
        let first = originals.recordIfNeeded(displayID: "A", name: "Built-in", picture: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sequoia.heic"), driftwallFramesDirectory: frames)
        let second = originals.recordIfNeeded(displayID: "A", name: "Built-in", picture: URL(fileURLWithPath: "/Users/x/Other.png"), driftwallFramesDirectory: frames)
        #expect(!frame && first && !second)
        #expect(originals.displays["A"]?.path == "/System/Library/Desktop Pictures/Sequoia.heic")
    }
}
