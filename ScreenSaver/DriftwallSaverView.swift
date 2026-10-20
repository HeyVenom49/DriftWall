// Driftwall screen-saver module (Driftwall.saver).
//
// Plays the video chosen in Driftwall › Lock Screen while the screen saver runs. With
// "Require password immediately" (System Settings › Lock Screen), that is whenever the Mac is locked.
// It runs inside Apple's sandboxed legacyScreenSaver host, whose entitlements allow read-only file access,
// so it only ever reads `~/Library/Application Support/Driftwall/LockScreen/config.json` and the video it names.
// It uses only the public ScreenSaver and AVFoundation APIs.

import AppKit
import AVFoundation
import os
import ScreenSaver

private let logger = Logger(subsystem: "local.driftwall.saver", category: "saver")

private struct SaverConfig: Decodable {
    var version: Int
    var title: String
    var mediaPath: String
    var gravity: String
}

@objc(DriftwallSaverView)
final class DriftwallSaverView: ScreenSaverView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var statusObservation: NSKeyValueObservation?
    private var message: String?
    private var stopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0
        // On recent macOS, legacyScreenSaver does not always call stopAnimation; this notification is the
        // reliable signal that the saver is being dismissed, so playback stops and the decoder is released.
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in self?.teardown() }
        logger.info("init (preview: \(isPreview, privacy: .public))")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        startPlayback()
    }

    override func stopAnimation() {
        super.stopAnimation()
        teardown()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard player == nil, let message else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isPreview ? 10 : 22, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.75),
            .paragraphStyle: style,
        ]
        let size = NSSize(width: bounds.width * 0.8, height: bounds.height * 0.3)
        (message as NSString).draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                                   withAttributes: attributes)
    }

    override func animateOneFrame() {}

    // MARK: - Playback

    private func startPlayback() {
        guard player == nil else {
            player?.play()
            return
        }
        guard let config = Self.loadConfig() else {
            show(message: "Choose a lock-screen wallpaper in Driftwall › Lock Screen.")
            logger.error("no usable config at \(Self.configURL.path, privacy: .public)")
            return
        }
        let url = URL(fileURLWithPath: config.mediaPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            show(message: "The lock-screen video “\(config.title)” can’t be read. Apply it again in Driftwall.")
            logger.error("video not readable: \(url.path, privacy: .public)")
            return
        }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        let layer = AVPlayerLayer(player: player)
        layer.frame = bounds
        switch config.gravity {
        case "fit": layer.videoGravity = .resizeAspect
        case "stretch": layer.videoGravity = .resize
        default: layer.videoGravity = .resizeAspectFill
        }
        self.layer?.addSublayer(layer)
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            if player.timeControlStatus == .playing {
                logger.info("playing “\(config.title, privacy: .public)” (preview: \(self?.isPreview ?? false, privacy: .public))")
            }
            if let error = player.currentItem?.error {
                logger.error("playback error: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.player = player
        self.looper = looper
        playerLayer = layer
        message = nil
        player.play()
        logger.info("starting “\(config.title, privacy: .public)” from \(url.path, privacy: .public)")
    }

    private func teardown() {
        statusObservation?.invalidate()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    private func show(message: String) {
        self.message = message
        needsDisplay = true
    }

    // MARK: - Configuration

    /// The real home folder. Inside the sandboxed host, NSHomeDirectory() points at the host's container.
    private static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    static var configURL: URL {
        URL(fileURLWithPath: realHome).appendingPathComponent("Library/Application Support/Driftwall/LockScreen/config.json")
    }

    private static func loadConfig() -> SaverConfig? {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(SaverConfig.self, from: data), config.version == 1 else { return nil }
        return config
    }
}
