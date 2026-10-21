import DriftwallCore
import SwiftUI

/// "My Videos": everything the user imported, plus recovery for missing files.
struct LibraryView: View {
    @Environment(AppController.self) private var app
    @State private var confirmRemoveMissing = false

    var body: some View {
        let imported = app.library.importedWallpapers
        let missing = imported.filter { !app.library.isAvailable($0.id) }
        let available = imported.filter { app.library.isAvailable($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "My Videos", subtitle: subtitle(imported.count)) {
                    HStack(spacing: Theme.Space.s) {
                        Button("Check Files") { app.rescanLibrary() }
                            .help("Look for moved or missing video files")
                        Button("Import Videos…") { app.presentImportPanel() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if !missing.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        InlineNotice(kind: .warning, title: "\(missing.count) video\(missing.count == 1 ? "" : "s") can’t be found",
                                     message: "The files were moved to another volume, renamed outside Finder, deleted, or are on a disconnected drive. Reconnect the drive and choose Check Files, or locate each file.") {
                            Button("Remove All Missing…") { confirmRemoveMissing = true }
                        }
                        ForEach(missing) { wallpaper in
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "questionmark.folder").foregroundStyle(.secondary)
                                Text(wallpaper.title).font(.callout.weight(.medium))
                                Text(wallpaper.mediaPath).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Locate…") { app.presentRelinkPanel(for: wallpaper.id) }
                                Button("Remove") { app.removeWallpaper(wallpaper.id) }
                            }
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, 6)
                            Divider().padding(.leading, Theme.Space.m)
                        }
                    }
                }

                if imported.isEmpty {
                    DropZone()
                } else if !available.isEmpty {
                    WallpaperGrid(wallpapers: available)
                }
            }
            .padding(Theme.Space.page)
        }
        .background(Theme.background)
        .navigationTitle("My Videos")
        .confirmationDialog("Remove all missing videos from the library?", isPresented: $confirmRemoveMissing) {
            Button("Remove \(missing.count) Item\(missing.count == 1 ? "" : "s")", role: .destructive) { app.removeAllMissing() }
        } message: {
            Text("Only the library entries are removed. No files are deleted.")
        }
    }

    private func subtitle(_ count: Int) -> String {
        let mode = app.settings.copyImportsIntoLibrary ? "Imports are copied into Driftwall’s library folder." : "Imports are referenced in place; originals are never moved or deleted."
        return "\(count) imported · \(mode)"
    }
}

private struct DropZone: View {
    @Environment(AppController.self) private var app

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.secondaryText.opacity(0.75))
            Text("Drop videos here")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("QuickTime (.mov), MPEG-4 (.mp4) and .m4v videos, or folders containing them.\nH.264, HEVC and ProRes play with hardware decoding on Apple silicon.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
            Button("Choose Videos…") { app.presentImportPanel() }
                .buttonStyle(.borderedProminent)
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(Theme.Space.xl)
        .background(Theme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
            .strokeBorder(Theme.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
