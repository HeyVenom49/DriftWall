import Foundation
import Testing
@testable import DriftwallCore

@MainActor
final class FakeLockScreenSystem: LockScreenSystem {
    var screenSaverFrameworkPresent = true
    var osVersion = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
    var isSaverInstalled = false
    var selection: ScreenSaverSelection = .notSelected
    var installError: Error?
    var stillPictureError: Error?
    private(set) var stillPictures: [URL] = []

    func installSaver() throws {
        if let installError { throw installError }
        isSaverInstalled = true
    }
    func uninstallSaver() throws { isSaverInstalled = false }
    func screenSaverSelection() -> ScreenSaverSelection { selection }
    func setStillSystemPicture(_ imageURL: URL) throws {
        if let stillPictureError { throw stillPictureError }
        stillPictures.append(imageURL)
    }
}

@Suite("Lock screen: capabilities and media compatibility")
struct LockScreenCompatibilityTests {
    @Test func capabilitiesOnCurrentMacOS() {
        let caps = LockScreenCapabilities.evaluate(osVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 1), screenSaverFrameworkPresent: true)
        #expect(caps.videoWhileLocked.isSupported)
        #expect(caps.staticImage.isSupported)
        #expect(caps.desktopVideo.isSupported)
        #expect(!caps.systemVideoWallpaper.isSupported) // private entitlement only
        #expect(caps.osVersionText == "macOS 27.0.1")
    }

    @Test func capabilitiesFallBackOnUnsupportedSystems() {
        let old = LockScreenCapabilities.evaluate(osVersion: .init(majorVersion: 13, minorVersion: 6, patchVersion: 0), screenSaverFrameworkPresent: true)
        #expect(!old.videoWhileLocked.isSupported)
        let noFramework = LockScreenCapabilities.evaluate(osVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0), screenSaverFrameworkPresent: false)
        #expect(!noFramework.videoWhileLocked.isSupported)
    }

    @Test func mediaCompatibility() {
        let url = URL(fileURLWithPath: "/tmp/x.mov")
        var w = Fixtures.wallpaper("w", source: .imported, mediaPath: "/tmp/x.mov")
        w.codec = "HEVC"
        #expect(LockScreenMediaCompatibility.evaluate(w, availability: .available(url)) == .compatible)
        #expect(!LockScreenMediaCompatibility.evaluate(w, availability: .missing).isUsable)

        var noMetadata = w
        noMetadata.duration = 0
        #expect(!LockScreenMediaCompatibility.evaluate(noMetadata, availability: .available(url)).isUsable)

        var wrongType = w
        wrongType.mediaPath = "/tmp/x.avi"
        #expect(!LockScreenMediaCompatibility.evaluate(wrongType, availability: .available(url)).isUsable)

        var exotic = w
        exotic.codec = "AV1"
        if case .compatibleWithWarning = LockScreenMediaCompatibility.evaluate(exotic, availability: .available(url)) {} else {
            Issue.record("unusual codec should warn")
        }

        var portrait = w
        portrait.pixelWidth = 1080
        portrait.pixelHeight = 1920
        if case .compatibleWithWarning = LockScreenMediaCompatibility.evaluate(portrait, availability: .available(url)) {} else {
            Issue.record("portrait should warn")
        }
    }

    @Test func desktopAndLockScreenPreferenceCombinations() {
        var settings = LockScreenSettings()
        #expect(settings.targetWallpaperID(desktopWallpaperID: "desk") == nil) // disabled
        settings.isEnabled = true
        #expect(settings.targetWallpaperID(desktopWallpaperID: "desk") == "desk") // same as desktop
        #expect(settings.targetWallpaperID(desktopWallpaperID: nil) == nil)
        settings.useDesktopWallpaper = false
        #expect(settings.targetWallpaperID(desktopWallpaperID: "desk") == nil) // nothing chosen yet
        settings.wallpaperID = "lock"
        #expect(settings.targetWallpaperID(desktopWallpaperID: "desk") == "lock") // independent
    }

    @Test func preferencesPersistAndDecodeTolerantly() throws {
        let store = try Fixtures.memoryStore()
        var settings = AppSettings()
        settings.lockScreen.isEnabled = true
        settings.lockScreen.useDesktopWallpaper = false
        settings.lockScreen.wallpaperID = "sample.neon-grid"
        settings.lockScreen.setsStillSystemPicture = true
        try store.saveSettings(settings)
        #expect(try store.loadSettings().lockScreen == settings.lockScreen)

        // Settings saved before the feature existed decode with lock screen off.
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"videoGravity":"fill"}"#.utf8))
        #expect(legacy.lockScreen == LockScreenSettings())
    }
}

@MainActor
@Suite("Lock screen service")
struct LockScreenServiceTests {
    let dir: URL
    let system = FakeLockScreenSystem()
    let service: LockScreenWallpaperService
    let video: URL

    init() async throws {
        dir = try Fixtures.temporaryDirectory()
        video = dir.appendingPathComponent("source.mov")
        try await Fixtures.makeVideo(at: video)
        service = LockScreenWallpaperService(directory: dir.appendingPathComponent("LockScreen"), system: system, log: DiagnosticsLog(capacity: 10))
    }

    func wallpaper(_ id: String = "w1", title: String = "Clip") -> Wallpaper {
        var w = Fixtures.wallpaper(id, title: title, source: .imported, mediaPath: video.path)
        w.codec = "H.264"
        return w
    }

    @Test func applyWritesVerifiedConfigAndCopiesMedia() throws {
        let config = try service.apply(wallpaper(), mediaURL: video, availability: .available(video), gravity: .fit)
        #expect(config.wallpaperID == "w1")
        #expect(FileManager.default.fileExists(atPath: config.mediaPath))
        #expect(config.mediaPath.hasPrefix(service.mediaDirectory.path))
        #expect(FileManager.default.fileExists(atPath: video.path)) // original untouched
        #expect(LockScreenWallpaperService.readConfig(at: service.configURL) == config)

        // The saver decodes this file with its own minimal decoder: keys and value types must match.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: service.configURL)) as? [String: Any]
        #expect(json?["version"] as? Int == 1)
        #expect(json?["gravity"] as? String == "fit")
        #expect(json?["mediaPath"] as? String == config.mediaPath)
        #expect(json?["title"] as? String == "Clip")
    }

    @Test func applyingAnotherWallpaperReplacesOldMedia() throws {
        let first = try service.apply(wallpaper("a"), mediaURL: video, availability: .available(video), gravity: .fill)
        let second = try service.apply(wallpaper("b", title: "Other"), mediaURL: video, availability: .available(video), gravity: .fill)
        #expect(!FileManager.default.fileExists(atPath: first.mediaPath))
        #expect(FileManager.default.fileExists(atPath: second.mediaPath))
        #expect(try FileManager.default.contentsOfDirectory(atPath: service.mediaDirectory.path).count == 1)
    }

    @Test func invalidMediaIsRejectedWithoutWritingAnything() {
        #expect(throws: LockScreenError.self) {
            try service.apply(wallpaper(), mediaURL: nil, availability: .missing, gravity: .fill)
        }
        #expect(throws: LockScreenError.mediaUnavailable("Clip")) {
            try service.apply(wallpaper(), mediaURL: dir.appendingPathComponent("gone.mov"), availability: .available(video), gravity: .fill)
        }
        #expect(service.config == nil)
        #expect(!FileManager.default.fileExists(atPath: service.configURL.path))
    }

    @Test func unsupportedSystemRefusesToApply() throws {
        system.osVersion = .init(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        let oldService = LockScreenWallpaperService(directory: dir.appendingPathComponent("Old"), system: system)
        #expect(throws: LockScreenError.self) {
            try oldService.apply(wallpaper(), mediaURL: video, availability: .available(video), gravity: .fill)
        }
        var settings = LockScreenSettings()
        settings.isEnabled = true
        oldService.refresh(settings: settings, targetWallpaperTitle: "Clip")
        if case .unsupported = oldService.status {} else { Issue.record("expected unsupported status, got \(oldService.status)") }
    }

    @Test func writeFailureIsReported() throws {
        // Make the media folder impossible to create by putting a file where it should go.
        try FileManager.default.createDirectory(at: service.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: service.mediaDirectory.path, contents: Data([1]))
        #expect {
            try service.apply(wallpaper(), mediaURL: video, availability: .available(video), gravity: .fill)
        } throws: { error in
            if case LockScreenError.writeFailed = error { return true }
            return false
        }
        #expect(service.config == nil)
    }

    @Test func statusOnlyReportsActiveWhenEverythingIsConfirmed() throws {
        var settings = LockScreenSettings()
        service.refresh(settings: settings, targetWallpaperTitle: nil)
        #expect(service.status == .disabled)

        settings.isEnabled = true
        service.refresh(settings: settings, targetWallpaperTitle: nil)
        #expect(service.status == .nothingSelected)

        service.refresh(settings: settings, targetWallpaperTitle: "Clip")
        if case .needsSetup = service.status {} else { Issue.record("not applied yet → needs setup") }

        try service.apply(wallpaper(), mediaURL: video, availability: .available(video), gravity: .fill)
        service.refresh(settings: settings, targetWallpaperTitle: "Clip")
        #expect(service.status == .needsSetup("Install the Driftwall screen saver to finish setup."))

        try service.installSaver()
        system.selection = .notSelected
        service.refresh(settings: settings, targetWallpaperTitle: "Clip")
        #expect(service.status == .needsSetup("Select “Driftwall” as your screen saver to finish setup."))

        system.selection = .unknown
        service.refresh(settings: settings, targetWallpaperTitle: "Clip")
        if case .active = service.status { Issue.record("unknown selection must not report success") }

        system.selection = .selected
        service.refresh(settings: settings, targetWallpaperTitle: "Clip")
        #expect(service.status == .active(title: "Clip"))

        // The video disappearing afterwards is detected.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: try #require(service.config).mediaPath))
        service.refresh(settings: settings, targetWallpaperTitle: "Clip")
        if case .active = service.status { Issue.record("missing media must not report success") }
    }

    @Test func installFailureIsReported() {
        system.installError = CocoaError(.fileWriteNoPermission)
        #expect {
            try service.installSaver()
        } throws: { error in
            if case LockScreenError.saverInstallFailed = error { return true }
            return false
        }
        #expect(!service.isSaverInstalled)
    }

    @Test func stillPictureFailureIsReported() {
        system.stillPictureError = CocoaError(.fileReadNoPermission)
        #expect {
            try service.setStillSystemPicture(video)
        } throws: { error in
            if case LockScreenError.stillPictureFailed = error { return true }
            return false
        }
    }

    @Test func clearRemovesConfigurationAndCopies() throws {
        try service.apply(wallpaper(), mediaURL: video, availability: .available(video), gravity: .fill)
        service.clear()
        #expect(service.config == nil)
        #expect(!FileManager.default.fileExists(atPath: service.configURL.path))
        #expect(!FileManager.default.fileExists(atPath: service.mediaDirectory.path))
        #expect(FileManager.default.fileExists(atPath: video.path))
    }

    @Test func configSurvivesRestart() throws {
        let applied = try service.apply(wallpaper(), mediaURL: video, availability: .available(video), gravity: .stretch)
        let restarted = LockScreenWallpaperService(directory: service.directory, system: system)
        #expect(restarted.config == applied)
    }
}
