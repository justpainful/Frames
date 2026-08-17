import Foundation
import Testing
@testable import Frames

@Suite("Capture recorder")
struct CaptureRecorderTests {

    /// The capture queue reads Portrait settings on every frame. It used to do
    /// that by hopping to `MainActor.assumeIsolated`, which asserts it is on the
    /// main actor — the capture queue never is, so it trapped on the first
    /// frame of the first recording.
    ///
    /// This exercises the same path from a thread that is not the main actor.
    /// It would have crashed against the old design and passes against the
    /// current one, which is the whole point of it being here.
    @Test("Settings can be read from a thread that is not the main actor")
    func settingsAreReadableOffTheMainActor() async {
        let recorder = CaptureRecorder()
        recorder.updateSettings(PortraitSettings.Preset.studio.settings)

        let queue = DispatchQueue(label: "com.frames.Frames.tests.capture")
        let value: PortraitSettings = await withCheckedContinuation { continuation in
            queue.async {
                recorder.updateSettings(PortraitSettings.Preset.natural.settings)
                continuation.resume(returning: recorder.settingsForTesting())
            }
        }

        #expect(value == PortraitSettings.Preset.natural.settings)
    }

    @Test("The most recent settings win")
    func latestSettingsWin() {
        let recorder = CaptureRecorder()
        recorder.updateSettings(PortraitSettings.Preset.clean.settings)
        recorder.updateSettings(PortraitSettings.Preset.lowLight.settings)
        #expect(recorder.settingsForTesting() == PortraitSettings.Preset.lowLight.settings)
    }

    @Test("A recorder with nothing recorded refuses to finish")
    func finishWithoutRecording() async {
        let recorder = CaptureRecorder()
        await #expect(throws: FramesError.self) {
            _ = try await recorder.finish()
        }
    }

    @Test("There is no frame to capture before any has arrived")
    func noFrameYet() {
        #expect(CaptureRecorder().latestProcessedImage() == nil)
    }
}
