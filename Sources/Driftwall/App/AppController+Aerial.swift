import AppKit
import DriftwallCore

/// Advanced lock screen: user-approved replacement of one Apple Aerial video (see AerialLockScreenService).
extension AppController {
    func refreshAerial() {
        aerial.refresh()
        if let id = aerial.manifest?.slotID {
            aerialSelectedAsWallpaper = AerialWallpaperSelection.isSelectedAsWallpaper(id)
        } else {
            aerialSelectedAsWallpaper = nil
        }
    }

    func installAerial(wallpaperID: WallpaperID, slot: AerialSlot) async {
        guard let wallpaper = library.wallpaper(wallpaperID), let url = library.mediaURL(for: wallpaperID) else {
            showBanner(.error, "That wallpaper’s video file can’t be found.")
            return
        }
        do {
            try await aerial.install(wallpaper: wallpaper, mediaURL: url, slot: slot)
        } catch AerialError.cancelled {
            showBanner(.info, AerialError.cancelled.localizedDescription)
            refreshAerial()
            return
        } catch {
            log.log(.error, "aerial", error.localizedDescription)
            showBanner(.error, error.localizedDescription)
            refreshAerial()
            return
        }
        refreshAerial()
        if aerialSelectedAsWallpaper == true {
            showBanner(.success, "Done. “\(slot.name)” now shows “\(wallpaper.title)” on your lock screen.")
        } else {
            showBanner(.success, "Installed. Now choose the “\(slot.name)” Aerial in Wallpaper settings.")
            AerialWallpaperSelection.openWallpaperSettings()
            watchForAerialSelection()
        }
    }

    func restoreAerial() async {
        do {
            try await aerial.restore()
            showBanner(.success, "Apple’s original Aerial video is back.")
        } catch AerialError.cancelled {
            showBanner(.info, AerialError.cancelled.localizedDescription)
        } catch {
            showBanner(.error, error.localizedDescription)
        }
        refreshAerial()
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
