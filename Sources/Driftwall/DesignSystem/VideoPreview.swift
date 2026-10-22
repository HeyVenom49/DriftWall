import AVFoundation
import AppKit
import Observation
import SwiftUI

/// A looping, muted in-app preview player. Each instance owns one decoder that is released in
/// `stop()`; views create it on appear and stop it on disappear so previews never accumulate.
///
/// The decoder runs only while the preview is playing, its window can be seen, and it is the most
/// recently started preview. A hidden window (minimized, covered, hidden, on another Space) or a newer
/// preview (a hover preview over a page whose own preview plays) holds it paused without changing
/// `isPlaying`; it resumes where it was once the window shows again or the newer preview ends.
@MainActor
@Observable
final class PreviewPlayer {
    private(set) var isPlaying = false
    private(set) var failure: String?
    @ObservationIgnored private(set) var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private(set) var url: URL?
    @ObservationIgnored private var isVisible = true
    @ObservationIgnored private var isPreempted = false

    /// Playback is wanted but held, because the window isn't visible or a newer preview plays.
    var isSuspended: Bool { isPlaying && !(isVisible && !isPreempted) }

    func load(_ url: URL, autoplay: Bool = true) {
        guard url != self.url else {
            if autoplay { play() }
            return
        }
        stop()
        self.url = url
        failure = nil
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        statusObservation = looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let message = looper.error?.localizedDescription ?? "This video can’t be played."
            Task { @MainActor in
                self?.failure = message
                self?.isPlaying = false
                if let self { Self.resign(self) }
            }
        }
        self.player = player
        self.looper = looper
        PlaybackDiagnostics.opened(.preview)
        if autoplay { play() }
    }

    func play() {
        guard player != nil, failure == nil else { return }
        isPlaying = true
        Self.activate(self)
        applyRate()
    }

    func pause() {
        isPlaying = false
        Self.resign(self)
        applyRate()
    }

    /// Called by `PlayerLayerView` when its window's visibility changes.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        applyRate()
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        if player != nil { PlaybackDiagnostics.closed(.preview) }
        Self.resign(self)
        statusObservation?.invalidate()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        url = nil
        isPlaying = false
        isPreempted = false
    }

    private func applyRate() {
        guard let player else { return }
        if isPlaying && !isSuspended {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    // MARK: - One decoder at a time

    private struct Weak { weak var preview: PreviewPlayer? }
    /// Previews that want to play, oldest first. Only the last one decodes.
    private static var playing: [Weak] = []

    private static func activate(_ preview: PreviewPlayer) {
        playing.removeAll { $0.preview == nil || $0.preview === preview }
        if let previous = playing.last?.preview {
            previous.isPreempted = true
            previous.applyRate()
        }
        playing.append(Weak(preview: preview))
        preview.isPreempted = false
    }

    private static func resign(_ preview: PreviewPlayer) {
        let wasCurrent = playing.last?.preview === preview
        playing.removeAll { $0.preview == nil || $0.preview === preview }
        preview.isPreempted = false
        if wasCurrent, let next = playing.last?.preview {
            next.isPreempted = false
            next.applyRate()
        }
    }
}

/// Displays an `AVPlayer` with a plain `AVPlayerLayer` (no system transport controls).
/// `onVisibilityChange` reports whether the hosting window can currently be seen.
struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var onVisibilityChange: (@MainActor (Bool) -> Void)? = nil

    func makeNSView(context: Context) -> PlayerLayerNSView {
        PlayerLayerNSView()
    }

    func updateNSView(_ view: PlayerLayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
        view.onVisibilityChange = onVisibilityChange
    }

    static func dismantleNSView(_ view: PlayerLayerNSView, coordinator: ()) {
        view.onVisibilityChange = nil
        view.playerLayer.player = nil
    }
}

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var onVisibilityChange: (@MainActor (Bool) -> Void)? {
        didSet { if let isWindowVisible { onVisibilityChange?(isWindowVisible) } }
    }
    private var occlusionObserver: NSObjectProtocol?
    private var isWindowVisible: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else { return }
        // Occlusion covers minimizing, hiding the app, other windows covering it and other Spaces.
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        onVisibilityChange?(visible)
    }
}
