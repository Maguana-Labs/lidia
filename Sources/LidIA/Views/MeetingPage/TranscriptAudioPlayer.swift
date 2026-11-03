import AVFoundation
import Foundation
import Observation

/// Plays a meeting's audio file for the transcript inspector.
@MainActor
@Observable
final class TranscriptAudioPlayer {
    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var loadedURL: URL?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?

    /// Loads `url`, replacing any previous file. Passing nil unloads.
    func load(url: URL?) {
        guard url != loadedURL else { return }
        unload()
        guard let url else { return }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedURL = url
        isLoaded = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                let seconds = time.seconds
                self.currentTime = seconds.isFinite ? seconds : 0
                self.isPlaying = player.timeControlStatus != .paused
            }
        }

        Task { [weak self] in
            let loaded = try? await item.asset.load(.duration)
            guard let self, self.loadedURL == url, let loaded else { return }
            let seconds = loaded.seconds
            self.duration = seconds.isFinite ? seconds : 0
        }
    }

    func unload() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        loadedURL = nil
        isLoaded = false
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if duration > 0, currentTime >= duration - 0.1 {
                seek(to: 0, play: true)
                return
            }
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: TimeInterval, play: Bool = false) {
        guard let player else { return }
        let upper = duration > 0 ? duration : seconds
        let clamped = min(max(0, seconds), upper)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        if play {
            player.play()
            isPlaying = true
        }
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta, play: isPlaying)
    }
}
