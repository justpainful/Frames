import AVFoundation
import Combine
import CoreMedia
import Foundation
import Observation
import OSLog

/// Owns the one `AVPlayer` the editor uses.
///
/// Kept deliberately separate from SwiftUI. A SwiftUI view rebuilding its body
/// must never rebuild the player graph, so the engine exposes a stable player
/// object plus a handful of observable scalars, and swaps the *item* only when
/// the composition genuinely changes.
@MainActor
@Observable
final class PlaybackEngine {
    /// Stable for the lifetime of the editor. The view layer binds to this once.
    @ObservationIgnored let player = AVPlayer()

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isReady = false
    /// True while the player is filling its buffer after a seek or a stall.
    private(set) var isBuffering = false

    /// Set while the user is scrubbing so periodic time updates don't fight the
    /// gesture.
    private(set) var isScrubbing = false

    func beginScrubbing() {
        guard !isScrubbing else { return }
        pause()
        isScrubbing = true
    }

    func endScrubbing() {
        isScrubbing = false
    }

    /// Identifies the currently loaded composition, so re-applying an identical
    /// edit does not tear the player down.
    private var loadedSignature: Int?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var bufferObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    private let logger = FramesLog.playback

    init() {
        player.actionAtItemEnd = .pause
        installPeriodicObserver()
    }

    /// Releases observers and stops decoding. Called when the editor closes;
    /// doing it explicitly rather than in `deinit` keeps the teardown on the
    /// main actor where the player lives.
    func tearDown() {
        pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        bufferObservation?.invalidate()
        player.replaceCurrentItem(with: nil)
        loadedSignature = nil
    }

    // MARK: - Loading

    /// Loads a plain file. Used for the raw source before any composition
    /// exists, and by the previews.
    func load(url: URL) {
        let signature = url.hashValue
        guard signature != loadedSignature else { return }
        loadedSignature = signature
        replaceItem(AVPlayerItem(asset: AVURLAsset(url: url)))
    }

    /// Loads a built composition. `signature` lets the caller say "this is the
    /// same edit as last time" cheaply, avoiding a rebuild on every keystroke.
    func load(asset: AVAsset, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?, signature: Int) {
        guard signature != loadedSignature else { return }
        loadedSignature = signature
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        replaceItem(item)
    }

    /// Applies a new video composition to the item already playing.
    ///
    /// This is the cheap path used while the user drags a slider: the asset and
    /// its decoders stay exactly where they are, and only the filter chain
    /// changes.
    func updateVideoComposition(_ videoComposition: AVVideoComposition?) {
        player.currentItem?.videoComposition = videoComposition
    }

    func updateAudioMix(_ audioMix: AVAudioMix?) {
        player.currentItem?.audioMix = audioMix
    }

    private func replaceItem(_ item: AVPlayerItem) {
        isReady = false
        statusObservation?.invalidate()
        bufferObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.isReady = true
                    self.duration = CMTimeGetSeconds(observedItem.duration).isFinite
                        ? CMTimeGetSeconds(observedItem.duration)
                        : 0
                case .failed:
                    self.isReady = false
                    self.logger.error("Player item failed: \(observedItem.error?.localizedDescription ?? "unknown", privacy: .public)")
                default:
                    break
                }
            }
        }

        bufferObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                self?.isBuffering = !observedItem.isPlaybackLikelyToKeepUp
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }

        player.replaceCurrentItem(with: item)
    }

    // MARK: - Transport

    func play() {
        guard isReady else { return }
        // Restarting from the very end is what the user means by pressing play
        // on a finished clip.
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0, precise: true)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    /// Seeks. `precise` costs a decode of the surrounding GOP and is what an
    /// edit needs; the imprecise path is for scrubbing, where keeping up
    /// matters more than landing on the exact frame.
    func seek(to time: TimeInterval, precise: Bool = false) {
        let clamped = min(max(time, 0), duration > 0 ? duration : time)
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        if precise {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
        }
    }

    func step(byFrames count: Int) {
        player.currentItem?.step(byCount: count)
        if let time = player.currentItem?.currentTime() {
            currentTime = CMTimeGetSeconds(time)
        }
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setVolume(_ volume: Float) {
        player.volume = min(max(volume, 0), 1)
    }

    // MARK: - Observation

    private func installPeriodicObserver() {
        // 30 Hz is enough for a playhead that reads as smooth without waking the
        // main thread more often than the display refreshes for it.
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    self.currentTime = seconds
                }
            }
        }
    }
}
