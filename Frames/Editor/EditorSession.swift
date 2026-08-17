import Foundation
import Observation
import OSLog

/// The tool whose controls are currently showing in the bottom area.
enum EditorTool: String, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case cut
    case crop
    case adjust
    case filters
    case blur
    case text
    case effects
    case background
    case audio
    case draw
    case speed
    case overlay
    case retouch

    var id: String { rawValue }
}

/// Owns one edit: the document, its history, what is selected, and where the
/// playhead is.
///
/// Everything the renderer needs is in `document`. Everything the *interface*
/// needs and the render does not — selection, the open tool, the playhead — is
/// kept here and deliberately not persisted, so reopening a recovered edit puts
/// the user back at the start of their media rather than in a half-open panel.
@MainActor
@Observable
final class EditorSession {
    // MARK: Document

    private(set) var document: EditDocument

    private var history = EditorHistory()

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var undoLabel: String? { history.undoLabel }
    var redoLabel: String? { history.redoLabel }

    // MARK: Interface state

    /// Set through `select(_:)` so choosing an object and opening its controls
    /// can never come apart.
    private(set) var selection: EditorSelection = .none

    var tool: EditorTool = .none
    /// The parameter the Adjust strip has expanded into a large slider.
    var focusedAdjustment: AdjustmentParameter?
    /// True while the user is holding the canvas to compare with the original.
    var isShowingOriginal = false
    /// Range selection mode, used by Remove Range.
    var pendingRemovalRange: TimeRange?

    // MARK: Playback

    /// Current playhead position in timeline seconds.
    var currentTime: TimeInterval = 0
    var isPlaying = false
    /// Seconds per screen point at the current timeline zoom.
    var timelineZoom: Double = 1

    // MARK: Wiring

    let store: SessionRecoveryStore
    private var autosaveTask: Task<Void, Never>?
    private let logger = FramesLog.editor

    init(document: EditDocument, store: SessionRecoveryStore = SessionRecoveryStore()) {
        self.document = document
        self.store = store
    }

    // MARK: - Mutation

    /// The single door through which every change to the document goes.
    ///
    /// Recording the pre-change snapshot here — rather than at each call site —
    /// is what guarantees that nothing in the app can change the edit without
    /// being undoable.
    func perform(
        _ label: String,
        coalescing token: String? = nil,
        _ mutate: (inout EditDocument) -> Void
    ) {
        history.record(document, label: label, token: token)
        var copy = document
        mutate(&copy)
        copy.touch()
        document = copy
        scheduleAutosave()
        #if DEBUG
        if copy.kind == .video, !copy.timelineIsValid {
            logger.fault("Timeline invariant broken after: \(label, privacy: .public)")
        }
        #endif
    }

    /// Ends a coalescing group. Call when a continuous gesture finishes.
    func endInteraction() {
        history.endCoalescing()
    }

    /// A change that must not create an undo step — currently only the
    /// housekeeping the app itself does, never anything the user can see.
    func mutateWithoutHistory(_ mutate: (inout EditDocument) -> Void) {
        var copy = document
        mutate(&copy)
        document = copy
        scheduleAutosave()
    }

    func undo() {
        guard let entry = history.undo(current: document) else { return }
        document = entry.document
        scheduleAutosave()
        reconcileSelection()
        logger.debug("Undo: \(entry.label, privacy: .public)")
    }

    func redo() {
        guard let entry = history.redo(current: document) else { return }
        document = entry.document
        scheduleAutosave()
        reconcileSelection()
        logger.debug("Redo: \(entry.label, privacy: .public)")
    }

    /// Drops a selection that points at something undo has just removed.
    private func reconcileSelection() {
        guard let id = selection.identifier else { return }
        let exists: Bool
        switch selection {
        case .none: exists = true
        case .clip: exists = document.videoTrack.contains { $0.id == id }
        case .text: exists = document.textOverlays.contains { $0.id == id }
        case .imageOverlay: exists = document.imageOverlays.contains { $0.id == id }
        case .drawing: exists = document.drawings.contains { $0.id == id }
        case .blur: exists = document.blurRegions.contains { $0.id == id }
        case .audio: exists = document.audioClips.contains { $0.id == id }
        case .selectiveAdjustment: exists = document.selectiveAdjustments.contains { $0.id == id }
        case .effect: exists = document.effects.contains { $0.id == id }
        }
        if !exists { selection = .none }
        currentTime = min(currentTime, max(document.duration, 0))
    }

    // MARK: - Selection

    /// The tool a freshly selected object should open with. Selecting a clip
    /// shows clip controls immediately rather than making the user hunt for
    /// them.
    private func defaultTool(for selection: EditorSelection) -> EditorTool {
        switch selection {
        case .none: .none
        case .clip: .cut
        case .text: .text
        case .imageOverlay: .overlay
        case .drawing: .draw
        case .blur: .blur
        case .audio: .audio
        case .selectiveAdjustment: .adjust
        case .effect: .effects
        }
    }

    func select(_ newSelection: EditorSelection) {
        guard newSelection != selection else { return }
        selection = newSelection
        tool = defaultTool(for: newSelection)
        focusedAdjustment = nil
    }

    /// Selects an object without changing which tool is open — used when a
    /// tool creates the object it is about to edit.
    func selectKeepingTool(_ newSelection: EditorSelection) {
        selection = newSelection
    }

    func clearSelection() {
        selection = .none
        tool = .none
        focusedAdjustment = nil
    }

    /// The clip under the playhead, which is what clip-level actions apply to
    /// when nothing is explicitly selected.
    var activeClipID: UUID? {
        if case .clip(let id) = selection { return id }
        return document.clip(at: currentTime)?.clip.id
    }

    // MARK: - Playhead

    func seek(to time: TimeInterval) {
        currentTime = min(max(time, 0), max(document.duration, 0))
    }

    /// Snaps to the nearest clip edge or keyframe if one is within `tolerance`.
    func snappedTime(_ time: TimeInterval, tolerance: TimeInterval) -> TimeInterval? {
        var best: (time: TimeInterval, distance: TimeInterval)?
        for point in document.snapPoints {
            let distance = abs(point - time)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance {
                best = (point, distance)
            }
        }
        return best?.time
    }

    // MARK: - Persistence

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = document
        autosaveTask = Task { [store, logger] in
            // Debounced: a drag produces dozens of mutations a second and none
            // of them are worth a disk write on their own.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                try await store.save(snapshot)
            } catch {
                logger.error("Autosave failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes immediately, for backgrounding and termination.
    func saveNow() async {
        autosaveTask?.cancel()
        do {
            try await store.save(document)
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called after a successful export, or when the user discards the edit.
    func finish() async {
        autosaveTask?.cancel()
        await store.discard()
        SessionPaths.pruneScratch()
    }
}
