import Foundation
import Testing
@testable import Frames

@Suite("Undo and redo")
struct EditorHistoryTests {

    @Test("A recorded change can be undone")
    func undoRestoresPreviousDocument() throws {
        var history = EditorHistory()
        let original = TestDocuments.singleClipVideo(duration: 15)

        var changed = original
        history.record(original, label: "Trim")
        _ = try changed.trimClip(changed.videoTrack[0].id, headDelta: 2)

        #expect(history.canUndo)
        #expect(history.undoLabel == "Trim")

        let restored = history.undo(current: changed)
        #expect(restored != nil)
        #expect(abs((restored?.document.duration ?? 0) - 15) < 0.001)
        #expect(history.canRedo)
    }

    @Test("Redo re-applies what undo removed")
    func redoReappliesChange() throws {
        var history = EditorHistory()
        var document = TestDocuments.singleClipVideo(duration: 15)
        let original = document

        history.record(document, label: "Trim")
        _ = try document.trimClip(document.videoTrack[0].id, headDelta: 2)
        let trimmed = document

        document = try #require(history.undo(current: document)).document
        #expect(abs(document.duration - original.duration) < 0.001)

        document = try #require(history.redo(current: document)).document
        #expect(abs(document.duration - trimmed.duration) < 0.001)
        #expect(!history.canRedo)
    }

    @Test("A new change after undo discards the redo branch")
    func branchAfterUndo() throws {
        var history = EditorHistory()
        var document = TestDocuments.singleClipVideo(duration: 15)

        history.record(document, label: "First")
        _ = try document.trimClip(document.videoTrack[0].id, headDelta: 1)
        document = try #require(history.undo(current: document)).document
        #expect(history.canRedo)

        history.record(document, label: "Second")
        #expect(!history.canRedo, "recording a change must abandon the redo branch")
        #expect(history.undoLabel == "Second")
    }

    @Test("A continuous gesture coalesces into one undo step")
    func coalescingProducesOneStep() {
        var history = EditorHistory()
        let document = TestDocuments.singleClipVideo(duration: 15)

        for _ in 0..<20 {
            history.record(document, label: "Exposure", token: "adjust.exposure")
        }
        #expect(history.undoStack.count == 1)

        history.endCoalescing()
        history.record(document, label: "Exposure", token: "adjust.exposure")
        #expect(history.undoStack.count == 2, "a new gesture after the last one ends is a new step")
    }

    @Test("Different tokens are separate steps")
    func differentTokensAreSeparateSteps() {
        var history = EditorHistory()
        let document = TestDocuments.singleClipVideo()

        history.record(document, label: "Exposure", token: "adjust.exposure")
        history.record(document, label: "Contrast", token: "adjust.contrast")
        #expect(history.undoStack.count == 2)
    }

    @Test("History is bounded")
    func historyIsBounded() {
        var history = EditorHistory()
        let document = TestDocuments.singleClipVideo()
        for index in 0..<(EditorHistory.limit + 40) {
            history.record(document, label: "Change \(index)")
        }
        #expect(history.undoStack.count == EditorHistory.limit)
    }

    @Test("Undo on an empty history does nothing")
    func undoWhenEmpty() {
        var history = EditorHistory()
        let document = TestDocuments.singleClipVideo()
        #expect(history.undo(current: document) == nil)
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    @Test("Undo covers compound operations as a single step")
    func compoundOperationIsOneStep() throws {
        var history = EditorHistory()
        var document = TestDocuments.singleClipVideo(duration: 15)

        // Remove Range is several internal edits but one user action.
        history.record(document, label: "Remove Range")
        _ = try document.removeRange(TimeRange(start: 3, duration: 5))
        #expect(document.videoTrack.count == 2)

        document = try #require(history.undo(current: document)).document
        #expect(document.videoTrack.count == 1)
        #expect(abs(document.duration - 15) < 0.001)
    }
}
