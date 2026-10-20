import AppKit
import DriftwallCore

/// User-facing actions. Views and menus call these; they never talk to services directly.
extension AppController {
    // MARK: - Applying wallpapers

    /// Applies a wallpaper to `target` (or the default target from Settings).
    func apply(_ id: WallpaperID, target: DisplayTarget? = nil, fromRotation: Bool = false) {
        guard let wallpaper = library.wallpaper(id) else { return }
        guard library.isAvailable(id) else {
            showBanner(.error, "“\(wallpaper.title)” can’t be applied because its video file is missing. Relink or remove it from the Library.")
            return
        }
        let connected = displays.displays
        guard !connected.isEmpty else {
            showBanner(.error, "No displays are available right now.")
            return
        }
        let target = target ?? settings.defaultTarget

        if target == .allDisplays {
            for display in connected { assignments.assign(id, to: display) }
            settings.mirrorWallpaperID = id
        } else {
            if settings.displayMode == .mirror {
                // Targeting one display leaves mirror mode; keep the other displays on what they showed.
                if let mirrored = settings.mirrorWallpaperID {
                    for display in connected { assignments.assign(mirrored, to: display) }
                }
                settings.displayMode = .perDisplay
            }
            for display in DisplayAssignmentResolver.targetDisplays(for: target, in: connected) {
                assignments.assign(id, to: display)
            }
        }
        library.recordApplied(id)
        reconcileDesktop()
        syncSystemWallpaperFrames()
        followDesktopOnLockScreen()
        if !fromRotation {
            log.log(.info, "wallpaper", "Applied “\(wallpaper.title)”")
        }
    }

    /// Stops the live wallpaper on one display (the system wallpaper becomes visible there).
    func clearWallpaper(displayID: String) {
        if settings.displayMode == .mirror {
            settings.displayMode = .perDisplay
            if let mirrored = settings.mirrorWallpaperID {
                for display in displays.displays where display.id != displayID { assignments.assign(mirrored, to: display) }
            }
        }
        assignments.clear(displayID: displayID)
        reconcileDesktop()
    }

    func clearAllWallpapers() {
        rotation.stop()
        for assignment in assignments.assignments { assignments.clear(displayID: assignment.displayID) }
        settings.mirrorWallpaperID = nil
        reconcileDesktop()
    }

    func forgetAssignment(displayID: String) {
        assignments.clear(displayID: displayID)
    }

    // MARK: - Playback control

    func togglePlayback() {
        settings.userPaused.toggle()
    }

    func nextWallpaper() {
        if rotation.isActive {
            rotation.next()
        } else {
            step(by: 1)
        }
    }

    func previousWallpaper() {
        if rotation.isActive {
            rotation.previous()
        } else {
            step(by: -1)
        }
    }

    /// Without an active playlist, Next/Previous walk through favorites (or the whole library).
    /// In per-display mode only the display under the pointer changes; in mirror mode every display does.
    private func step(by offset: Int) {
        let pool = (library.favoriteIDs.isEmpty ? library.popularWallpapers.map(\.id) : library.favoriteIDs).filter(library.isAvailable)
        guard !pool.isEmpty else {
            showBanner(.info, "Add some wallpapers first.")
            return
        }
        let display = settings.displayMode == .perDisplay ? activeDisplay : nil
        let current = display.flatMap { engine.surfaceStates[$0.id]?.wallpaperID } ?? currentWallpaper?.id
        let index = current.flatMap { pool.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        let next = ((index + offset) % pool.count + pool.count) % pool.count
        apply(pool[next], target: display.map { .display(id: $0.id) } ?? .allDisplays)
    }

    func startPlaylist(_ playlistID: String) {
        rotation.start(playlistID: playlistID)
        if let message = rotation.lastMessage { showBanner(.error, message) }
    }

    // MARK: - Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Videos"
        panel.prompt = "Import"
        panel.message = "Choose QuickTime (.mov), MPEG-4 (.mp4) or .m4v videos, or a folder containing them."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = MediaInspector.supportedTypes + [.folder]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls) }
    }

    /// Imports files (and supported files inside dropped folders, one level deep), sequentially so a
    /// large batch never decodes many videos at once.
    func importFiles(_ urls: [URL]) async {
        let files = Self.expand(urls)
        guard !files.isEmpty else {
            showBanner(.error, "No supported videos were found in the selection.")
            return
        }
        guard importProgress == nil else {
            showBanner(.info, "An import is already running.")
            return
        }
        var imported: [Wallpaper] = []
        var failures: [(String, String)] = []
        for (offset, url) in files.enumerated() {
            importProgress = ImportProgress(total: files.count, completed: offset, currentName: url.lastPathComponent)
            do {
                let wallpaper = try await importer.importFile(at: url, copyIntoLibrary: settings.copyImportsIntoLibrary, existing: library.wallpapers)
                library.add(wallpaper)
                imported.append(wallpaper)
                log.log(.info, "import", "Imported “\(wallpaper.title)” (\(wallpaper.resolutionText), \(wallpaper.durationText))")
                if let mediaURL = library.mediaURL(for: wallpaper.id) {
                    _ = await thumbnailLoader.image(for: wallpaper, mediaURL: mediaURL)
                }
            } catch {
                failures.append((url.lastPathComponent, error.localizedDescription))
                log.log(.warning, "import", "Import failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        importProgress = nil
        if failures.isEmpty {
            showBanner(.success, imported.count == 1 ? "Imported “\(imported[0].title)”." : "Imported \(imported.count) videos.")
        } else {
            importReport = ImportReport(imported: imported, failures: failures)
        }
        if imported.count == 1, failures.isEmpty {
            navigation.open(imported[0].id)
        }
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                result += children.filter { MediaInspector.supportedExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                // Unsupported files are passed through so the user gets a specific error for them.
                result.append(url)
            }
        }
        return result
    }

    // MARK: - Library maintenance

    /// Removes an imported wallpaper from the library. The original video is never deleted.
    func removeWallpaper(_ id: WallpaperID) {
        guard let wallpaper = library.wallpaper(id) else { return }
        let wasMirrored = settings.mirrorWallpaperID == id
        guard library.remove(id, ownedMediaDirectory: paths.mediaDirectory) else { return }
        if wasMirrored { settings.mirrorWallpaperID = nil }
        assignments.reload()
        rotation.playlistsChanged()
        thumbnailLoader.invalidate(id)
        Task { await thumbnails.removeCachedImages(for: id) }
        reconcileDesktop()
        if navigation.detailWallpaperID == id { navigation.detailWallpaperID = nil }
        showBanner(.info, "Removed “\(wallpaper.title)” from your library. The original file was not deleted.")
    }

    func presentRelinkPanel(for id: WallpaperID) {
        guard let wallpaper = library.wallpaper(id) else { return }
        let panel = NSOpenPanel()
        panel.title = "Locate “\(wallpaper.title)”"
        panel.prompt = "Relink"
        panel.allowedContentTypes = MediaInspector.supportedTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await library.relink(id, to: url)
                thumbnailLoader.invalidate(id)
                await thumbnails.removeCachedImages(for: id)
                thumbnailEpoch += 1
                reconcileDesktop()
                showBanner(.success, "“\(wallpaper.title)” now points to \(url.lastPathComponent).")
            } catch {
                showBanner(.error, error.localizedDescription)
            }
        }
    }

    func revealInFinder(_ id: WallpaperID) {
        guard let url = library.mediaURL(for: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func rescanLibrary() {
        library.refreshAvailability()
        reconcileDesktop()
        let missing = library.missingWallpapers.count
        showBanner(missing == 0 ? .success : .info, missing == 0 ? "All wallpaper files are available." : "\(missing) wallpaper file(s) are missing.")
    }

    func removeAllMissing() {
        for wallpaper in library.missingWallpapers where wallpaper.source == .imported {
            removeWallpaper(wallpaper.id)
        }
    }

    func clearThumbnailCache() async {
        await thumbnails.clearCache()
        thumbnailLoader.clearMemory()
        thumbnailEpoch += 1
        showBanner(.success, "Cleared cached previews. They will be regenerated as needed.")
    }

    func deletePlaylist(_ id: String) {
        library.deletePlaylist(id)
        rotation.playlistsChanged()
        if case .playlist(id) = navigation.selection { navigation.selection = .playlists }
    }

    func playlistEdited() {
        rotation.playlistsChanged()
    }
}
