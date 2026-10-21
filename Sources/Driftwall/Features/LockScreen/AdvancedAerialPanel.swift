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
                if app.aerialSetupStep == nil, !service.isBusy, let modified = app.aerialModifiedSlots, !modified.isEmpty {
                    modifiedAerialsView(modified)
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
        .task {
            if app.aerialModifiedSlots == nil { await app.checkAerials() }
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
                case .addingToDisplays(let aerial, let displays):
                    Text("Now choose “\(aerial)” on \(displayList(displays)) too.").font(.callout.weight(.medium))
                }
            }
            Text(stepDetail(step))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !isDownloading(step) {
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
                StatusLabel(kind: .warning, text: "macOS put Apple’s “\(manifest.slotName)” video back. Driftwall puts yours back automatically once macOS has finished downloading it.")
            } else if let missing = app.aerialMissingDisplays, !missing.isEmpty {
                let total = app.displays.displays.count
                StatusLabel(kind: .warning, text: missing.count == total
                            ? "“\(manifest.slotName)” isn’t your wallpaper right now, so the lock screen doesn’t play your video."
                            : "Not playing on \(displayList(missing.map(\.name))): that display shows another wallpaper.")
                Button(missing.count == total ? "Choose “\(manifest.slotName)” in Wallpaper Settings" : "Fix in Wallpaper Settings") {
                    app.chooseAerialOnRemainingDisplays()
                }
            } else {
                StatusLabel(kind: .live, text: "On: your lock screen plays “\(manifest.wallpaperTitle)”.")
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
            if app.aerialRestoreNeedsDownload {
                Text("No copy of Apple’s original “\(manifest.slotName)” is left on this Mac. Turning off removes your video instead, and macOS downloads Apple’s original again when it’s next shown.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Turn Off and Download Apple’s Original") { app.turnOffAndRedownloadAerial() }
            }
        }
    }

    /// Aerials whose video was changed outside Driftwall's install (by hand, or by an older version):
    /// they would show the wrong video, and Driftwall won't back them up as originals.
    private func modifiedAerialsView(_ modified: [AerialSlot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusLabel(kind: .warning, text: modified.count == 1
                        ? "The Aerial “\(modified[0].name)” doesn’t contain Apple’s original video."
                        : "\(modified.count) Aerials don’t contain Apple’s original video.")
            Text("They were changed outside Driftwall’s install, for example by an older version. Repair puts Apple’s original back: from a copy on this Mac when there is one, otherwise macOS downloads it again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(modified) { slot in
                HStack {
                    Text(slot.name).font(.callout)
                    Spacer()
                    Button("Repair") { Task { await app.repairAerial(slot) } }
                }
            }
        }
    }

    private func displayList(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })
    }

    private func isDownloading(_ step: AerialSetupStep) -> Bool {
        if case .downloading = step { return true }
        return false
    }

    private func stepDetail(_ step: AerialSetupStep) -> String {
        switch step {
        case .choosingAerial:
            return "Driftwall continues by itself as soon as you’ve clicked one."
        case .downloading:
            return "Aerials are a few hundred megabytes. Driftwall continues by itself when the download finishes."
        case .addingToDisplays:
            return "Each display has its own wallpaper, and only displays showing the Aerial play the video on the lock screen. In Wallpaper settings, pick the display, click the Aerial, and turn on “Show on all Spaces” so it stays when you switch Spaces. Driftwall notices by itself."
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
                Button("Check Apple’s Aerials") { Task { await app.checkAerials() } }
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
