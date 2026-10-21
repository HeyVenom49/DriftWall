import AppKit
import SwiftUI

/// Design tokens for a dark-first, native macOS creative utility.
/// Artwork stays the brightest surface; chrome stays restrained (Linear-like hierarchy, Apple controls).
enum Theme {
    // MARK: Color

    /// Interaction accent — System Settings › Appearance › Accent Color.
    static let accent = Color.accentColor
    static let live = Color(nsColor: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.58, alpha: 1))
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    /// Main content plane (deep charcoal, not pure black).
    static let background = dynamic(
        light: NSColor(white: 0.965, alpha: 1),
        dark: NSColor(srgbRed: 0.070, green: 0.073, blue: 0.082, alpha: 1)
    )
    /// Sidebar — subtly lifted from the content plane.
    static let sidebar = dynamic(
        light: NSColor(white: 0.945, alpha: 1),
        dark: NSColor(srgbRed: 0.088, green: 0.091, blue: 0.102, alpha: 1)
    )
    /// Grouped surfaces (sections, inspectors). Use sparingly; never nest.
    static let surface = dynamic(
        light: NSColor(white: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.112, green: 0.116, blue: 0.130, alpha: 1)
    )
    static let surfaceRaised = dynamic(
        light: NSColor(white: 0.92, alpha: 1),
        dark: NSColor(srgbRed: 0.150, green: 0.155, blue: 0.172, alpha: 1)
    )
    static let stroke = dynamic(
        light: NSColor(white: 0, alpha: 0.08),
        dark: NSColor(white: 1, alpha: 0.06)
    )
    static let strokeStrong = dynamic(
        light: NSColor(white: 0, alpha: 0.14),
        dark: NSColor(white: 1, alpha: 0.10)
    )
    static let placeholder = dynamic(
        light: NSColor(white: 0.88, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.130, blue: 0.145, alpha: 1)
    )
    static let primaryText = dynamic(
        light: NSColor(white: 0.08, alpha: 1),
        dark: NSColor(white: 0.96, alpha: 1)
    )
    static let secondaryText = dynamic(
        light: NSColor(white: 0.35, alpha: 1),
        dark: NSColor(srgbRed: 0.62, green: 0.64, blue: 0.68, alpha: 1)
    )

    // MARK: Layout

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Window edge → page content.
        static let page: CGFloat = 24
        /// Gap between wallpaper grid / shelf items.
        static let grid: CGFloat = 14
    }

    enum Radius {
        static let card: CGFloat = 6
        static let hero: CGFloat = 10
        static let section: CGFloat = 8
        static let chip: CGFloat = 6
        static let control: CGFloat = 6
    }

    enum Size {
        static let sidebarMin: CGFloat = 196
        static let sidebarIdeal: CGFloat = 212
        static let sidebarMax: CGFloat = 268
        static let shelfItem: CGFloat = 228
        static let rowThumbnail = CGSize(width: 96, height: 54)
        static let statusDot: CGFloat = 6
        static let iconButton: CGFloat = 28
        static let controlHeight: CGFloat = 28
    }

    // MARK: Motion

    enum Motion {
        static let quick = 0.12
        static let standard = 0.20

        static func ease(_ duration: Double = standard, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: duration)
        }
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
        })
    }
}

extension Font {
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let cardTitle = Font.system(size: 12, weight: .medium)
    static let meta = Font.system(size: 11, weight: .regular).monospacedDigit()
    static let eyebrow = Font.system(size: 10, weight: .semibold)
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Date {
    var relativeDescription: String {
        RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date())
    }
}
