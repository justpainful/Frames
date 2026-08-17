import CoreGraphics
import Foundation
import Testing
@testable import Frames

@Suite("Document coding")
struct DocumentCodingTests {

    private func roundTrip(_ document: EditDocument) throws -> EditDocument {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EditDocument.self, from: encoder.encode(document))
    }

    @Test("A plain video document survives a round trip")
    func videoRoundTrip() throws {
        let document = TestDocuments.singleClipVideo(duration: 12)
        let decoded = try roundTrip(document)
        #expect(decoded == document)
    }

    @Test("A photo document survives a round trip")
    func photoRoundTrip() throws {
        let document = TestDocuments.photo()
        let decoded = try roundTrip(document)
        #expect(decoded == document)
    }

    @Test("A fully loaded document survives a round trip")
    func complexRoundTrip() throws {
        var document = TestDocuments.threeClipVideo()
        let assetID = try #require(document.assets.first?.id)

        document.grade = Grade(
            adjustments: AdjustmentSet([.exposure: 0.3, .vignette: -0.2]),
            filter: FilterInstance(presetID: "noir", intensity: 0.7)
        )
        document.outputAspect = .nineSixteen
        document.background = BackgroundStyle(fill: .blur, blurAmount: 0.8)
        document.textOverlays = [
            TextOverlay(
                string: "مرحبا",
                style: TextStyle(design: .rounded, weight: .bold, alignment: .leading),
                timeRange: TimeRange(start: 1, duration: 3),
                animation: TextAnimationSet(entrance: .pop, loop: .float, exit: .fade)
            )
        ]
        document.imageOverlays = [ImageOverlay(assetID: assetID, cornerRadius: 0.05)]
        document.drawings = [
            DrawingOverlay(shapes: [
                VectorShape(kind: .arrow, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.8, y: 0.7))
            ])
        ]
        document.blurRegions = [BlurRegion.make(scope: .area), BlurRegion.make(scope: .background)]
        document.selectiveAdjustments = [
            SelectiveAdjustment(adjustments: AdjustmentSet([.brightness: 0.25]))
        ]
        document.effects = [EffectInstance(kind: .grain, intensity: 0.4)]
        document.audioClips = [
            AudioClip(
                assetID: assetID,
                role: .voiceover,
                source: TimeRange(start: 0, duration: 4),
                timelineStart: 2,
                fadeIn: 0.3,
                fadeOut: 0.3
            )
        ]
        document.audioMix = AudioMixSettings(autoDuck: true)

        var tracked = TrackedObject(label: "plate")
        tracked.append(TrackingSample(time: 0, rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), confidence: 0.9))
        tracked.append(TrackingSample(time: 1, rect: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.1), confidence: 0.8))
        document.trackedObjects = [tracked]

        var keyframes = KeyframeSet()
        keyframes.setKeyframe(.opacity, value: 0, at: 0)
        keyframes.setKeyframe(.opacity, value: 1, at: 1)
        document.videoTrack[0].keyframes = keyframes

        let decoded = try roundTrip(document)
        #expect(decoded == document)
        #expect(decoded.textOverlays.first?.string == "مرحبا")
        #expect(decoded.videoTrack[0].keyframes.animatedProperties == [.opacity])
    }

    @Test("Sparse adjustment sets stay sparse through coding")
    func adjustmentSparsity() throws {
        var document = TestDocuments.photo()
        document.grade.adjustments[.exposure] = 0.5
        let encoder = JSONEncoder()
        let data = try encoder.encode(document.grade.adjustments)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("exposure"))
        #expect(!json.contains("vignette"), "untouched parameters are not written")
    }

    @Test("The schema version is stamped")
    func schemaVersionIsStamped() throws {
        let document = TestDocuments.photo()
        #expect(document.schemaVersion == EditDocument.currentSchemaVersion)
        #expect(try roundTrip(document).schemaVersion == EditDocument.currentSchemaVersion)
    }
}

@Suite("Session recovery", .serialized)
struct SessionRecoveryTests {

    /// Puts a stand-in file where the document says its media lives, so the
    /// store's integrity check passes without a real video.
    private func writePlaceholderMedia(for document: EditDocument) throws {
        try SessionPaths.createDirectories()
        for asset in document.assets {
            let url = SessionPaths.mediaURL(for: asset.fileName)
            try Data("placeholder".utf8).write(to: url, options: .atomic)
        }
    }

    @Test("A saved session comes back")
    func saveAndLoad() async throws {
        let store = SessionRecoveryStore()
        await store.discard()

        var document = TestDocuments.singleClipVideo(duration: 9)
        document.grade.adjustments[.contrast] = 0.4
        try writePlaceholderMedia(for: document)

        try await store.save(document)
        let loaded = await store.load()
        #expect(loaded?.id == document.id)
        #expect(loaded?.grade.adjustments[.contrast] == 0.4)

        await store.discard()
    }

    @Test("Discarding removes the session")
    func discard() async throws {
        let store = SessionRecoveryStore()
        var document = TestDocuments.singleClipVideo()
        document.grade.adjustments[.exposure] = 0.2
        try writePlaceholderMedia(for: document)
        try await store.save(document)

        await store.discard()
        #expect(await store.load() == nil)
    }

    @Test("A session with missing media is discarded rather than half-restored")
    func missingMediaIsDiscarded() async throws {
        let store = SessionRecoveryStore()
        await store.discard()

        var document = TestDocuments.singleClipVideo()
        document.grade.adjustments[.exposure] = 0.2
        try writePlaceholderMedia(for: document)
        try await store.save(document)

        for asset in document.assets {
            try FileManager.default.removeItem(at: SessionPaths.mediaURL(for: asset.fileName))
        }
        #expect(await store.load() == nil)
    }

    @Test("An untouched session is not offered for recovery")
    func pristineSessionIsNotOffered() async throws {
        let store = SessionRecoveryStore()
        await store.discard()

        let document = TestDocuments.singleClipVideo()
        try writePlaceholderMedia(for: document)
        try await store.save(document)

        #expect(await store.summary() == nil, "there is nothing to recover if nothing was changed")
        await store.discard()
    }

    @Test("A changed session is offered for recovery")
    func changedSessionIsOffered() async throws {
        let store = SessionRecoveryStore()
        await store.discard()

        var document = TestDocuments.singleClipVideo()
        document.grade.adjustments[.exposure] = 0.35
        try writePlaceholderMedia(for: document)
        try await store.save(document)

        let summary = await store.summary()
        #expect(summary?.id == document.id)
        #expect(summary?.kind == .video)

        await store.discard()
    }
}
