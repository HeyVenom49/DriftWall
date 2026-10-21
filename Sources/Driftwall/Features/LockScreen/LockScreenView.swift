import DriftwallCore
import SwiftUI

struct LockScreenView: View {
    @Environment(AppController.self) private var app
    @State private var preview = PreviewPlayer()
    @State private var confirmTest = false
    @State private var isApplying = false

    var body: some View {
        let lock = app.settings.lockScreen
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                PageHeader(title: "Lock Screen",
                           subtitle: "Two ways to show your wallpaper while your Mac is locked. Use either or both; what’s possible depends on your macOS version.")

                // Option 1: the Aerial-based animated lock screen.
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    optionHeader(title: "Animated Lock Screen", badge: "BETA",
                                 summary: "Your wallpaper plays on the lock screen itself, behind the password prompt, as one of Apple’s Aerial wallpapers. It replaces your own copy of one Aerial; Apple’s original is backed up, and no administrator password is needed.")
                    AdvancedAerialPanel()
                }

                Divider().opacity(0.55)

                // Option 2: the screen-saver module.
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .firstTextBaseline) {
                        optionHeader(title: "Screen Saver Video", badge: nil,
                                     summary: "Plays full screen while the screen saver runs after the Mac locks. The password prompt itself appears over a still picture — not live video.")
                        Spacer()
                        if lock.isEnabled {
                            Toggle("On", isOn: Binding(get: { lock.isEnabled }, set: { app.setLockScreenEnabled($0) }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .help("Turn the screen saver video off or on")
                        }
                    }
                    if !app.lockScreen.isSupported {
                        InlineNotice(kind: .warning, title: "Not available on this Mac",
                                     message: app.lockScreen.capabilities.videoWhileLocked.detail)
                    } else if app.isLockScreenReady {
                        ReadyRow()
                    } else {
                        SetupCard()
                    }
                    if lock.isEnabled && app.lockScreen.isSupported {
                        sourcePanel(lock)
                        DisclosureGroup("Setup Checklist and Still Picture") {
                            VStack(alignment: .leading, spacing: Theme.Space.l) {
                                SetupPanel(confirmTest: $confirmTest)
                                stillPicturePanel(lock)
                            }
                            .padding(.top, Theme.Space.m)
                        }
                    }
                }

                DisclosureGroup("What macOS Allows") {
                    CapabilityPanel(capabilities: app.lockScreen.capabilities, aerialAvailable: aerialAvailable)
                        .padding(.top, Theme.Space.m)
                }
            }
            .padding(Theme.Space.page)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle("Lock Screen")
        .onAppear { app.refreshLockScreen() }
        .onDisappear { preview.stop() }
        .confirmationDialog("Start the screen saver now?", isPresented: $confirmTest) {
            Button("Start Screen Saver") { MacLockScreenSystem.startScreenSaver() }
        } message: {
            Text(app.passwordDelay == "delay is immediate"
                 ? "Your Mac requires the password immediately, so this locks it. Move the mouse or press a key, then enter your password to come back."
                 : "The screen saver starts now. Move the mouse or press a key to stop it.")
        }
    }

    private var aerialAvailable: Bool {
        if case .unavailable = app.aerial.status { return false }
        return true
    }

    private func optionHeader(title: String, badge: String?, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.s) {
                Text(title).font(.sectionTitle)
                if let badge { Badge(text: badge) }
            }
            Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Source

    private func sourcePanel(_ lock: LockScreenSettings) -> some View {
        let targetID = app.lockScreenTargetID
        let target = app.library.wallpaper(targetID)
        return Panel {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack {
                    Text("Wallpaper").font(.headline)
                    Spacer()
                    Picker("Source", selection: Binding(get: { lock.useDesktopWallpaper },
                                                        set: { app.chooseLockScreenWallpaper(lock.wallpaperID ?? app.currentWallpaper?.id, useDesktop: $0) })) {
                        Text("Same as Desktop").tag(true)
                        Text("Choose Separately").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack {
                            if let target {
                                ThumbnailView(wallpaper: target)
                                if let player = preview.player {
                                    PlayerLayerView(player: player)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                                }
                            } else {
                                RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surfaceRaised)
                                Text(lock.useDesktopWallpaper ? "No desktop wallpaper is live" : "Choose a wallpaper below")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(width: 320)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke))
                        .task(id: targetID) {
                            if let id = targetID, let url = app.library.mediaURL(for: id) { preview.load(url) } else { preview.stop() }
                        }
                        Text("Preview of the video, not of your lock screen").font(.caption).foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if let target {
                            Text(target.title).font(.title3.weight(.semibold))
                            Text("\(target.resolutionText) · \(target.durationText) · \(target.codec ?? "unknown codec")")
                                .font(.meta).foregroundStyle(.secondary)
                            CompatibilityLabel(compatibility: app.lockScreenCompatibility(target.id))
                        }
                        let prepared = app.lockScreen.config?.wallpaperID == targetID && targetID != nil
                        Button {
                            Task {
                                isApplying = true
                                await app.applyLockScreen()
                                isApplying = false
                            }
                        } label: {
                            if isApplying { ProgressView().controlSize(.small) } else { Text(prepared ? "Apply Again" : "Apply to Lock Screen") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(target == nil || isApplying || !(target.map { app.lockScreenCompatibility($0.id).isUsable } ?? false))
                        .padding(.top, Theme.Space.xs)
                        if let config = app.lockScreen.config {
                            Text("Prepared: “\(config.title)” · \(config.appliedAt.relativeDescription)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if lock.useDesktopWallpaper {
                            Text("Follows the wallpaper on your main display and updates automatically when it changes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if !lock.useDesktopWallpaper {
                    Divider()
                    HStack {
                        Text("Choose from your library").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Import Video…") { app.presentImportPanel() }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                        ForEach(app.library.search(SearchQuery(sort: .title))) { wallpaper in
                            LockScreenChoice(wallpaper: wallpaper, isSelected: lock.wallpaperID == wallpaper.id) {
                                app.chooseLockScreenWallpaper(wallpaper.id, useDesktop: false)
                            }
                        }
                    }
                }
            }
        }
    }

    private func stillPicturePanel(_ lock: LockScreenSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Also use a still frame as the macOS wallpaper picture",
                   isOn: Binding(get: { lock.setsStillSystemPicture }, set: { app.setLockScreenStillPicture($0) }))
                .disabled(app.isAerialOn)
            if app.isAerialOn {
                StatusLabel(kind: .warning, text: "Off while the Animated Lock Screen is on: a still picture would replace its Aerial wallpaper.", font: .caption)
            }
            Text("macOS shows its wallpaper picture behind the password prompt, where the screen saver video doesn’t play. The picture is shared with the desktop (hidden behind Driftwall’s live wallpaper), and your previous picture isn’t restored automatically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CapabilityPanel: View {
    let capabilities: LockScreenCapabilities
    let aerialAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("On \(capabilities.osVersionText)").font(.callout.weight(.semibold))
            row("Video on the lock screen, behind the password prompt",
                aerialAvailable
                    ? .supported("With the Animated Lock Screen: macOS itself plays the video, because it replaces your copy of one Apple Aerial wallpaper. Apple’s original is backed up and can be restored.")
                    : .unavailable("This Mac has no Aerial wallpaper store for this user, so the Animated Lock Screen can’t be used."))
            row("Video while the screen saver runs after locking", capabilities.videoWhileLocked)
            row("Still picture behind the password prompt", capabilities.staticImage)
            row("Driftwall drawing its own video on the password screen",
                .unavailable("No public API lets apps draw on the login or password screen, and Driftwall doesn’t try to bypass that."))
            row("Video on the unlocked desktop", capabilities.desktopVideo)
        }
    }

    private func row(_ title: String, _ support: CapabilitySupport) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: support.isSupported ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(support.isSupported ? Theme.live : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(support.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SetupPanel: View {
    @Environment(AppController.self) private var app
    @Binding var confirmTest: Bool

    var body: some View {
        let service = app.lockScreen
        let prepared = service.config.map { FileManager.default.fileExists(atPath: $0.mediaPath) } ?? false
        let immediate = app.passwordDelay == "delay is immediate"
        VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Image(systemName: statusSymbol(service.status)).foregroundStyle(statusColor(service.status))
                    Text(service.status.summary).font(.headline)
                    Spacer()
                    Button("Refresh") { app.refreshLockScreen() }.buttonStyle(.link)
                }
                step(prepared ? .done : .todo, "Lock-screen video prepared", detail: prepared ? nil : "Use Apply below.")
                step(service.isSaverInstalled ? .done : .todo, "Driftwall screen saver installed",
                     detail: service.isSaverInstalled ? "~/Library/Screen Savers/Driftwall.saver" : nil) {
                    if !service.isSaverInstalled { Button("Install") { app.installLockScreenSaver() } }
                }
                step(selectionState(service.saverSelection), "“Driftwall” selected as the screen saver",
                     detail: service.saverSelection == .selected ? nil : MacLockScreenSystem.screenSaverSelectionInstructions
                        + (service.saverSelection == .unknown ? " Driftwall can’t read this setting on your macOS version, so check it there." : "")) {
                    Button("Open Screen Saver Settings…") { MacLockScreenSystem.openScreenSaverSettings() }
                }
                step(app.passwordDelay == nil ? .unknown : (immediate ? .done : .warning), "Password required immediately after the screen saver starts",
                     detail: app.passwordDelay.map { "Currently: \($0.replacingOccurrences(of: "delay is ", with: ""))." + (immediate ? "" : " Until the password is required, the video plays but the Mac isn’t locked yet.") }) {
                    if !immediate { Button("Open Lock Screen Settings…") { MacLockScreenSystem.openLockScreenSettings() } }
                }
                Divider()
                HStack(alignment: .top) {
                    Text("To check it, lock with ⌃⌘Q and wait for the screen saver delay, use a hot corner set to Start Screen Saver, or test it now.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Test Now…") { confirmTest = true }
                        // With another saver selected, the test would show that saver (e.g. Aerials) instead.
                        .disabled(!prepared || !service.isSaverInstalled || service.saverSelection == .notSelected)
                        .help(service.saverSelection == .notSelected ? MacLockScreenSystem.screenSaverSelectionInstructions : "Start the screen saver now")
                }
        }
    }

    private enum StepState { case done, todo, warning, unknown }

    private func selectionState(_ selection: ScreenSaverSelection) -> StepState {
        switch selection {
        case .selected: return .done
        case .notSelected: return .todo
        case .unknown: return .unknown
        }
    }

    private func step(_ state: StepState, _ title: String, detail: String?, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: { switch state {
                case .done: return "checkmark.circle.fill"
                case .todo: return "circle"
                case .warning: return "exclamationmark.triangle.fill"
                case .unknown: return "questionmark.circle"
            } }())
            .foregroundStyle(state == .done ? Theme.live : state == .warning ? Theme.warning : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            action()
        }
    }

    private func statusSymbol(_ status: LockScreenStatus) -> String {
        switch status {
        case .active: return "checkmark.seal.fill"
        case .failed, .unsupported: return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private func statusColor(_ status: LockScreenStatus) -> Color {
        switch status {
        case .active: return Theme.live
        case .failed, .unsupported: return Theme.warning
        default: return Theme.accent
        }
    }
}

private struct CompatibilityLabel: View {
    let compatibility: LockScreenMediaCompatibility

    var body: some View {
        switch compatibility {
        case .compatible:
            StatusLabel(kind: .live, text: compatibility.message)
        case .compatibleWithWarning:
            StatusLabel(kind: .warning, text: compatibility.message)
        case .incompatible:
            StatusLabel(kind: .error, text: compatibility.message)
        }
    }
}

private struct LockScreenChoice: View {
    @Environment(AppController.self) private var app
    let wallpaper: Wallpaper
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let usable = app.lockScreenCompatibility(wallpaper.id).isUsable
        VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(wallpaper: wallpaper, cornerRadius: 8)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 2.5 : 1))
                .opacity(usable ? 1 : 0.45)
            Text(wallpaper.title).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { if usable { select() } }
        .help(usable ? "Use on the lock screen" : app.lockScreenCompatibility(wallpaper.id).message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wallpaper.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Shown until everything is in place: one button does all the work Driftwall is allowed to do, then
/// Driftwall waits for the one choice only the user can make and confirms it automatically.
private struct SetupCard: View {
    @Environment(AppController.self) private var app

    var body: some View {
        let waiting = app.isWaitingForScreenSaverSelection
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if waiting {
                    Text("One last step in System Settings").font(.headline)
                    ForEach(Array(app.screenSaverSelectionSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.callout.weight(.bold)).foregroundStyle(Theme.accent)
                            Text(step).font(.callout)
                        }
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Driftwall notices automatically when you’re done.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings Again") { MacLockScreenSystem.openScreenSaverSettings() }
                    }
                    .padding(.top, 2)
                } else {
                    HStack(alignment: .center, spacing: Theme.Space.l) {
                        Text("Driftwall prepares the video, installs its screen saver and opens System Settings. You then make one click there, because macOS only lets you choose the screen saver yourself.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Space.l)
                        Button("Set Up Screen Saver Video") {
                            Task { await app.setUpLockScreen() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

/// Shown once the screen saver video is fully working.
private struct ReadyRow: View {
    @Environment(AppController.self) private var app

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            StatusLabel(kind: .live, text: "Plays “\(app.lockScreen.config?.title ?? "")” whenever the screen saver starts and the Mac locks, even when Driftwall is closed.")
            Spacer(minLength: Theme.Space.l)
            Button {
                app.lockNow()
            } label: {
                Label("Lock Now", systemImage: "lock.fill")
            }
            .help("Locks your Mac and starts the screen saver right away. Enter your password to come back.")
        }
    }
}
