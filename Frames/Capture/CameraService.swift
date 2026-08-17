import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Observation
import OSLog
import UIKit

/// The camera.
///
/// Frames processes what it captures rather than capturing first and fixing
/// afterwards. Every frame goes through `PortraitProcessor` on its way to both
/// the preview and the recording, which is the point of the mode: the noise is
/// dealt with before the shadows are lifted, and what you are looking at while
/// you shoot is what lands in the file.
///
/// Recording is done with `AVAssetWriter` fed from the processed frames rather
/// than `AVCaptureMovieFileOutput`, because the movie output writes the sensor's
/// frames and would silently discard the processing.
@MainActor
@Observable
final class CameraService: NSObject {

    enum Status: Equatable {
        case idle
        case preparing
        case ready
        case unavailable(FramesError)
    }

    private(set) var status: Status = .idle
    private(set) var isRecording = false
    private(set) var recordedDuration: TimeInterval = 0
    private(set) var position: AVCaptureDevice.Position = .front

    /// Live settings. Changing these changes the preview immediately and, if a
    /// recording is running, the rest of the recording.
    var portrait: PortraitSettings = PortraitSettings.Preset.clean.settings

    /// Called on the capture queue with each processed frame, for the preview
    /// layer to draw. Deliberately not `@Observable` state: routing 30 frames a
    /// second through the observation system would invalidate the whole view
    /// tree 30 times a second.
    @ObservationIgnored nonisolated(unsafe) var onFrame: ((CIImage) -> Void)?

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.frames.Frames.capture.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "com.frames.Frames.capture.video", qos: .userInitiated)

    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let audioOutput = AVCaptureAudioDataOutput()
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var audioInput: AVCaptureDeviceInput?

    /// Everything the capture queue touches lives here, so the main actor and
    /// the capture queue never reach for the same thing.
    @ObservationIgnored private let recorder = CaptureRecorder()

    private let logger = FramesLog.render

    // MARK: - Lifecycle

    func prepare() async {
        guard status == .idle else { return }
        status = .preparing

        guard await requestCameraPermission() else {
            status = .unavailable(.cameraPermissionDenied)
            return
        }
        // Audio is asked for separately and is not fatal: a silent recording is
        // better than no recording.
        let hasAudio = await requestMicrophonePermission()

        let configured = await configureSession(includeAudio: hasAudio)
        guard configured else {
            status = .unavailable(.cameraUnavailable)
            return
        }

        recorder.portraitProvider = { [weak self] in
            MainActor.assumeIsolated { self?.portrait ?? .off }
        }
        recorder.onDurationChange = { [weak self] duration in
            Task { @MainActor in self?.recordedDuration = duration }
        }
        recorder.onFrame = { [weak self] image in
            self?.onFrame?(image)
        }

        status = .ready
        start()
    }

    func start() {
        guard status == .ready else { return }
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    func toggleCamera() {
        guard status == .ready, !isRecording else { return }
        let next: AVCaptureDevice.Position = position == .front ? .back : .front
        position = next
        Haptics.snap()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let existing = self.videoInput {
                self.session.removeInput(existing)
            }
            if let device = Self.device(for: next),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoInput = input
            }
            self.applyConnectionSettings()
            self.session.commitConfiguration()
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard status == .ready, !isRecording else { return }
        isRecording = true
        recordedDuration = 0
        Haptics.edit()
        recorder.begin()
    }

    /// Stops and returns the finished clip, already described and staged in the
    /// session's media directory so it can be opened like any import.
    func stopRecording() async throws -> SourceAsset {
        guard isRecording else { throw FramesError.exportFailed("not recording") }
        isRecording = false
        let url = try await recorder.finish()
        Haptics.success()
        return try await MediaImportService().describeExisting(
            fileName: url.lastPathComponent,
            kind: .video
        )
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        recorder.cancel()
    }

    /// Captures the frame currently on screen — processed, not raw, because the
    /// processed frame is the one the user is composing.
    func capturePhoto() async throws -> SourceAsset {
        guard let image = recorder.latestProcessedImage() else {
            throw FramesError.renderFailed("no frame to capture")
        }
        try SessionPaths.createDirectories()
        let fileName = "\(UUID().uuidString).heic"
        let url = SessionPaths.mediaURL(for: fileName)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        do {
            try RenderContext.shared.export.writeHEIFRepresentation(
                of: image,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95]
            )
        } catch {
            logger.error("Photo capture failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.exportFailed(error.localizedDescription)
        }

        Haptics.success()
        return try await MediaImportService().describeExisting(fileName: fileName, kind: .photo)
    }

    // MARK: - Configuration

    private func configureSession(includeAudio: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                self.session.beginConfiguration()
                // 1080p is the sweet spot: enough resolution for the processing
                // to have something to work with, few enough pixels that the
                // whole chain keeps up at 30 fps on a phone.
                self.session.sessionPreset = .hd1920x1080

                guard let device = Self.device(for: self.position),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input)
                else {
                    self.session.commitConfiguration()
                    continuation.resume(returning: false)
                    return
                }
                self.session.addInput(input)
                self.videoInput = input

                if includeAudio,
                   let microphone = AVCaptureDevice.default(for: .audio),
                   let audio = try? AVCaptureDeviceInput(device: microphone),
                   self.session.canAddInput(audio) {
                    self.session.addInput(audio)
                    self.audioInput = audio
                }

                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                // Dropping late frames rather than queueing them is what keeps
                // the preview live instead of drifting behind the subject.
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self.recorder, queue: self.videoQueue)
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }

                if self.audioInput != nil {
                    self.audioOutput.setSampleBufferDelegate(self.recorder, queue: self.videoQueue)
                    if self.session.canAddOutput(self.audioOutput) {
                        self.session.addOutput(self.audioOutput)
                    }
                }

                self.applyConnectionSettings()
                self.session.commitConfiguration()
                continuation.resume(returning: true)
            }
        }
    }

    /// Orientation and mirroring, set on the connection so the frames arrive
    /// the right way up and the recorder never has to rotate anything.
    private func applyConnectionSettings() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        // A front camera that does not mirror its preview is disorienting, and
        // one that mirrors the *recording* produces backwards text.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front)
        }
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    // MARK: - Permissions

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
