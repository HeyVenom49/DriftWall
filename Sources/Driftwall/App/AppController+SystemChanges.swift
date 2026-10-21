import AppKit
import DriftwallCore

/// Things Driftwall changes outside its own folders, the cleanup task that undoes them if the app is
/// deleted, and undoing them on request.
extension AppController {
    var originalDesktopPicturesURL: URL { OriginalDesktopPictures.url(in: paths.supportDirectory) }

    /// The system changes in place right now, in words.
    var systemChanges: [String] {
        var changes: [String] = []
        if let manifest = aerial.manifest {
            changes.append("Animated Lock Screen: your copy of Apple’s “\(manifest.slotName)” Aerial plays “\(manifest.wallpaperTitle)”.")
        }
        if FileManager.default.fileExists(atPath: lockScreenSystem.installedSaverURL.path) {
            changes.append("Screen Saver Video: Driftwall’s screen saver is installed in ~/Library/Screen Savers.")
        }
        let pictures = OriginalDesktopPictures.load(from: originalDesktopPicturesURL).displays.count
        if pictures > 0 {
            changes.append("The macOS desktop picture was replaced with a still frame on \(pictures) display\(pictures == 1 ? "" : "s").")
        }
        if settings.launchAtLogin {
            changes.append("Driftwall opens at login.")
        }
        return changes
    }

    /// Installs the cleanup task while any change it can undo is in place, removes it otherwise.
    func refreshCleanupAgent() {
        let needed = aerial.manifest != nil
            || FileManager.default.fileExists(atPath: lockScreenSystem.installedSaverURL.path)
            || FileManager.default.fileExists(atPath: originalDesktopPicturesURL.path)
        CleanupAgentService.update(needed: needed, agent: CleanupAgentService.agent(
            paths: paths, aerialVideoDirectory: aerial.reader.videoDirectory, screenSaverPath: lockScreenSystem.installedSaverURL))
    }

    /// Remembers the display's current desktop picture before Driftwall replaces it for the first time.
    func recordOriginalDesktopPicture(for screen: NSScreen) {
        guard let id = DisplayService.directID(of: screen).map(DisplayService.uuidString(for:)) else { return }
        var originals = OriginalDesktopPictures.load(from: originalDesktopPicturesURL)
        let recorded = originals.recordIfNeeded(displayID: id, name: screen.localizedName,
                                                picture: NSWorkspace.shared.desktopImageURL(for: screen),
                                                driftwallFramesDirectory: paths.cacheDirectory.appendingPathComponent("Frames", isDirectory: true))
        if recorded { try? originals.save(to: originalDesktopPicturesURL) }
    }

    /// Puts back everything Driftwall changed outside its own folders. The library, favorites and
    /// playlists stay. Returns what couldn't be undone.
    @discardableResult
    func undoAllSystemChanges() async -> [String] {
        var problems: [String] = []
        cancelAnimatedLockScreenSetup()

        // Animated Lock Screen.
        if aerial.manifest != nil {
            do {
                try await aerial.restore()
            } catch AerialError.backupMissing {
                do { try aerial.removeAndRedownload() } catch { problems.append("Animated Lock Screen: \(error.localizedDescription)") }
            } catch {
                problems.append("Animated Lock Screen: \(error.localizedDescription)")
            }
        }

        // Screen Saver Video.
        if settings.lockScreen.isEnabled { setLockScreenEnabled(false) }
        lockScreen.clear()
        if FileManager.default.fileExists(atPath: lockScreenSystem.installedSaverURL.path) {
            do { try lockScreen.uninstallSaver() } catch { problems.append("Screen saver: \(error.localizedDescription)") }
        }

        // Desktop pictures: stop replacing them, then put the originals back.
        settings.syncSystemWallpaper = false
        settings.lockScreen.setsStillSystemPicture = false
        let originals = OriginalDesktopPictures.load(from: originalDesktopPicturesURL)
        var unrestored = OriginalDesktopPictures()
        for (id, entry) in originals.displays {
            guard let display = displays.display(id: id), let screen = displays.screen(for: display) else {
                unrestored.displays[id] = entry   // not connected now; kept for later
                continue
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: entry.path), for: screen, options: [:])
            } catch {
                unrestored.displays[id] = entry
                problems.append("Desktop picture on \(entry.name): \(error.localizedDescription)")
            }
        }
        if unrestored.displays.isEmpty {
            try? FileManager.default.removeItem(at: originalDesktopPicturesURL)
        } else {
            try? unrestored.save(to: originalDesktopPicturesURL)
            let names = unrestored.displays.values.map(\.name).joined(separator: ", ")
            if !problems.contains(where: { $0.hasPrefix("Desktop picture") }) {
                problems.append("Desktop picture on \(names): that display isn’t connected; it’s restored when you undo again with it connected.")
            }
        }

        // Login item.
        if settings.launchAtLogin { settings.launchAtLogin = false }

        refreshAerial()
        refreshLockScreen()
        refreshCleanupAgent()
        log.log(problems.isEmpty ? .info : .warning, "cleanup", problems.isEmpty ? "Undid all system changes" : "Undid system changes with problems: \(problems.joined(separator: "; "))")
        showBanner(problems.isEmpty ? .success : .error,
                   problems.isEmpty ? "Everything Driftwall changed outside its own folders is back to how it was."
                                    : "Some changes couldn’t be undone: \(problems.joined(separator: " "))")
        return problems
    }
}
