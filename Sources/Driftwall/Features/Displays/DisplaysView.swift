import DriftwallCore
import SwiftUI

struct DisplaysView: View {
    @Environment(AppController.self) private var app

    var body: some View {
        let displays = app.displays.displays
        let dormant = DisplayAssignmentResolver.dormantAssignments(app.assignments.assignments, connected: displays)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Displays", subtitle: "\(displays.count) connected") {
                    Picker("Layout", selection: Binding(get: { app.settings.displayMode }, set: { app.settings.displayMode = $0 })) {
                        ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Give each display its own wallpaper, or show the same one everywhere")
                }

                if displays.isEmpty {
                    EmptyStateView(symbol: "display.trianglebadge.exclamationmark", title: "No displays detected",
                                   message: "Driftwall restores wallpapers automatically when a display is connected.") { EmptyView() }
                } else {
                    ArrangementView(displays: displays)
                        .frame(height: 200)

                    if app.settings.displayMode == .mirror {
                        StatusLabel(kind: .info, text: "Every display shows the same wallpaper, decoded once and shared by all displays.")
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                            if index > 0 { Divider().padding(.leading, 56).opacity(0.6) }
                            DisplayRow(display: display)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.section, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.5)
                    )
                }

                if !dormant.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader(title: "Remembered Displays", subtitle: "Restored when they reconnect")
                        ForEach(dormant, id: \.displayID) { assignment in
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "display").foregroundStyle(.tertiary)
                                Text(assignment.displayName).font(.callout.weight(.medium))
                                Text(app.library.wallpaper(assignment.wallpaperID)?.title ?? "Removed wallpaper")
                                    .font(.callout).foregroundStyle(.secondary)
                                Text("· set \(assignment.updatedAt.relativeDescription)").font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                                Button("Forget") { app.forgetAssignment(displayID: assignment.displayID) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                InlineNotice(kind: .info, title: "How live wallpapers are shown",
                             message: "Driftwall plays video in a click-through window at the desktop level of each display, above the macOS wallpaper and below your app windows. The lock screen is set up separately.") {
                    Button("Lock Screen…") { app.navigation.show(.lockScreen) }
                }
            }
            .padding(Theme.Space.page)
        }
        .background(Theme.background)
        .navigationTitle("Displays")
    }
}

/// Scaled drawing of the current display arrangement with each display's wallpaper.
private struct ArrangementView: View {
    @Environment(AppController.self) private var app
    let displays: [DisplayInfo]

    var body: some View {
        GeometryReader { geometry in
            let union = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let scale = min((geometry.size.width - 20) / max(union.width, 1), (geometry.size.height - 20) / max(union.height, 1))
            let offsetX = (geometry.size.width - union.width * scale) / 2
            let offsetY = (geometry.size.height - union.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    // AppKit's origin is bottom-left; flip to SwiftUI's top-left.
                    let rect = CGRect(x: (display.frame.minX - union.minX) * scale + offsetX,
                                      y: (union.maxY - display.frame.maxY) * scale + offsetY,
                                      width: display.frame.width * scale, height: display.frame.height * scale)
                    let state = app.engine.surfaceStates[display.id]
                    let isTarget = app.isDefaultTarget(display)
                    ZStack {
                        if let state, let wallpaper = app.library.wallpaper(state.wallpaperID) {
                            ThumbnailView(wallpaper: wallpaper, cornerRadius: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceRaised)
                            Text("macOS wallpaper").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack {
                            Spacer()
                            Text(display.name).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(4)
                        }
                    }
                    .frame(width: rect.width - 4, height: rect.height - 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isTarget ? Theme.accent : Theme.stroke, lineWidth: isTarget ? 2 : 1))
                    .offset(x: rect.minX + 2, y: rect.minY + 2)
                }
            }
        }
        .padding(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display arrangement with \(displays.count) displays")
    }
}

private struct DisplayRow: View {
    @Environment(AppController.self) private var app
    let display: DisplayInfo

    var body: some View {
        let state = app.engine.surfaceStates[display.id]
        let assignedID = app.settings.displayMode == .mirror ? app.settings.mirrorWallpaperID : app.assignments.wallpaperID(for: display.id)
        let assigned = app.library.wallpaper(assignedID)
        let isTarget = app.isDefaultTarget(display)
        HStack(alignment: .center, spacing: Theme.Space.l) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.name).font(.body.weight(.semibold))
                    if display.isMain { Badge(text: "MAIN") }
                    if isTarget { Badge(text: "DEFAULT TARGET") }
                }
                Text("\(display.resolutionText) px · \(Int(display.frame.width))×\(Int(display.frame.height)) pt @\(Int(display.scale))x\(display.rotation != 0 ? " · rotated \(Int(display.rotation))°" : "")")
                    .font(.meta).foregroundStyle(.secondary)
            }
            .frame(minWidth: 220, alignment: .leading)

            if let assigned {
                ThumbnailView(wallpaper: assigned, cornerRadius: 5)
                    .frame(width: 80, height: 45)
                VStack(alignment: .leading, spacing: 2) {
                    Text(assigned.title).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        StatusDot(color: statusColor(state?.status, available: app.library.isAvailable(assigned.id)))
                        Text(state?.status.label ?? (app.library.isAvailable(assigned.id) ? "Not running" : "Video file missing"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Text("macOS wallpaper (no live wallpaper)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.m)

            Menu("Choose Wallpaper") {
                let favorites = app.library.favoriteWallpapers.filter { app.library.isAvailable($0.id) }
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { w in Button(w.title) { app.apply(w.id, target: .display(id: display.id)) } }
                    }
                }
                Section("All Wallpapers") {
                    ForEach(app.library.search(SearchQuery(sort: .title)).filter { app.library.isAvailable($0.id) }) { w in
                        Button(w.title) { app.apply(w.id, target: .display(id: display.id)) }
                    }
                }
            }
            .fixedSize()
            Menu {
                Button("Make Default Target") { app.settings.defaultTarget = .display(id: display.id) }
                    .disabled(isTarget)
                if assigned != nil {
                    Divider()
                    Button("Stop Live Wallpaper on This Display") { app.clearWallpaper(displayID: display.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for \(display.name)")
            .accessibilityLabel("More for \(display.name)")
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
    }

    private func statusColor(_ status: SurfaceStatus?, available: Bool) -> Color {
        guard available else { return Theme.warning }
        switch status {
        case .playing: return Theme.live
        case .loading: return Theme.accent
        case .paused: return Theme.warning
        case .failed: return Theme.danger
        case nil: return .secondary
        }
    }
}

extension AppController {
    /// Whether "Set as Wallpaper" targets this display by default.
    func isDefaultTarget(_ display: DisplayInfo) -> Bool {
        switch settings.defaultTarget {
        case .display(let id): return id == display.id
        case .mainDisplay: return display.isMain
        case .allDisplays: return false
        }
    }
}
