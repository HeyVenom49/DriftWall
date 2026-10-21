import AppKit
import DriftwallCore

/// Lock-screen actions. The work happens in `LockScreenWallpaperService`; this layer supplies library
/// lookups, still frames and user-facing messages.
extension AppController {
    /// The wallpaper the lock screen should show under the current settings.
    var lockScreenTargetID: WallpaperID? {
        settings.lockScreen.targetWallpaperID(desktopWallpaperID: currentWallpaper?.id)
    }

    func refreshLockScreen() {
        lockScreen.refresh(settings: settings.lockScreen, targetWallpaperTitle: library.wallpaper(lockScreenTargetID)?.title)
        Task { passwordDelay = await MacLockScreenSystem.passwordDelayDescription() }
    }

    /// At launch: make sure the saver's configuration matches the preferences (e.g. after the video moved).
    func restoreLockScreen() {
        // An older Driftwall module from a previous build is updated in place; the user's
        // screen-saver choice points at the same path, so it stays selected.
        if FileManager.default.fileExists(atPath: lockScreenSystem.installedSaverURL.path), !lockScreenSystem.isSaverInstalled {
            try? lockScreen.installSaver()
        }
        refreshLockScreen()
        guard settings.lockScreen.isEnabled, let target = lockScreenTargetID else { return }
        let configMatches = lockScreen.config?.wallpaperID == target
            && lockScreen.config.map { FileManager.default.fileExists(atPath: $0.mediaPath) } == true
        if !configMatches { Task { await applyLockScreen(quiet: true) } }
    }

    var isLockScreenReady: Bool {
        if case .active = lockScreen.status { return settings.lockScreen.isEnabled }
        return false
    }

    /// Everything is done except the screen-saver choice, which only the user can make.
    var isWaitingForScreenSaverSelection: Bool {
        settings.lockScreen.isEnabled && lockScreen.isSaverInstalled && lockScreen.config != nil
            && lockScreen.saverSelection != .selected
    }

    var screenSaverSelectionSteps: [String] {
        MacLockScreenSystem.hasSeparateScreenSaverPane
            ? ["Find “Driftwall” in the Screen Saver list (under Other).", "Click it once."]
            : ["Click the “Screen Saver…” button in Wallpaper settings.", "Click “Driftwall” (near the bottom, under Other)."]
    }

    /// One-click setup: turn on, install the module, prepare the video, open System Settings, and wait
    /// for the user's single choice there.
    func setUpLockScreen() async {
        settings.lockScreen.isEnabled = true
        if lockScreenTargetID == nil {
            // No live desktop wallpaper to follow yet: start with a featured one so setup never stalls.
            if let fallback = library.featuredWallpapers.first(where: { library.isAvailable($0.id) }) ?? library.wallpapers.first(where: { library.isAvailable($0.id) }) {
                settings.lockScreen.useDesktopWallpaper = false
                settings.lockScreen.wallpaperID = fallback.id
            }
        }
        if !lockScreen.isSaverInstalled {
            do { try lockScreen.installSaver() } catch {
                showBanner(.error, error.localizedDescription)
                refreshLockScreen()
                return
            }
        }
        guard await applyLockScreen(quiet: true) else {
            showBanner(.error, "The lock-screen video couldn’t be prepared. \(lockScreen.status.summary)")
            return
        }
        refreshLockScreen()
        if lockScreen.saverSelection != .selected {
            MacLockScreenSystem.openScreenSaverSettings()
            watchForScreenSaverSelection()
        } else {
            showBanner(.success, "Your lock screen is ready.")
        }
    }

    /// Polls the (read-only) screen-saver choice for a few minutes so the UI confirms by itself.
    func watchForScreenSaverSelection() {
        selectionWatch?.cancel()
        selectionWatch = Task { [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.lockScreen.refresh(settings: self.settings.lockScreen, targetWallpaperTitle: self.library.wallpaper(self.lockScreenTargetID)?.title)
                if self.lockScreen.saverSelection == .selected {
                    self.showBanner(.success, "All set — your lock screen now plays “\(self.lockScreen.config?.title ?? "your video")”.")
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
            }
        }
    }

    /// Starts the screen saver, which locks the Mac immediately when the password is required immediately.
    func lockNow() {
        MacLockScreenSystem.startScreenSaver()
    }

    func setLockScreenEnabled(_ enabled: Bool) {
        settings.lockScreen.isEnabled = enabled
        if enabled {
            if !lockScreen.isSaverInstalled { installLockScreenSaver() }
            if lockScreenTargetID != nil { Task { await applyLockScreen() } }
        } else {
            lockScreen.clear()
        }
        refreshLockScreen()
    }

    func chooseLockScreenWallpaper(_ id: WallpaperID?, useDesktop: Bool) {
        settings.lockScreen.useDesktopWallpaper = useDesktop
        if !useDesktop { settings.lockScreen.wallpaperID = id }
        refreshLockScreen()
    }

    func lockScreenCompatibility(_ id: WallpaperID) -> LockScreenMediaCompatibility {
        guard let wallpaper = library.wallpaper(id) else { return .incompatible("This wallpaper is no longer in your library.") }
        return LockScreenMediaCompatibility.evaluate(wallpaper, availability: library.availabilityOf(id))
    }

    /// Prepares the lock-screen video. Reports success only after the service verified the written configuration.
    @discardableResult
    func applyLockScreen(quiet: Bool = false) async -> Bool {
        guard let id = lockScreenTargetID, var wallpaper = library.wallpaper(id) else {
            if !quiet { showBanner(.error, settings.lockScreen.useDesktopWallpaper
                ? "There is no live desktop wallpaper to use. Set one, or choose a specific wallpaper for the lock screen."
                : "Choose a wallpaper for the lock screen first.") }
            refreshLockScreen()
            return false
        }
        // On a fresh library, metadata may still be loading in the background; read it now if needed.
        if !wallpaper.hasMetadata, let url = library.mediaURL(for: id),
           let metadata = try? await MediaInspector().inspect(url) {
            wallpaper.duration = metadata.duration
            wallpaper.pixelWidth = metadata.pixelWidth
            wallpaper.pixelHeight = metadata.pixelHeight
            wallpaper.frameRate = metadata.frameRate
            wallpaper.codec = metadata.codec
            wallpaper.fileSize = metadata.fileSize
            library.update(wallpaper)
        }
        do {
            try lockScreen.apply(wallpaper, mediaURL: library.mediaURL(for: id), availability: library.availabilityOf(id),
                                 gravity: settings.videoGravity)
        } catch {
            log.log(.error, "lockscreen", error.localizedDescription)
            if !quiet { showBanner(.error, error.localizedDescription) }
            refreshLockScreen()
            return false
        }

        var stillPictureError: String?
        // A still picture would replace the Aerial wallpaper that plays the animated lock screen.
        if settings.lockScreen.setsStillSystemPicture, !isAerialOn, let url = library.mediaURL(for: id) {
            do {
                let frame = try await thumbnails.posterFrame(for: id, mediaURL: url, duration: wallpaper.duration)
                try lockScreen.setStillSystemPicture(frame)
            } catch {
                stillPictureError = error.localizedDescription
                log.log(.error, "lockscreen", "Still system picture failed: \(error.localizedDescription)")
            }
        }
        refreshLockScreen()
        followWallpaperOnAerial()
        if !quiet {
            if let stillPictureError {
                showBanner(.error, stillPictureError)
            } else if case .active = lockScreen.status {
                showBanner(.success, "“\(wallpaper.title)” will play while your Mac is locked.")
            } else {
                showBanner(.info, "“\(wallpaper.title)” is prepared. \(lockScreen.status.summary)")
            }
        }
        return true
    }

    /// In "same as desktop" mode the lock screen follows the main display's wallpaper.
    func followDesktopOnLockScreen() {
        followWallpaperOnAerial()
        guard settings.lockScreen.isEnabled, settings.lockScreen.useDesktopWallpaper,
              let target = lockScreenTargetID, target != lockScreen.config?.wallpaperID else { return }
        Task { await applyLockScreen(quiet: true) }
    }

    func installLockScreenSaver() {
        do {
            try lockScreen.installSaver()
            showBanner(.success, "Driftwall screen saver installed. \(MacLockScreenSystem.screenSaverSelectionInstructions)")
        } catch {
            showBanner(.error, error.localizedDescription)
        }
        refreshLockScreen()
    }

    func setLockScreenStillPicture(_ enabled: Bool) {
        guard !(enabled && isAerialOn) else { return }
        settings.lockScreen.setsStillSystemPicture = enabled
        if enabled, lockScreen.config != nil { Task { await applyLockScreen() } }
    }
}
