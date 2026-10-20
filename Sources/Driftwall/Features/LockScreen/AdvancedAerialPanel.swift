import DriftwallCore
import SwiftUI

/// Advanced mode: plays a Driftwall video as an Apple Aerial, which macOS animates on the lock screen
/// itself (including behind the password prompt). Requires the user's administrator password.
struct AdvancedAerialPanel: View {
    @Environment(AppController.self) private var app
    @State private var expanded = false
    @State private var wallpaperID: WallpaperID?
    @State private var slotID: String?
    @State private var confirmInstall = false
    @State private var confirmRestore = false

    var body: some View {
        let service = app.aerial
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top) {
                    Image(systemName: "sparkles.tv").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Animated lock screen").font(.headline)
                            Badge(text: "ADVANCED")
                        }
                        Text("Shows your video as one of Apple’s Aerial wallpapers, which macOS animates on the lock screen itself, even behind the password prompt.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(expanded ? "Hide" : "Show") { withAnimation { expanded.toggle() } }
                }

                if expanded || service.isBusy || isInstalled(service.status) {
                    Divider()
                    content(service)
                }
            }
        }
        .onAppear {
            app.refreshAerial()
            if wallpaperID == nil { wallpaperID = app.lockScreenTargetID ?? app.currentWallpaper?.id }
        }
        .confirmationDialog("Replace an Apple Aerial with your video?", isPresented: $confirmInstall) {
            Button("Continue (asks for your password)") { startInstall() }
        } message: {
            Text("""
            Driftwall will convert your video, back up Apple’s original “\(selectedSlot?.name ?? "Aerial")” video, and then replace it. macOS asks for your administrator password.

            Only that one video file changes. You can restore Apple’s original at any time, and a macOS update may put it back on its own.
            """)
        }
        .confirmationDialog("Restore Apple’s original Aerial?", isPresented: $confirmRestore) {
            Button("Restore (asks for your password)") { Task { await app.restoreAerial() } }
        }
    }

    @ViewBuilder
    private func content(_ service: AerialLockScreenService) -> some View {
        switch service.status {
        case .unavailable(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .installed(let manifest):
            installedView(manifest)
        case .replacedByMacOS(let manifest):
            VStack(alignment: .leading, spacing: 8) {
                Label("macOS put Apple’s “\(manifest.slotName)” video back (probably after an update). Your lock screen shows Apple’s Aerial again.",
                      systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Install Again…") { confirmInstall = true }.disabled(selectedSlot == nil)
                    Button("Dismiss") { service.forgetReplacedInstall() }
                }
            }
            chooser(service)
        case .notInstalled:
            chooser(service)
        }
        if let phase = service.phase {
            HStack(spacing: 8) {
                if let progress = service.progress {
                    ProgressView(value: progress).frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(phase).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func installedView(_ manifest: AerialInstallManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Apple’s “\(manifest.slotName)” Aerial now plays “\(manifest.wallpaperTitle)”.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.live)
            if app.aerialSelectedAsWallpaper == true {
                Text("It’s your wallpaper, so it plays on the lock screen.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Last step: in Wallpaper settings, choose the “\(manifest.slotName)” Aerial.")
                        .font(.callout)
                    Button("Open Wallpaper Settings") {
                        AerialWallpaperSelection.openWallpaperSettings()
                        app.watchForAerialSelection()
                    }
                }
            }
            Button("Restore Apple’s Original…") { confirmRestore = true }
                .disabled(app.aerial.isBusy)
            if expanded {
                Divider()
                Text("Use a different video:").font(.callout.weight(.medium))
                chooser(app.aerial)
            }
        }
    }

    private func chooser(_ service: AerialLockScreenService) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Picker("Video", selection: $wallpaperID) {
                ForEach(app.library.search(SearchQuery(sort: .title)).filter { app.library.isAvailable($0.id) }) { wallpaper in
                    Text(wallpaper.title).tag(WallpaperID?.some(wallpaper.id))
                }
            }
            Picker("Replace Apple’s Aerial", selection: Binding(get: { slotID ?? service.slots.first?.id }, set: { slotID = $0 })) {
                ForEach(service.slots) { slot in
                    Text("\(slot.name) (\(slot.fileSize.formattedBytes))").tag(String?.some(slot.id))
                }
            }
            if service.slots.isEmpty, case .notInstalled = service.status {
                Text("No Aerials are downloaded on this Mac yet. Choose any Aerial in Wallpaper settings once so macOS downloads it, then come back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Only Aerials already downloaded on this Mac can be used. Pick one you don’t mind seeing replaced; its name and thumbnail in System Settings stay Apple’s.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Install as Aerial…") { confirmInstall = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(wallpaperID == nil || selectedSlot == nil || service.isBusy)
            }
        }
    }

    private var selectedSlot: AerialSlot? {
        let slots = app.aerial.slots
        if let slotID { return slots.first { $0.id == slotID } }
        return slots.first
    }

    private func isInstalled(_ status: AerialStatus) -> Bool {
        if case .installed = status { return true }
        if case .replacedByMacOS = status { return true }
        return false
    }

    private func startInstall() {
        guard let wallpaperID, let slot = selectedSlot else { return }
        Task { await app.installAerial(wallpaperID: wallpaperID, slot: slot) }
    }
}
