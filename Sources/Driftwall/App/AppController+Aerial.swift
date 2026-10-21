import AppKit
import DriftwallCore

/// What one-click animated lock-screen setup is waiting for.
enum AerialSetupStep: Equatable {
    /// The user hasn't chosen an Aerial as wallpaper yet; Wallpaper settings is open.
    case choosingAerial
    /// An Aerial is chosen and macOS is downloading it.
    case downloading(name: String)
}

/// Animated lock screen: replaces the user's copy of one Apple Aerial video (see AerialLockScreenService).
extension AppController {
    /// The animated lock screen shows the lock-screen wallpaper when that is set up, otherwise the
    /// main display's wallpaper.
    var aerialTargetID: WallpaperID? {
        lockScreenTargetID ?? currentWallpaper?.id
    }

    var isAerialOn: Bool { aerial.manifest != nil }

    func refreshAerial() {
        aerial.refresh()
        if let id = aerial.manifest?.slotID {
            aerialSelectedAsWallpaper = AerialWallpaperSelection.isSelectedAsWallpaper(id)
        } else {
            aerialSelectedAsWallpaper = nil
        }
    }

    // MARK: - One-click setup

    /// Turns the animated lock screen on with the current wallpaper. Uses the Aerial already chosen as
    /// wallpaper, or opens Wallpaper settings and continues by itself once the user clicks any Aerial
    /// and macOS has downloaded it. The only thing the user does outside Driftwall is that one click.
    func turnOnAnimatedLockScreen() {
        guard let target = aerialTargetID, library.wallpaper(target) != nil, library.mediaURL(for: target) != nil else {
            showBanner(.error, "Set a live wallpaper first. The animated lock screen plays your current wallpaper.")
            return
        }
        stopStillSystemPictures()
        aerialSetupTask?.cancel()
        aerialSetupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.aerialSetupStep = nil }
            guard let slot = await self.waitForChosenAerial() else { return }
            guard let target = self.aerialTargetID else { return }
            if await self.installAerial(wallpaperID: target, slot: slot, followsWallpaper: true, quiet: true) {
                self.showBanner(.success, "Your lock screen now plays “\(self.library.wallpaper(target)?.title ?? "your wallpaper")”. Lock your Mac to see it.")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func cancelAnimatedLockScreenSetup() {
        aerialSetupTask?.cancel()
        aerialSetupTask = nil
        aerialSetupStep = nil
    }

    /// Waits (up to 15 minutes) until an Aerial is chosen as a desktop wallpaper and fully downloaded.
    /// Opens Wallpaper settings only if none is chosen yet. A file counts once its size stops changing.
    private func waitForChosenAerial() async -> AerialSlot? {
        var openedSettings = false
        var previous: AerialSlot?
        for _ in 0..<450 {
            if Task.isCancelled { return nil }
            refreshAerial()
            let names = aerial.reader.assetNames()
            let known = Set(names.keys).union(aerial.slots.map(\.id))
            let chosen = AerialWallpaperStore.selectedAssetIDs(among: known) ?? []
            // Prefer an Aerial Driftwall already replaced, so switching videos doesn't touch a second one.
            let downloaded = aerial.slots.filter { chosen.contains($0.id) }
            let candidate = downloaded.first { $0.id == aerial.manifest?.slotID } ?? downloaded.first
            if let candidate, candidate == previous { return candidate }
            previous = candidate
            if candidate != nil || !chosen.isEmpty {
                let name = candidate?.name ?? chosen.compactMap { names[$0] }.first ?? "the Aerial"
                aerialSetupStep = .downloading(name: name)
            } else {
                aerialSetupStep = .choosingAerial
                if !openedSettings {
                    openedSettings = true
                    AerialWallpaperSelection.openWallpaperSettings()
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if !Task.isCancelled {
            showBanner(.error, "No downloaded Aerial wallpaper was found. Choose one in Wallpaper settings, then try again.")
        }
        return nil
    }

    /// A still macOS wallpaper replaces the Aerial and with it the animated lock screen, so both
    /// still-picture options are turned off (and stay unavailable while the animated lock screen is on).
    private func stopStillSystemPictures() {
        settings.lockScreen.setsStillSystemPicture = false
        settings.syncSystemWallpaper = false
    }

    // MARK: - Install, follow, restore

    @discardableResult
    func installAerial(wallpaperID: WallpaperID, slot: AerialSlot, followsWallpaper: Bool, quiet: Bool = false) async -> Bool {
        guard let wallpaper = library.wallpaper(wallpaperID), let url = library.mediaURL(for: wallpaperID) else {
            showBanner(.error, "That wallpaper’s video file can’t be found.")
            return false
        }
        stopStillSystemPictures()
        do {
            try await aerial.install(wallpaper: wallpaper, mediaURL: url, slot: slot, followsWallpaper: followsWallpaper)
        } catch {
            log.log(.error, "aerial", error.localizedDescription)
            showBanner(.error, error.localizedDescription)
            refreshAerial()
            return false
        }
        refreshAerial()
        if !quiet {
            if aerialSelectedAsWallpaper == true {
                showBanner(.success, "Done. Your lock screen now plays “\(wallpaper.title)”.")
            } else {
                showBanner(.success, "Installed. Now click the “\(slot.name)” Aerial in Wallpaper settings.")
                AerialWallpaperSelection.openWallpaperSettings()
                watchForAerialSelection()
            }
        }
        // The wallpaper may have changed again while this one was converting.
        followWallpaperOnAerial()
        return true
    }

    /// When the lock-screen wallpaper changes, converts the new one into the same Aerial in the
    /// background. Changes made during a conversion are picked up when it finishes.
    func followWallpaperOnAerial() {
        guard let manifest = aerial.manifest, manifest.followsWallpaper == true, !aerial.isBusy, aerialSetupStep == nil,
              let target = aerialTargetID, target != manifest.wallpaperID, library.mediaURL(for: target) != nil else { return }
        aerial.refresh()
        guard let slot = aerial.slots.first(where: { $0.id == manifest.slotID }) else { return }
        log.log(.info, "aerial", "Lock-screen wallpaper changed; updating the Aerial")
        Task { await installAerial(wallpaperID: target, slot: slot, followsWallpaper: true, quiet: true) }
    }

    func restoreAerial() async {
        cancelAnimatedLockScreenSetup()
        do {
            try await aerial.restore()
            showBanner(.success, "Animated lock screen turned off. Apple’s original Aerial is back.")
        } catch {
            showBanner(.error, error.localizedDescription)
        }
        refreshAerial()
    }

    /// macOS downloads Apple's Aerial again now and then (for example after an update or when the
    /// catalog changes). Checks at launch and every 5 minutes, and puts the video back when it has.
    func startAerialKeeper() {
        aerialKeeper?.cancel()
        aerialKeeper = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    if try await self.aerial.reapplyIfReplaced() { self.refreshAerial() }
                } catch {
                    self.log.log(.error, "aerial", "Couldn’t re-apply the Aerial video: \(error.localizedDescription)")
                }
                self.followWallpaperOnAerial()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Polls the read-only wallpaper store until the user picks the replaced Aerial (up to 5 minutes).
    func watchForAerialSelection() {
        aerialWatch?.cancel()
        aerialWatch = Task { [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, let id = self.aerial.manifest?.slotID else { return }
                if AerialWallpaperSelection.isSelectedAsWallpaper(id) == true {
                    self.aerialSelectedAsWallpaper = true
                    self.showBanner(.success, "All set. Your lock screen now plays your video.")
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
            }
        }
    }
}
