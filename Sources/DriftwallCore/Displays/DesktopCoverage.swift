import CoreGraphics

/// Decides whether ordinary app windows cover a display's desktop.
///
/// macOS reports the wallpaper window as visible while any part of it shows, including through the
/// translucent menu bar and Dock, so window occlusion alone almost never says "hidden" while someone
/// works with a zoomed window. Coverage is therefore checked against the display's usable area (the
/// screen minus menu bar and Dock): it is covered when every point of a grid over that area lies
/// inside some window. All rectangles use the same coordinate space.
public enum DesktopCoverage {
    /// Grid points per axis. Windows that leave a gap narrower than one cell are treated as covering;
    /// at 24 × 16 over a laptop screen that is ~60 × 60 points, far less than any usable desktop area.
    public static let columns = 24
    public static let rows = 16

    public static func isCovered(_ area: CGRect, by windows: [CGRect]) -> Bool {
        guard !area.isEmpty else { return false }
        let relevant = windows.filter { $0.intersects(area) }
        guard !relevant.isEmpty else { return false }
        // Inset so points on the area's own edges don't depend on rounding of window frames.
        let inner = area.insetBy(dx: min(4, area.width / 4), dy: min(4, area.height / 4))
        for row in 0..<rows {
            let y = inner.minY + inner.height * (CGFloat(row) + 0.5) / CGFloat(rows)
            for column in 0..<columns {
                let x = inner.minX + inner.width * (CGFloat(column) + 0.5) / CGFloat(columns)
                let point = CGPoint(x: x, y: y)
                if !relevant.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }
}
