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

    /// Current optical-equivalent zoom, in the units people read on a camera
    /// app: 0.5×, 1×, 2×. Not the raw `videoZoomFactor`, which is relative to
    /// the widest lens and reads as 2× when the user is at 1×.
    private(set) var zoom: Double = 1
    private(set) var minimumZoom: Double = 1
    private(set) var maximumZoom: Double = 1
    /// The lens positions this device actually has, for the row of buttons.
    private(set) var lensStops: [Double] = [1]

    /// Live settings. Changing these changes the preview immediately and, if a
    /// recording is running, the rest of the recording.
    ///
    /// Writing pushes a copy down to the recorder rather than leaving the
    /// capture queue to read main-actor state, which is not something it can
    /// safely do.
    var portrait: PortraitSettings {
        get { trackedPortrait }
        set {
            trackedPortrait = newValue
            recorder.updateSettings(newValue)
        }
    }

    private var trackedPortrait = PortraitSettings.Preset.clean.settings

    /// Called on the capture queue with each processed frame, for the preview
    /// layer to draw.
    ///
    /// Forwarded straight to the recorder so the frame path never touches this
    /// object: routing 30 frames a second through an observable main-actor type
    /// would invalidate the view tree 30 times a second, and reaching back into
    /// the main actor from the capture queue is what crashed this before.
    @ObservationIgnored var onFrame: ((CIImage) -> Void)? {
        get { recorder.onFrame }
        set { recorder.onFrame = newValue }
    }

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

        recorder.updateSettings(trackedPortrait)
        recorder.onDurationChange = { [weak self] duration in
            Task { @MainActor in self?.recordedDuration = duration }
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
                self.lockFrameRate(on: device)
            }
            self.applyConnectionSettings()
            self.session.commitConfiguration()
            Task { @MainActor in self.refreshZoomRange() }
        }
    }

    // MARK: - Zoom

    /// Sets the zoom in the units shown on screen.
    ///
    /// On a multi-lens device the system switches lenses for you as the factor
    /// crosses each threshold, which is why this drives one number rather than
    /// picking a device: switching inputs mid-session drops frames and resets
    /// exposure, and the virtual device does it properly.
    func setZoom(_ value: Double, animated: Bool = false) {
        guard let device = videoInput?.device else { return }
        let clamped = min(max(value, minimumZoom), maximumZoom)
        zoom = clamped

        // The device's own factor is relative to its widest lens; the number
        // the user sees is relative to the 1× lens.
        let raw = clamped * zoomBaseline

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let bounded = min(
                    max(CGFloat(raw), device.minAvailableVideoZoomFactor),
                    device.maxAvailableVideoZoomFactor
                )
                if animated {
                    device.ramp(toVideoZoomFactor: bounded, withRate: 8)
                } else {
                    device.videoZoomFactor = bounded
                }
            } catch {
                self.logger.notice("Zoom refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Called continuously during a pinch, so it multiplies the factor the
    /// gesture started from rather than accumulating rounding.
    func zoom(byPinch magnification: Double, from start: Double) {
        setZoom(start * magnification)
    }

    /// The raw factor that corresponds to 1× on this device.
    @ObservationIgnored private var zoomBaseline: Double = 1

    private func refreshZoomRange() {
        guard let device = videoInput?.device else { return }

        // On a device with an ultra-wide, the raw factor at 1× is the first
        // switch-over point — everything below it is the 0.5× lens.
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        let baseline = switchOvers.first ?? 1
        zoomBaseline = baseline

        let rawMin = Double(device.minAvailableVideoZoomFactor)
        let rawMax = Double(device.maxAvailableVideoZoomFactor)
        minimumZoom = max(rawMin / baseline, 0.5)
        // Past about six times the picture is mush, whatever the sensor claims.
        maximumZoom = min(rawMax / baseline, 8)

        var stops: [Double] = []
        if minimumZoom < 0.9 { stops.append(0.5) }
        stops.append(1)
        for switchOver in switchOvers.dropFirst() {
            let stop = (switchOver / baseline * 10).rounded() / 10
            if stop > 1.05, stop <= maximumZoom { stops.append(stop) }
        }
        lensStops = stops
        zoom = min(max(1, minimumZoom), maximumZoom)
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

                // Bi-planar YUV rather than BGRA. At 1080p30 that is roughly
                // 90 MB/s off the sensor instead of 250, which is a large part
                // of why the phone was getting hot; Core Image reads it
                // natively, so nothing downstream changes.
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
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
                self.lockFrameRate(on: device)
                self.session.commitConfiguration()
                Task { @MainActor in self.refreshZoomRange() }
                continuation.resume(returning: true)
            }
        }
    }

    /// Pins the camera to 30 fps.
    ///
    /// Left alone, the camera picks a range and drifts inside it — including up
    /// to 60, which doubles the work per second for a chain that is already the
    /// expensive part. A fixed rate also stops the preview stuttering as the
    /// camera trades frame rate for exposure in a dim room, which is exactly
    /// the situation this mode is for.
    private func lockFrameRate(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let duration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            logger.notice("Frame rate not locked: \(error.localizedDescription, privacy: .public)")
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
