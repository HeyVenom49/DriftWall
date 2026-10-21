import DriftwallCore
import SwiftUI

/// Animated lock screen: plays the wallpaper as one of Apple's Aerials, which macOS animates on the
/// lock screen itself (including behind the password prompt). One button sets it up; the manual
/// choices are under Options.
struct AdvancedAerialPanel: View {
    @Environment(AppController.self) private var app
    @State private var showOptions = false
    @State private var wallpaperID: WallpaperID?
    @State private var slotID: String?
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
                            Badge(text: "BETA")
                        }
                        Text("Plays your wallpaper on the lock screen itself, even behind the password prompt, by showing it as one of Apple’s Aerial wallpapers.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                if let step = app.aerialSetupStep {
                    setupProgress(step)
                } else if let phase = service.phase {
                    busy(phase, progress: service.progress)
                } else {
                    switch service.status {
                    case .installed(let manifest), .replacedByMacOS(let manifest):
                        onView(manifest, replaced: service.status != .installed(manifest))
                    case .notInstalled, .unavailable:
                        offView()
                    }
                }
                if app.aerialSetupStep == nil, !service.isBusy {
                    DisclosureGroup("Options", isExpanded: $showOptions) { options(service) }
                        .font(.callout)
                }
            }
        }
        .onAppear {
            app.refreshAerial()
            if wallpaperID == nil { wallpaperID = app.aerialTargetID }
        }
        .confirmationDialog("Turn off the animated lock screen?", isPresented: $confirmRestore) {
            Button("Turn Off") { Task { await app.restoreAerial() } }
        } message: {
            Text("Apple’s original Aerial video comes back. Your wallpaper choice in System Settings stays as it is.")
        }
    }

    // MARK: - States

    private func offView() -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Button("Turn On Animated Lock Screen") { app.turnOnAnimatedLockScreen() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(app.aerialTargetID == nil)
                if let title = app.library.wallpaper(app.aerialTargetID)?.title {
                    Text("Plays “\(title)”").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(app.aerialTargetID == nil
                 ? "Set a live wallpaper first. The animated lock screen plays your current wallpaper."
                 : "If no Aerial is your wallpaper yet, Driftwall opens Wallpaper settings: click any Aerial and Driftwall does the rest. Converting takes about a minute.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupProgress(_ step: AerialSetupStep) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                switch step {
                case .choosingAerial:
                    Text("In Wallpaper settings, click any Aerial (for example one under “Landscape”).")
                        .font(.callout.weight(.medium))
                case .downloading(let name):
                    Text("macOS is downloading “\(name)”…").font(.callout.weight(.medium))
                }
            }
            Text(step == .choosingAerial
                 ? "Driftwall continues by itself as soon as you’ve clicked one."
                 : "Aerials are a few hundred megabytes. Driftwall continues by itself when the download finishes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if step == .choosingAerial {
                    Button("Open Wallpaper Settings") { AerialWallpaperSelection.openWallpaperSettings() }
                }
                Button("Cancel") { app.cancelAnimatedLockScreenSetup() }
            }
        }
    }

    private func busy(_ phase: String, progress: Double?) -> some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress).frame(width: 160)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(phase).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func onView(_ manifest: AerialInstallManifest, replaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if replaced {
                Label("macOS put Apple’s “\(manifest.slotName)” video back. Driftwall puts yours back automatically once macOS has finished downloading it.",
                      systemImage: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
            } else if app.aerialSelectedAsWallpaper == false {
                Label("“\(manifest.slotName)” isn’t your wallpaper right now, so the lock screen doesn’t play your video.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Choose “\(manifest.slotName)” in Wallpaper Settings") {
                    AerialWallpaperSelection.openWallpaperSettings()
                    app.watchForAerialSelection()
                }
            } else {
                Label("On: your lock screen plays “\(manifest.wallpaperTitle)”.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.live)
            }
            Text(manifest.followsWallpaper == true
                 ? "It follows your lock-screen wallpaper: when that changes, Driftwall updates it in the background."
                 : "Shown as Apple’s “\(manifest.slotName)” Aerial.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if manifest.followsWallpaper == true, let target = app.aerialTargetID, target != manifest.wallpaperID {
                    Button("Update Now") { app.followWallpaperOnAerial() }
                }
                Button("Turn Off…") { confirmRestore = true }
            }
        }
    }

    // MARK: - Options

    private func options(_ service: AerialLockScreenService) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Picker("Video", selection: $wallpaperID) {
                ForEach(app.library.search(SearchQuery(sort: .title)).filter { app.library.isAvailable($0.id) }) { wallpaper in
                    Text(wallpaper.title).tag(WallpaperID?.some(wallpaper.id))
                }
            }
            if service.slots.isEmpty {
                Text("No Aerial is downloaded yet. Turn On downloads one for you, or choose any Aerial in Wallpaper settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Apple Aerial to use", selection: Binding(get: { slotID ?? service.manifest?.slotID ?? service.slots.first?.id }, set: { slotID = $0 })) {
                    ForEach(service.slots) { slot in
                        Text(slot.name).tag(String?.some(slot.id))
                    }
                }
            }
            Text("Choosing a video other than your lock-screen wallpaper keeps that video until you change it here. Its name and thumbnail in System Settings stay Apple’s.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Install") {
                    guard let wallpaperID, let slot = selectedSlot else { return }
                    let follows = wallpaperID == app.aerialTargetID
                    Task { await app.installAerial(wallpaperID: wallpaperID, slot: slot, followsWallpaper: follows) }
                }
                .disabled(wallpaperID == nil || selectedSlot == nil)
            }
        }
        .padding(.top, 6)
    }

    private var selectedSlot: AerialSlot? {
        let slots = app.aerial.slots
        let id = slotID ?? app.aerial.manifest?.slotID
        return slots.first { $0.id == id } ?? slots.first
    }
}
