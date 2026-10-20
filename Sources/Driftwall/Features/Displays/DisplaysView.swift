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
                    Picker("Mode", selection: Binding(get: { app.settings.displayMode }, set: { app.settings.displayMode = $0 })) {
                        ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                if displays.isEmpty {
                    EmptyStateView(symbol: "display.trianglebadge.exclamationmark", title: "No displays detected",
                                   message: "Driftwall will restore wallpapers automatically when a display is connected.") { EmptyView() }
                } else {
                    ArrangementView(displays: displays)
                        .frame(height: 220)

                    if app.settings.displayMode == .mirror {
                        Text("Every display shows the same wallpaper. One video decoder is shared by all displays.")
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.Space.l)], spacing: Theme.Space.l) {
                        ForEach(displays) { display in
                            DisplayCard(display: display)
                        }
                    }
                }

                if !dormant.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionHeader(title: "Remembered Displays", subtitle: "Assignments for disconnected displays are restored when they reconnect.")
                        ForEach(dormant, id: \.displayID) { assignment in
                            HStack {
                                Image(systemName: "display").foregroundStyle(.secondary)
                                Text(assignment.displayName).font(.callout.weight(.medium))
                                Text("→ \(app.library.wallpaper(assignment.wallpaperID)?.title ?? "Removed wallpaper")")
                                    .font(.callout).foregroundStyle(.secondary)
                                Text("· last set \(assignment.updatedAt.relativeDescription)").font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                                Button("Forget") { app.forgetAssignment(displayID: assignment.displayID) }
                            }
                        }
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("How live wallpapers are shown", systemImage: "info.circle").font(.headline)
                        Text("Driftwall plays video in a click-through window placed at the desktop level of each display — above the system wallpaper and below your app windows. The lock screen and login window cannot show live video; enable “Match system wallpaper” in Settings › Playback to give them a matching still frame.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.Space.page)
        }
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
                    ZStack {
                        if let state, let wallpaper = app.library.wallpaper(state.wallpaperID) {
                            ThumbnailView(wallpaper: wallpaper, cornerRadius: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceRaised)
                            Text("System wallpaper").font(.caption).foregroundStyle(.secondary)
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
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(display.isMain ? Theme.accent : Theme.stroke, lineWidth: display.isMain ? 2 : 1))
                    .offset(x: rect.minX + 2, y: rect.minY + 2)
                }
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display arrangement with \(displays.count) displays")
    }
}

private struct DisplayCard: View {
    @Environment(AppController.self) private var app
    let display: DisplayInfo

    var body: some View {
        let state = app.engine.surfaceStates[display.id]
        let assignedID = app.settings.displayMode == .mirror ? app.settings.mirrorWallpaperID : app.assignments.wallpaperID(for: display.id)
        let assigned = app.library.wallpaper(assignedID)
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display").font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(display.name).font(.headline)
                            if display.isMain { Badge(text: "MAIN") }
                        }
                        Text("\(display.resolutionText) px · \(Int(display.frame.width))×\(Int(display.frame.height)) pt @\(Int(display.scale))x\(display.rotation != 0 ? " · rotated \(Int(display.rotation))°" : "")")
                            .font(.meta).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider()
                HStack(spacing: Theme.Space.m) {
                    if let assigned {
                        ThumbnailView(wallpaper: assigned, cornerRadius: 6).frame(width: 96, height: 54)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(assigned.title).font(.callout.weight(.semibold))
                            Text(state?.status.label ?? (app.library.isAvailable(assigned.id) ? "Not running" : "Video file missing"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No live wallpaper — the system wallpaper is visible.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
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
                    if assigned != nil {
                        Button("Clear") { app.clearWallpaper(displayID: display.id) }
                            .help("Stop the live wallpaper on this display")
                    }
                    Spacer()
                    Button("Make Default") { app.settings.defaultTarget = .display(id: display.id) }
                        .buttonStyle(.link)
                        .disabled(app.settings.defaultTarget == .display(id: display.id))
                        .help("“Set as Wallpaper” targets this display by default")
                }
            }
        }
    }
}
