import CoreGraphics
import Foundation
import Testing
@testable import DriftwallCore

@Suite("Display assignment logic")
struct DisplayAssignmentTests {
    let builtIn = DisplayInfo(id: "UUID-BUILTIN", directDisplayID: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              pixelWidth: 3024, pixelHeight: 1964, scale: 2, isMain: true, isBuiltIn: true)
    let external = DisplayInfo(id: "UUID-EXT", directDisplayID: 2, name: "Studio", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                               pixelWidth: 5120, pixelHeight: 2880, scale: 2, isMain: false, isBuiltIn: false)
    let portrait = DisplayInfo(id: "UUID-PORTRAIT", directDisplayID: 3, name: "Portrait", frame: CGRect(x: -1080, y: 0, width: 1080, height: 1920),
                               pixelWidth: 1080, pixelHeight: 1920, scale: 1, isMain: false, isBuiltIn: false, rotation: 90)

    func assignment(_ display: String, _ wallpaper: String) -> DisplayAssignment {
        DisplayAssignment(displayID: display, wallpaperID: wallpaper, displayName: display)
    }

    @Test func perDisplayAssignments() {
        let result = DisplayAssignmentResolver.resolve(
            displays: [builtIn, external],
            assignments: [assignment("UUID-BUILTIN", "a"), assignment("UUID-EXT", "b")],
            mode: .perDisplay, mirrorWallpaperID: nil, isAvailable: { _ in true })
        #expect(result == ["UUID-BUILTIN": "a", "UUID-EXT": "b"])
    }

    @Test func mirrorModeUsesOneWallpaperEverywhere() {
        let result = DisplayAssignmentResolver.resolve(
            displays: [builtIn, external, portrait],
            assignments: [assignment("UUID-BUILTIN", "a")],
            mode: .mirror, mirrorWallpaperID: "m", isAvailable: { _ in true })
        #expect(result == ["UUID-BUILTIN": "m", "UUID-EXT": "m", "UUID-PORTRAIT": "m"])
    }

    @Test func unavailableMediaIsLeftToTheSystemWallpaper() {
        let perDisplay = DisplayAssignmentResolver.resolve(
            displays: [builtIn, external],
            assignments: [assignment("UUID-BUILTIN", "missing"), assignment("UUID-EXT", "b")],
            mode: .perDisplay, mirrorWallpaperID: nil, isAvailable: { $0 != "missing" })
        #expect(perDisplay == ["UUID-EXT": "b"])
        let mirror = DisplayAssignmentResolver.resolve(displays: [builtIn], assignments: [], mode: .mirror,
                                                       mirrorWallpaperID: "missing", isAvailable: { $0 != "missing" })
        #expect(mirror.isEmpty)
    }

    @Test func disconnectedDisplayKeepsAssignmentAndRecoversOnReconnect() {
        let stored = [assignment("UUID-BUILTIN", "a"), assignment("UUID-EXT", "b")]
        let unplugged = DisplayAssignmentResolver.resolve(displays: [builtIn], assignments: stored, mode: .perDisplay,
                                                          mirrorWallpaperID: nil, isAvailable: { _ in true })
        #expect(unplugged == ["UUID-BUILTIN": "a"])
        #expect(DisplayAssignmentResolver.dormantAssignments(stored, connected: [builtIn]).map(\.displayID) == ["UUID-EXT"])

        // The transient CGDirectDisplayID may change on reconnect; the UUID does not.
        var replugged = external
        replugged.directDisplayID = 99
        let restored = DisplayAssignmentResolver.resolve(displays: [builtIn, replugged], assignments: stored, mode: .perDisplay,
                                                         mirrorWallpaperID: nil, isAvailable: { _ in true })
        #expect(restored == ["UUID-BUILTIN": "a", "UUID-EXT": "b"])
    }

    @Test func newDisplayWithoutAssignmentShowsNothingInPerDisplayMode() {
        let result = DisplayAssignmentResolver.resolve(displays: [builtIn, portrait], assignments: [assignment("UUID-BUILTIN", "a")],
                                                       mode: .perDisplay, mirrorWallpaperID: nil, isAvailable: { _ in true })
        #expect(result["UUID-PORTRAIT"] == nil)
    }

    @Test func targetSelection() {
        let all = [builtIn, external]
        #expect(DisplayAssignmentResolver.targetDisplays(for: .allDisplays, in: all).map(\.id) == ["UUID-BUILTIN", "UUID-EXT"])
        #expect(DisplayAssignmentResolver.targetDisplays(for: .mainDisplay, in: all).map(\.id) == ["UUID-BUILTIN"])
        #expect(DisplayAssignmentResolver.targetDisplays(for: .display(id: "UUID-EXT"), in: all).map(\.id) == ["UUID-EXT"])
        // A remembered target that is not connected falls back to the main display.
        #expect(DisplayAssignmentResolver.targetDisplays(for: .display(id: "UUID-GONE"), in: all).map(\.id) == ["UUID-BUILTIN"])
        #expect(DisplayAssignmentResolver.targetDisplays(for: .mainDisplay, in: []).isEmpty)
    }

    @Test func orientation() {
        #expect(portrait.isPortrait)
        #expect(!external.isPortrait)
    }
}
