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
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Lock Screen", subtitle: "Play a video wallpaper while your Mac is locked") {
                    if lock.isEnabled {
                        Toggle("Enabled", isOn: Binding(get: { lock.isEnabled }, set: { app.setLockScreenEnabled($0) }))
                            .toggleStyle(.switch)
                    }
                }

                if !app.lockScreen.isSupported {
                    EmptyStateView(symbol: "lock.slash", title: "Not available on this Mac",
                                   message: app.lockScreen.capabilities.videoWhileLocked.detail) { EmptyView() }
                } else if app.isLockScreenReady {
                    ReadyCard()
                } else {
                    SetupCard()
                }

                if lock.isEnabled && app.lockScreen.isSupported {
                    sourcePanel(lock)
                }

                AdvancedAerialPanel()

                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        CapabilityPanel(capabilities: app.lockScreen.capabilities)
                        if lock.isEnabled {
                            SetupPanel(confirmTest: $confirmTest)
                            stillPicturePanel(lock)
                        }
                    }
                    .padding(.top, Theme.Space.m)
                }
                .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.page)
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

                HStack(alignment: .top, spacing: Theme.Space.l) {
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
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "lock.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 6)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 14)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: 360)
                    .task(id: targetID) {
                        if let id = targetID, let url = app.library.mediaURL(for: id) { preview.load(url) } else { preview.stop() }
                    }

                    VStack(alignment: .leading, spacing: Theme.Space.m) {
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
                        Text("Your library").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Import Video…") { app.presentImportPanel() }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
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
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Also use a still frame as the macOS system picture",
                       isOn: Binding(get: { lock.setsStillSystemPicture }, set: { app.setLockScreenStillPicture($0) }))
                Text("macOS shows the system picture behind the password prompt and login window, where video can’t play. The system picture is shared with the desktop (hidden behind Driftwall’s live wallpaper), and your previous picture is not restored automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CapabilityPanel: View {
    let capabilities: LockScreenCapabilities

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text("What \(capabilities.osVersionText) allows").font(.headline)
                    Spacer()
                }
                row("Video while the Mac is locked (screen saver)", capabilities.videoWhileLocked)
                row("Still picture behind the password prompt", capabilities.staticImage)
                row("Video inside the password/login screen itself", .unavailable("No public API lets apps draw on the login or password UI, and Driftwall doesn’t try to bypass that."))
                row("Installing a system video wallpaper (like Apple’s Aerials)", capabilities.systemVideoWallpaper)
                row("Video on the unlocked desktop", capabilities.desktopVideo)
            }
        }
    }

    private func row(_ title: String, _ support: CapabilitySupport) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: support.isSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(support.isSupported ? Theme.live : .secondary)
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
        Panel {
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
            .foregroundStyle(state == .done ? Theme.live : state == .warning ? Color.orange : Color.secondary)
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
        case .failed, .unsupported: return .orange
        default: return .blue
        }
    }
}

private struct CompatibilityLabel: View {
    let compatibility: LockScreenMediaCompatibility

    var body: some View {
        switch compatibility {
        case .compatible:
            Label(compatibility.message, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.live).font(.callout)
        case .compatibleWithWarning:
            Label(compatibility.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case .incompatible:
            Label(compatibility.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
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
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 3 : 1))
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
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Image(systemName: waiting ? "hand.point.up.left.fill" : "lock.display")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(waiting ? "One last step in System Settings" : "Set up your lock screen")
                            .font(.title3.weight(.semibold))
                        if waiting {
                            ForEach(Array(app.screenSaverSelectionSteps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(index + 1)").font(.callout.weight(.bold)).foregroundStyle(Theme.accent)
                                    Text(step).font(.callout)
                                }
                            }
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Driftwall will notice automatically when you’re done.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("Driftwall prepares the video and opens System Settings for you. You then make one click there, because macOS only lets you choose the screen saver yourself.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
                HStack {
                    Spacer()
                    if waiting {
                        Button("Open System Settings Again") { MacLockScreenSystem.openScreenSaverSettings() }
                    } else {
                        Button {
                            Task { await app.setUpLockScreen() }
                        } label: {
                            Text("Set Up Lock Screen").frame(minWidth: 180)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
        }
    }
}

/// Shown once the lock screen is fully working.
private struct ReadyCard: View {
    @Environment(AppController.self) private var app

    var body: some View {
        Panel {
            HStack(spacing: Theme.Space.l) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.live)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your lock screen plays “\(app.lockScreen.config?.title ?? "")”").font(.title3.weight(.semibold))
                    Text("It plays whenever the screen saver starts and the Mac locks, even when Driftwall is closed. Changes you make below apply automatically.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    app.lockNow()
                } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                }
                .controlSize(.large)
                .help("Locks your Mac and shows the video right away. Enter your password to come back.")
            }
        }
    }
}
