import AVFoundation
import CoreMedia
import Foundation
import Observation
import OSLog

/// Records narration against the timeline.
///
/// Permission is requested when the user actually taps record, not on launch,
/// and a refusal produces a clear message rather than a silent no-op. The
/// recorded file lands in the session's media directory like any other import,
/// so it is covered by recovery and cleanup for free.
@MainActor
@Observable
final class VoiceoverRecorder {
    struct Result: Sendable {
        let asset: SourceAsset
        /// Where on the timeline the recording should be placed.
        let startTime: TimeInterval
    }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Normalised input level, for the meter.
    private(set) var level: Double = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var fileName: String?
    @ObservationIgnored private var startTime: TimeInterval = 0
    private let logger = FramesLog.audio

    func start(at timelineTime: TimeInterval) async throws {
        guard !isRecording else { return }

        guard await requestPermission() else {
            throw FramesError.microphonePermissionDenied
        }

        try SessionPaths.createDirectories()
        let name = "\(UUID().uuidString).m4a"
        let url = SessionPaths.mediaURL(for: name)

        let session = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` so the timeline can keep playing while the user
            // records against it, which is the whole point of a voiceover.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            logger.error("Audio session failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.exportFailed(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw FramesError.exportFailed("the recorder refused to start")
        }

        self.recorder = recorder
        self.fileName = name
        self.startTime = timelineTime
        elapsed = 0
        isRecording = true
        Haptics.edit()
        startMetering()
    }

    func stop() async throws -> Result? {
        guard let recorder, let fileName else { return nil }
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
        level = 0
        self.recorder = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let recordedName = fileName
        let url = SessionPaths.mediaURL(for: recordedName)
        self.fileName = nil

        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0.05 else {
            try? FileManager.default.removeItem(at: url)
            throw FramesError.exportFailed("the recording was empty")
        }

        return Result(
            asset: SourceAsset(
                fileName: recordedName,
                kind: .video,
                duration: duration,
                displaySize: .zero,
                nominalFrameRate: 0,
                hasAudioTrack: true
            ),
            startTime: startTime
        )
    }

    func cancel() {
        recorder?.stop()
        meterTask?.cancel()
        meterTask = nil
        isRecording = false
        level = 0
        if let fileName {
            try? FileManager.default.removeItem(at: SessionPaths.mediaURL(for: fileName))
        }
        fileName = nil
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestPermission() async -> Bool {
        let application = AVAudioApplication.shared
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            _ = application
            return false
        }
    }

    /// Updates the meter and the elapsed readout without blocking anything.
    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, let recorder = self.recorder, recorder.isRecording else { break }
                recorder.updateMeters()
                // Decibels are logarithmic and mostly negative; map the useful
                // range onto 0...1 so the meter reads like a meter.
                let decibels = Double(recorder.averagePower(forChannel: 0))
                let normalised = max(0, (decibels + 50) / 50)
                self.level = min(normalised, 1)
                self.elapsed = recorder.currentTime
            }
        }
    }
}
