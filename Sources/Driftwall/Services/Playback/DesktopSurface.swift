import AppKit
import AVFoundation
import DriftwallCore

/// A borderless, click-through window that sits at the desktop window level: above the system
/// wallpaper, below Finder's desktop icons (unless configured otherwise) and below every app window.
/// It uses only public AppKit API; no system process is modified.
final class DesktopWallpaperWindow: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        // Present on every Space, unaffected by Exposé/Mission Control and never part of window cycling.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        setShowsDesktopIcons(true)
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setShowsDesktopIcons(_ show: Bool) {
        // Desktop icons live at kCGDesktopIconWindowLevel. Staying at the desktop level keeps them visible;
        // moving one level above the icon layer hides them while staying below all normal windows.
        let key: CGWindowLevelKey = show ? .desktopWindow : .desktopIconWindow
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(key)) + (show ? 0 : 1))
    }
}

/// Hosts the video layer(s) for one surface and cross-fades when the wallpaper changes.
final class PlayerContainerView: NSView {
    private var current: AVPlayerLayer?
    private var readyObservation: NSKeyValueObservation?
    var gravity: AVLayerVideoGravity = .resizeAspectFill {
        didSet { current?.videoGravity = gravity }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }

    func show(_ player: AVPlayer?) {
        readyObservation?.invalidate()
        guard let player else {
            current?.removeFromSuperlayer()
            current = nil
            return
        }
        let incoming = AVPlayerLayer(player: player)
        incoming.videoGravity = gravity
        incoming.frame = bounds
        incoming.opacity = 0
        incoming.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(incoming)
        let outgoing = current
        current = incoming

        let reveal = { [weak incoming] in
            guard let incoming else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(outgoing == nil ? 0.35 : 0.8)
            CATransaction.setCompletionBlock { outgoing?.removeFromSuperlayer() }
            incoming.opacity = 1
            CATransaction.commit()
        }
        if incoming.isReadyForDisplay {
            reveal()
        } else {
            // Fade in only once the first frame is decoded so switching never flashes black.
            readyObservation = incoming.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    self?.readyObservation?.invalidate()
                    reveal()
                }
            }
        }
    }

    func teardown() {
        readyObservation?.invalidate()
        layer?.sublayers?.forEach { ($0 as? AVPlayerLayer)?.player = nil; $0.removeFromSuperlayer() }
        current = nil
    }
}

/// One desktop surface per display.
@MainActor
final class DesktopSurface {
    let displayID: String
    private(set) var displayName: String
    let window: DesktopWallpaperWindow
    let container: PlayerContainerView
    private(set) var wallpaperID: WallpaperID?
    private(set) var isOccluded = false
    var onOcclusionChange: (() -> Void)?
    private var occlusionObserver: NSObjectProtocol?

    init(display: DisplayInfo) {
        displayID = display.id
        displayName = display.name
        window = DesktopWallpaperWindow(frame: display.frame)
        container = PlayerContainerView(frame: CGRect(origin: .zero, size: display.frame.size))
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let occluded = !self.window.occlusionState.contains(.visible)
                guard occluded != self.isOccluded else { return }
                self.isOccluded = occluded
                self.onOcclusionChange?()
            }
        }
    }

    func update(display: DisplayInfo) {
        displayName = display.name
        if window.frame != display.frame {
            // Handles resolution, arrangement and rotation changes.
            window.setFrame(display.frame, display: true)
        }
    }

    func show(_ player: SharedPlayer?, gravity: AVLayerVideoGravity) {
        container.gravity = gravity
        wallpaperID = player?.wallpaperID
        container.show(player?.player)
        if player == nil {
            window.orderOut(nil)
        } else if !window.isVisible {
            window.orderFront(nil)
        }
    }

    /// Keeps the assignment but hides the surface so the regular system wallpaper shows instead of black.
    func showFailure(of wallpaperID: WallpaperID) {
        self.wallpaperID = wallpaperID
        container.show(nil)
        window.orderOut(nil)
    }

    func close() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        onOcclusionChange = nil
        container.teardown()
        window.orderOut(nil)
        window.close()
    }
}
