import AppKit
import SwiftUI

/// Design tokens. Colors adapt to light/dark appearance; the app defaults to dark.
enum Theme {
    static let accent = Color(nsColor: NSColor(srgbRed: 0.95, green: 0.65, blue: 0.35, alpha: 1))
    static let live = Color(nsColor: NSColor(srgbRed: 0.18, green: 0.85, blue: 0.62, alpha: 1))
    static let danger = Color(nsColor: .systemRed)

    static let background = dynamic(light: NSColor(white: 0.97, alpha: 1), dark: NSColor(srgbRed: 0.055, green: 0.058, blue: 0.07, alpha: 1))
    static let surface = dynamic(light: NSColor(white: 1, alpha: 1), dark: NSColor(srgbRed: 0.09, green: 0.094, blue: 0.11, alpha: 1))
    static let surfaceRaised = dynamic(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(srgbRed: 0.13, green: 0.135, blue: 0.155, alpha: 1))
    static let stroke = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let placeholder = dynamic(light: NSColor(white: 0.88, alpha: 1), dark: NSColor(srgbRed: 0.15, green: 0.155, blue: 0.175, alpha: 1))

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
        static let page: CGFloat = 28
    }

    enum Radius {
        static let card: CGFloat = 12
        static let hero: CGFloat = 18
        static let chip: CGFloat = 8
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }
}

extension Font {
    static let pageTitle = Font.system(size: 26, weight: .bold)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let meta = Font.system(size: 11, weight: .medium).monospacedDigit()
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Date {
    var relativeDescription: String {
        RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date())
    }
}
