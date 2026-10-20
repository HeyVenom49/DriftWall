import AVFoundation
import AppKit
import Observation
import SwiftUI

/// A looping, muted in-app preview player. Each instance owns one decoder that is released in
/// `stop()`; views create it on appear and stop it on disappear so previews never accumulate.
@MainActor
@Observable
final class PreviewPlayer {
    private(set) var isPlaying = false
    private(set) var failure: String?
    @ObservationIgnored private(set) var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private(set) var url: URL?

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
            }
        }
        self.player = player
        self.looper = looper
        if autoplay { play() }
    }

    func play() {
        guard let player, failure == nil else { return }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        url = nil
        isPlaying = false
    }
}

/// Displays an `AVPlayer` with a plain `AVPlayerLayer` (no system transport controls).
struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PlayerLayerNSView {
        PlayerLayerNSView()
    }

    func updateNSView(_ view: PlayerLayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }

    static func dismantleNSView(_ view: PlayerLayerNSView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
}
