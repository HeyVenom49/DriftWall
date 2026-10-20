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
                    HStack {
                        Button("Check Files") { app.rescanLibrary() }
                            .help("Look for moved or missing video files")
                        Button("Import Videos…") { app.presentImportPanel() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if !missing.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            HStack {
                                Label("\(missing.count) video\(missing.count == 1 ? "" : "s") can’t be found", systemImage: "exclamationmark.triangle.fill")
                                    .font(.headline)
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Remove All Missing…") { confirmRemoveMissing = true }
                            }
                            Text("The files were moved to another volume, renamed outside Finder, deleted, or are on a disconnected drive. Reconnect the drive and choose Check Files, or locate each file.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(missing) { wallpaper in
                                HStack {
                                    Text(wallpaper.title).font(.callout.weight(.medium))
                                    Text(wallpaper.mediaPath).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button("Locate…") { app.presentRelinkPanel(for: wallpaper.id) }
                                    Button("Remove") { app.removeWallpaper(wallpaper.id) }
                                }
                            }
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
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Drop videos here").font(.title3.weight(.semibold))
            Text("QuickTime (.mov), MPEG-4 (.mp4) and .m4v videos, or folders containing them.\nH.264, HEVC and ProRes play with hardware decoding on Apple silicon.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose Videos…") { app.presentImportPanel() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
            .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }
}
