import Foundation
import Testing
@testable import Frames

@Suite("Selection")
struct EditorSelectionTests {

    @Test("Selection carries the object's identifier")
    func identifiers() {
        let id = UUID()
        #expect(EditorSelection.clip(id).identifier == id)
        #expect(EditorSelection.text(id).identifier == id)
        #expect(EditorSelection.none.identifier == nil)
    }

    @Test("Canvas layers are the ones that can be dragged")
    func canvasLayers() {
        let id = UUID()
        #expect(EditorSelection.text(id).isCanvasLayer)
        #expect(EditorSelection.imageOverlay(id).isCanvasLayer)
        #expect(EditorSelection.blur(id).isCanvasLayer)
        #expect(!EditorSelection.clip(id).isCanvasLayer)
        #expect(!EditorSelection.audio(id).isCanvasLayer)
        #expect(!EditorSelection.none.isCanvasLayer)
    }

    @Test("Every selection has an accessibility name")
    func accessibilityNames() {
        let id = UUID()
        let cases: [EditorSelection] = [
            .none, .clip(id), .text(id), .imageOverlay(id), .drawing(id),
            .blur(id), .audio(id), .selectiveAdjustment(id), .effect(id)
        ]
        for selection in cases {
            #expect(!selection.accessibilityName.isEmpty)
        }
    }
}

@Suite("Editing session")
@MainActor
struct EditorSessionTests {

    private func makeSession(_ document: EditDocument) -> EditorSession {
        EditorSession(document: document)
    }

    @Test("Every change through perform is undoable")
    func performIsUndoable() {
        let session = makeSession(TestDocuments.singleClipVideo(duration: 12))
        #expect(!session.canUndo)

        session.perform("Test") { $0.grade.adjustments[.exposure] = 0.4 }
        #expect(session.canUndo)
        #expect(session.document.grade.adjustments[.exposure] == 0.4)

        session.undo()
        #expect(session.document.grade.adjustments.isIdentity)
        #expect(session.canRedo)
    }

    @Test("A drag coalesces into one undo step")
    func coalescedDrag() {
        let session = makeSession(TestDocuments.photo())
        for step in 1...10 {
            session.setAdjustment(.contrast, to: Double(step) / 20, isFinal: false)
        }
        session.setAdjustment(.contrast, to: 0.5, isFinal: true)

        session.undo()
        #expect(session.document.grade.adjustments.isIdentity, "one drag is one undo step")
    }

    @Test("Selecting an object opens that object's tool")
    func selectionOpensTool() {
        let session = makeSession(TestDocuments.singleClipVideo())
        let clipID = session.document.videoTrack[0].id

        session.select(.clip(clipID))
        #expect(session.tool == .cut)

        let textID = session.addText()
        session.select(.text(textID))
        #expect(session.tool == .text)
    }

    @Test("Undo drops a selection pointing at something that no longer exists")
    func selectionIsReconciled() {
        let session = makeSession(TestDocuments.singleClipVideo())
        let textID = session.addText()
        session.select(.text(textID))
        #expect(session.selection == .text(textID))

        session.undo()
        #expect(session.selection == .none)
    }

    @Test("Splitting selects the new clip")
    func splitSelectsNewClip() {
        let session = makeSession(TestDocuments.singleClipVideo(duration: 12))
        session.seek(to: 5)
        session.splitAtPlayhead()

        #expect(session.document.videoTrack.count == 2)
        #expect(session.selection == .clip(session.document.videoTrack[1].id))
    }

    @Test("Remove Range starts with a visible band around the playhead")
    func rangeSelectionStartsVisible() {
        let session = makeSession(TestDocuments.singleClipVideo(duration: 12))
        session.seek(to: 6)
        session.beginRangeSelection()

        let range = session.pendingRemovalRange
        #expect(range != nil)
        #expect((range?.duration ?? 0) > 0.2, "an invisible zero-width band is not draggable")
        #expect((range?.start ?? -1) >= 0)
        #expect((range?.end ?? 99) <= session.document.duration + 0.001)
    }

    @Test("Committing a range removal shortens the edit and clears the band")
    func commitRangeRemoval() {
        let session = makeSession(TestDocuments.singleClipVideo(duration: 12))
        session.pendingRemovalRange = TimeRange(start: 3, duration: 4)
        #expect(session.commitRangeRemoval())

        #expect(abs(session.document.duration - 8) < 0.001)
        #expect(session.pendingRemovalRange == nil)

        session.undo()
        #expect(abs(session.document.duration - 12) < 0.001)
    }

    @Test("An impossible range removal is refused and changes nothing")
    func refusedRangeRemoval() {
        let session = makeSession(TestDocuments.singleClipVideo(duration: 12))
        session.pendingRemovalRange = TimeRange(start: 0, duration: 12)
        #expect(!session.commitRangeRemoval())
        #expect(abs(session.document.duration - 12) < 0.001)
    }

    @Test("A text layer created but never typed into is discarded")
    func emptyTextIsDiscarded() {
        let session = makeSession(TestDocuments.photo())
        let id = session.addText()
        #expect(session.document.textOverlays.count == 1)

        session.discardEmptyText(id)
        #expect(session.document.textOverlays.isEmpty)
        #expect(session.selection == .none)
    }

    @Test("A text layer with content is not discarded")
    func filledTextSurvives() {
        let session = makeSession(TestDocuments.photo())
        let id = session.addText()
        session.updateText(id) { $0.string = "Hello" }

        session.discardEmptyText(id)
        #expect(session.document.textOverlays.count == 1)
    }

    @Test("Adding an effect twice replaces rather than stacks")
    func effectsDoNotStack() {
        let session = makeSession(TestDocuments.photo())
        _ = session.addEffect(.grain)
        _ = session.addEffect(.grain)
        #expect(session.document.effects.count == 1)

        _ = session.addEffect(.bloom)
        #expect(session.document.effects.count == 2)

        session.removeEffect(kind: .grain)
        #expect(session.document.effects.map(\.kind) == [.bloom])
    }

    @Test("Text on a video gets a range around the playhead, not the whole video")
    func textGetsSensibleTiming() {
        let session = makeSession(TestDocuments.singleClipVideo(duration: 30))
        session.seek(to: 10)
        let id = session.addText()

        let overlay = session.document.textOverlays.first { $0.id == id }
        #expect(overlay?.timeRange != nil)
        #expect(abs((overlay?.timeRange?.start ?? 0) - 10) < 0.001)
        #expect((overlay?.timeRange?.duration ?? 0) <= 3.001)
    }

    @Test("Text on a photo is always visible")
    func photoTextHasNoRange() {
        let session = makeSession(TestDocuments.photo())
        let id = session.addText()
        let overlay = session.document.textOverlays.first { $0.id == id }
        #expect(overlay?.timeRange == nil)
    }

    @Test("Blur scopes create the mask their scope implies")
    func blurScopesCreateMasks() {
        let session = makeSession(TestDocuments.photo())

        _ = session.addBlur(scope: .full)
        #expect(session.document.blurRegions.last?.mask == nil, "a full blur has nothing to mask")

        _ = session.addBlur(scope: .area)
        #expect(session.document.blurRegions.last?.mask?.shape.isManipulable == true)

        _ = session.addBlur(scope: .background)
        #expect(session.document.blurRegions.last?.mask?.shape.isDetected == true)
        #expect(session.document.blurRegions.last?.invertsSubject == true)
    }

    @Test("Seeking is clamped to the edit")
    func seekIsClamped() {
        let session = makeSession(TestDocuments.singleClipVideo(duration: 10))
        session.seek(to: -5)
        #expect(session.currentTime == 0)
        session.seek(to: 99)
        #expect(abs(session.currentTime - 10) < 0.001)
    }

    @Test("Snapping finds clip edges and ignores distant ones")
    func snapping() {
        let session = makeSession(TestDocuments.threeClipVideo())
        #expect(session.snappedTime(5.05, tolerance: 0.2) == 5)
        #expect(session.snappedTime(7.5, tolerance: 0.2) == nil)
    }

    @Test("The active clip falls back to the one under the playhead")
    func activeClipFallsBackToPlayhead() {
        let session = makeSession(TestDocuments.threeClipVideo())
        session.seek(to: 7)
        #expect(session.activeClipID == session.document.videoTrack[1].id)

        session.select(.clip(session.document.videoTrack[2].id))
        #expect(session.activeClipID == session.document.videoTrack[2].id)
    }
}

@Suite("Auto Enhance")
struct AutoEnhanceTests {

    private func measurements(
        mean: Double = 0.46,
        shadow: Double = 0.03,
        highlight: Double = 0.95,
        saturation: Double = 0.35,
        balance: Double = 0
    ) -> AutoEnhanceAnalyzer.Measurements {
        AutoEnhanceAnalyzer.Measurements(
            meanLuminance: mean,
            shadowLevel: shadow,
            highlightLevel: highlight,
            meanSaturation: saturation,
            redBlueBalance: balance
        )
    }

    @Test("A well-exposed frame is barely touched")
    func neutralFrame() {
        let set = AutoEnhanceAnalyzer.adjustments(for: measurements())
        #expect(!set.isActive(.exposure))
        #expect(set.isActive(.definition), "a little local contrast is always worth it")
    }

    @Test("A dark frame is brightened")
    func darkFrame() {
        let set = AutoEnhanceAnalyzer.adjustments(for: measurements(mean: 0.18))
        #expect(set[.exposure] > 0)
    }

    @Test("A bright frame is pulled down")
    func brightFrame() {
        let set = AutoEnhanceAnalyzer.adjustments(for: measurements(mean: 0.78))
        #expect(set[.exposure] < 0)
    }

    @Test("Lifted blacks are restored")
    func liftedBlacks() {
        let set = AutoEnhanceAnalyzer.adjustments(for: measurements(shadow: 0.3))
        #expect(set[.blackPoint] > 0)
    }

    @Test("A flat frame gets contrast")
    func flatFrame() {
        let set = AutoEnhanceAnalyzer.adjustments(for: measurements(shadow: 0.3, highlight: 0.62))
        #expect(set[.contrast] > 0)
    }

    @Test("A dull frame gets vibrance rather than saturation")
    func dullFrame() {
        let set = AutoEnhanceAnalyzer.adjustments(for: measurements(saturation: 0.05))
        #expect(set[.vibrance] > 0)
        #expect(!set.isActive(.saturation))
    }

    @Test("A colour cast is corrected in the right direction")
    func colourCast() {
        let warmCast = AutoEnhanceAnalyzer.adjustments(for: measurements(balance: 0.2))
        #expect(warmCast[.warmth] < 0, "a red-heavy frame is cooled")

        let coolCast = AutoEnhanceAnalyzer.adjustments(for: measurements(balance: -0.2))
        #expect(coolCast[.warmth] > 0)
    }

    @Test("Nothing Auto produces is extreme")
    func resultsAreBounded() {
        let extremes = [
            measurements(mean: 0.01, shadow: 0.0, highlight: 0.02, saturation: 0, balance: -0.9),
            measurements(mean: 0.99, shadow: 0.9, highlight: 1.0, saturation: 1, balance: 0.9)
        ]
        for measurement in extremes {
            let set = AutoEnhanceAnalyzer.adjustments(for: measurement)
            for parameter in set.activeParameters {
                #expect(abs(set[parameter]) <= 0.55, "\(parameter.rawValue) went too far")
            }
        }
    }

    @Test("Auto is ordinary editable data")
    func resultIsEditable() {
        var set = AutoEnhanceAnalyzer.adjustments(for: measurements(mean: 0.2))
        set[.exposure] = 0
        #expect(!set.isActive(.exposure), "the user can always undo one of Auto's decisions")
    }
}
