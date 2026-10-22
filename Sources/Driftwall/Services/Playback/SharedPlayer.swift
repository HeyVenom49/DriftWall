import AVFoundation
import DriftwallCore

/// One looping decoder for one wallpaper. When the same wallpaper is shown on several displays,
/// every surface attaches its own `AVPlayerLayer` to this single player, so the video is decoded once.
@MainActor
final class SharedPlayer {
    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let wallpaperID: WallpaperID
    let url: URL
    let player: AVQueuePlayer
    private(set) var status: Status = .loading
    var onStatusChange: ((SharedPlayer) -> Void)?

    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []

    init(wallpaperID: WallpaperID, url: URL) {
        self.wallpaperID = wallpaperID
        self.url = url
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        // Wallpapers never need audio, and must never keep the display awake on their own.
        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        PlaybackDiagnostics.opened(.desktop)

        observations.append(looper.observe(\.status, options: [.new]) { [weak self] looper, _ in
            let failure = looper.status == .failed ? (looper.error?.localizedDescription ?? "The video could not be looped.") : nil
            Task { @MainActor in self?.handle(failure: failure, ready: looper.status == .ready) }
        })
        observations.append(player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            let itemStatus = player.currentItem?.status
            let failure = itemStatus == .failed ? (player.currentItem?.error?.localizedDescription ?? "The video could not be decoded.") : nil
            Task { @MainActor in self?.handle(failure: failure, ready: itemStatus == .readyToPlay) }
        })
    }

    var isPlaying: Bool { player.rate != 0 }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    func play() {
        guard !isFailed else { return }
        if player.rate == 0 { player.play() }
    }

    func pause() {
        if player.rate != 0 { player.pause() }
    }

    /// Releases the decoder and all observers. The player must not be used afterwards.
    func invalidate() {
        if looper != nil { PlaybackDiagnostics.closed(.desktop) }
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        onStatusChange = nil
    }

    private func handle(failure: String?, ready: Bool) {
        let newStatus: Status
        if let failure {
            newStatus = .failed(failure)
        } else if ready {
            newStatus = .ready
        } else {
            return
        }
        guard newStatus != status else { return }
        if isFailed { return } // failures are terminal for this player
        status = newStatus
        onStatusChange?(self)
    }
}
