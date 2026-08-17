import Foundation
import Testing
@testable import Frames

@Suite("Timeline duration and lookup")
struct TimelineGeometryTests {

    @Test("A freshly imported video is one clip covering the whole source")
    func importedVideoIsWholeSource() {
        let document = TestDocuments.singleClipVideo(duration: 15)
        #expect(document.videoTrack.count == 1)
        #expect(abs(document.duration - 15) < 0.001)
        #expect(document.isPristine)
        #expect(document.timelineIsValid)
    }

    @Test("Clip start times accumulate")
    func clipStartTimes() {
        let document = TestDocuments.threeClipVideo()
        let starts = document.clipStartTimes
        #expect(starts.count == 3)
        #expect(abs(starts[0] - 0) < 0.001)
        #expect(abs(starts[1] - 5) < 0.001)
        #expect(abs(starts[2] - 10) < 0.001)
    }

    @Test("Lookup finds the clip under the playhead")
    func clipLookup() {
        let document = TestDocuments.threeClipVideo()
        let located = document.clip(at: 7)
        #expect(located != nil)
        #expect(located?.index == 1)
        #expect(abs((located?.offset ?? 0) - 2) < 0.001)
    }

    @Test("Speed changes the timeline duration but not the source range")
    func speedAffectsTimelineDuration() throws {
        var document = TestDocuments.singleClipVideo(duration: 10)
        let clipID = try #require(document.videoTrack.first?.id)
        _ = try document.setSpeed(2, forClip: clipID)
        #expect(abs(document.duration - 5) < 0.001)
        #expect(abs(document.videoTrack[0].source.duration - 10) < 0.001)
    }

    @Test("Source time mapping honours speed")
    func sourceTimeMapping() {
        var clip = VideoClip(assetID: UUID(), source: TimeRange(start: 2, duration: 8))
        clip.speed = 2
        #expect(abs(clip.sourceTime(forOffset: 0) - 2) < 0.001)
        #expect(abs(clip.sourceTime(forOffset: 2) - 6) < 0.001)
        #expect(abs(clip.timelineDuration - 4) < 0.001)
    }

    @Test("Source time mapping honours reversal")
    func reversedSourceTimeMapping() {
        var clip = VideoClip(assetID: UUID(), source: TimeRange(start: 2, duration: 8))
        clip.isReversed = true
        #expect(abs(clip.sourceTime(forOffset: 0) - 10) < 0.001)
        #expect(abs(clip.sourceTime(forOffset: 8) - 2) < 0.001)
    }
}

@Suite("Trim")
struct TrimTests {

    @Test("Trimming the head moves the in-point and shortens the timeline")
    func trimHead() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let clipID = try #require(document.videoTrack.first?.id)
        _ = try document.trimClip(clipID, headDelta: 3)
        #expect(abs(document.videoTrack[0].source.start - 3) < 0.001)
        #expect(abs(document.duration - 12) < 0.001)
        #expect(document.timelineIsValid)
    }

    @Test("Trimming the tail shortens without moving the in-point")
    func trimTail() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let clipID = try #require(document.videoTrack.first?.id)
        _ = try document.trimClip(clipID, tailDelta: 4)
        #expect(abs(document.videoTrack[0].source.start) < 0.001)
        #expect(abs(document.duration - 11) < 0.001)
    }

    @Test("Trimming past the source start is refused")
    func trimBeyondSourceStart() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let clipID = try #require(document.videoTrack.first?.id)
        #expect(throws: TimelineEditError.rangeOutOfBounds) {
            _ = try document.trimClip(clipID, headDelta: -1)
        }
    }

    @Test("Trimming below the minimum clip length is refused")
    func trimBelowMinimum() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let clipID = try #require(document.videoTrack.first?.id)
        #expect(throws: TimelineEditError.resultingClipTooShort) {
            _ = try document.trimClip(clipID, headDelta: 14.99)
        }
        #expect(abs(document.duration - 15) < 0.001, "a refused trim must not change the document")
    }

    @Test("Setting an explicit source range works and is bounded")
    func setSourceRange() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let clipID = try #require(document.videoTrack.first?.id)
        _ = try document.setClipSource(clipID, start: 4, duration: 6)
        #expect(abs(document.duration - 6) < 0.001)
        #expect(throws: TimelineEditError.rangeOutOfBounds) {
            _ = try document.setClipSource(clipID, start: 12, duration: 10)
        }
    }

    @Test("A trimmed clip still points at the original asset")
    func trimIsNonDestructive() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let assetID = try #require(document.assets.first?.id)
        let clipID = try #require(document.videoTrack.first?.id)
        _ = try document.trimClip(clipID, headDelta: 2, tailDelta: 2)
        #expect(document.videoTrack[0].assetID == assetID)
        #expect(document.assets.count == 1)
        #expect(abs((document.assets.first?.duration ?? 0) - 15) < 0.001)
    }
}

@Suite("Split")
struct SplitTests {

    @Test("Splitting produces two clips that reference the same asset")
    func splitProducesTwoClips() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let assetID = try #require(document.assets.first?.id)
        _ = try document.split(at: 6)

        #expect(document.videoTrack.count == 2)
        #expect(document.videoTrack.allSatisfy { $0.assetID == assetID })
        #expect(abs(document.videoTrack[0].source.duration - 6) < 0.001)
        #expect(abs(document.videoTrack[1].source.start - 6) < 0.001)
        #expect(abs(document.videoTrack[1].source.duration - 9) < 0.001)
    }

    @Test("Splitting preserves total duration")
    func splitPreservesDuration() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let before = document.duration
        _ = try document.split(at: 4.25)
        #expect(abs(document.duration - before) < 0.001)
        #expect(document.timelineIsValid)
    }

    @Test("Splitting too close to an edge is refused")
    func splitTooCloseToEdge() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        #expect(throws: TimelineEditError.splitTooCloseToEdge) {
            _ = try document.split(at: 0.01)
        }
        #expect(document.videoTrack.count == 1)
    }

    @Test("Splitting a middle clip only affects that clip")
    func splitMiddleClip() throws {
        var document = TestDocuments.threeClipVideo()
        _ = try document.split(at: 7)
        #expect(document.videoTrack.count == 4)
        #expect(abs(document.duration - 15) < 0.001)
    }

    @Test("The first clip never carries a transition in")
    func firstClipHasNoTransition() throws {
        var document = TestDocuments.threeClipVideo()
        document.videoTrack[1].transitionIn = Transition(kind: .dissolve, duration: 0.5)
        _ = try document.deleteClip(document.videoTrack[0].id)
        #expect(document.videoTrack[0].transitionIn.isActive == false)
    }
}

@Suite("Remove range")
struct RemoveRangeTests {

    @Test("Removing a middle range closes the gap")
    func removeMiddle() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        _ = try document.removeRange(TimeRange(start: 3, duration: 5))

        #expect(document.videoTrack.count == 2)
        #expect(abs(document.duration - 10) < 0.001)
        #expect(abs(document.videoTrack[0].source.start - 0) < 0.001)
        #expect(abs(document.videoTrack[0].source.duration - 3) < 0.001)
        #expect(abs(document.videoTrack[1].source.start - 8) < 0.001)
        #expect(abs(document.videoTrack[1].source.duration - 7) < 0.001)
        #expect(document.timelineIsValid)
    }

    @Test("Removing from the beginning trims the head")
    func removeBeginning() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        _ = try document.removeRange(TimeRange(start: 0, duration: 4))

        #expect(document.videoTrack.count == 1)
        #expect(abs(document.duration - 11) < 0.001)
        #expect(abs(document.videoTrack[0].source.start - 4) < 0.001)
    }

    @Test("Removing from the end trims the tail")
    func removeEnd() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        _ = try document.removeRange(TimeRange(start: 11, duration: 4))

        #expect(document.videoTrack.count == 1)
        #expect(abs(document.duration - 11) < 0.001)
        #expect(abs(document.videoTrack[0].source.start) < 0.001)
        #expect(abs(document.videoTrack[0].source.duration - 11) < 0.001)
    }

    @Test("Removing a span that covers whole clips deletes them")
    func removeWholeClips() throws {
        var document = TestDocuments.threeClipVideo()
        let removed = try document.removeRange(TimeRange(start: 5, duration: 5))

        #expect(removed == 1)
        #expect(document.videoTrack.count == 2)
        #expect(abs(document.duration - 10) < 0.001)
    }

    @Test("Removing a span across a clip boundary trims both sides")
    func removeAcrossBoundary() throws {
        var document = TestDocuments.threeClipVideo()
        _ = try document.removeRange(TimeRange(start: 4, duration: 2))

        #expect(document.videoTrack.count == 3)
        #expect(abs(document.duration - 13) < 0.001)
        #expect(abs(document.videoTrack[0].timelineDuration - 4) < 0.001)
        #expect(abs(document.videoTrack[1].timelineDuration - 4) < 0.001)
        #expect(document.timelineIsValid)
    }

    @Test("A tiny range is still a valid edit")
    func removeTinyRange() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        _ = try document.removeRange(TimeRange(start: 7, duration: 0.2))
        #expect(abs(document.duration - 14.8) < 0.01)
    }

    @Test("A zero-length range is refused")
    func removeZeroLength() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        #expect(throws: TimelineEditError.rangeTooShort) {
            _ = try document.removeRange(TimeRange(start: 5, duration: 0))
        }
    }

    @Test("A range beyond the timeline is refused")
    func removeOutOfBounds() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        #expect(throws: TimelineEditError.rangeOutOfBounds) {
            _ = try document.removeRange(TimeRange(start: 12, duration: 10))
        }
        #expect(abs(document.duration - 15) < 0.001)
    }

    @Test("Removing the entire duration is refused")
    func removeEverything() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        #expect(throws: TimelineEditError.wouldEmptyTimeline) {
            _ = try document.removeRange(TimeRange(start: 0, duration: 15))
        }
        #expect(document.videoTrack.count == 1)
    }

    @Test("Removing exactly at a split boundary leaves both halves intact")
    func removeAtSplitBoundary() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        _ = try document.split(at: 5)
        _ = try document.removeRange(TimeRange(start: 5, duration: 3))

        #expect(document.videoTrack.count == 2)
        #expect(abs(document.duration - 12) < 0.001)
        #expect(abs(document.videoTrack[0].timelineDuration - 5) < 0.001)
    }

    @Test("Overlays after the removed span shift back with the picture")
    func overlaysShift() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        document.textOverlays = [
            TextOverlay(string: "before", timeRange: TimeRange(start: 0, duration: 2)),
            TextOverlay(string: "inside", timeRange: TimeRange(start: 4, duration: 2)),
            TextOverlay(string: "after", timeRange: TimeRange(start: 10, duration: 3))
        ]
        _ = try document.removeRange(TimeRange(start: 3, duration: 5))

        #expect(document.textOverlays.count == 2, "the overlay inside the removed span is gone")
        let after = document.textOverlays.first { $0.string == "after" }
        #expect(abs((after?.timeRange?.start ?? 0) - 5) < 0.001)
        let before = document.textOverlays.first { $0.string == "before" }
        #expect(abs((before?.timeRange?.start ?? -1) - 0) < 0.001)
    }

    @Test("Audio after the removed span shifts back")
    func audioShifts() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let musicAsset = SourceAsset(fileName: "music.m4a", kind: .video, duration: 20)
        document.addAsset(musicAsset)
        document.audioClips = [
            AudioClip(
                assetID: musicAsset.id,
                role: .music,
                source: TimeRange(start: 0, duration: 4),
                timelineStart: 10
            )
        ]
        _ = try document.removeRange(TimeRange(start: 2, duration: 3))
        #expect(abs((document.audioClips.first?.timelineStart ?? 0) - 7) < 0.001)
    }
}

@Suite("Clip management")
struct ClipManagementTests {

    @Test("Deleting a clip closes the gap")
    func deleteClip() throws {
        var document = TestDocuments.threeClipVideo()
        _ = try document.deleteClip(document.videoTrack[1].id)
        #expect(document.videoTrack.count == 2)
        #expect(abs(document.duration - 10) < 0.001)
    }

    @Test("Deleting the last remaining clip is refused")
    func deleteLastClip() throws {
        var document = TestDocuments.singleClipVideo()
        #expect(throws: TimelineEditError.wouldEmptyTimeline) {
            _ = try document.deleteClip(document.videoTrack[0].id)
        }
    }

    @Test("Duplicating a clip inserts a copy right after it")
    func duplicateClip() throws {
        var document = TestDocuments.threeClipVideo()
        let originalID = document.videoTrack[0].id
        let copyID = try document.duplicateClip(originalID)

        #expect(document.videoTrack.count == 4)
        #expect(document.videoTrack[1].id == copyID)
        #expect(copyID != originalID)
        #expect(abs(document.duration - 20) < 0.001)
    }

    @Test("Moving a clip reorders without changing duration")
    func moveClip() {
        var document = TestDocuments.threeClipVideo()
        let lastID = document.videoTrack[2].id
        document.moveClip(from: 2, to: 0)
        #expect(document.videoTrack[0].id == lastID)
        #expect(abs(document.duration - 15) < 0.001)
    }

    @Test("A freeze frame becomes its own clip and extends the timeline")
    func insertFreezeFrame() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let freezeID = try document.insertFreezeFrame(at: 5, duration: 2)

        #expect(document.videoTrack.count == 3)
        #expect(abs(document.duration - 17) < 0.001)
        let freeze = document.videoTrack.first { $0.id == freezeID }
        #expect(freeze?.isFrozen == true)
        #expect(abs((freeze?.source.start ?? 0) - 5) < 0.001)
        #expect(document.timelineIsValid)
    }

    @Test("A frozen clip can be trimmed like any other")
    func trimFrozenClip() throws {
        var document = TestDocuments.singleClipVideo(duration: 15)
        let freezeID = try document.insertFreezeFrame(at: 5, duration: 2)
        _ = try document.trimClip(freezeID, tailDelta: 0.5)
        let freeze = document.videoTrack.first { $0.id == freezeID }
        #expect(abs((freeze?.timelineDuration ?? 0) - 1.5) < 0.001)
    }

    @Test("Photo documents refuse timeline operations")
    func photoRefusesTimelineEdits() throws {
        var document = TestDocuments.photo()
        #expect(throws: TimelineEditError.notAVideoEdit) {
            _ = try document.split(at: 1)
        }
        #expect(throws: TimelineEditError.notAVideoEdit) {
            _ = try document.removeRange(TimeRange(start: 0, duration: 1))
        }
    }
}
