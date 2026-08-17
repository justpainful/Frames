import Foundation

/// Undo and redo for the editor.
///
/// Frames stores whole-document snapshots rather than inverse commands. The
/// document is a value type of a few kilobytes and every operation is a pure
/// mutation of it, so a snapshot is cheap, always correct, and cannot drift out
/// of sync with the thing it is supposed to undo — which is exactly the failure
/// mode hand-written inverse operations have in editors like this one.
///
/// Continuous gestures (dragging a slider, dragging a trim handle) coalesce
/// into a single entry via a token, so one drag is one undo step.
struct EditorHistory {
    struct Entry: Equatable {
        var document: EditDocument
        var label: String
        var token: String?
    }

    /// Deep enough that a long editing session stays fully undoable, shallow
    /// enough that the memory cost stays in the low megabytes.
    static let limit = 100

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    /// Records the state *before* a change. Call this immediately before
    /// mutating the document.
    ///
    /// - Parameter token: identifies a continuous interaction. Two consecutive
    ///   records with the same non-nil token produce one undo step.
    mutating func record(_ document: EditDocument, label: String, token: String? = nil) {
        if let token, let last = undoStack.last, last.token == token {
            // Same gesture still in flight: keep the original "before" state.
            redoStack.removeAll()
            return
        }
        undoStack.append(Entry(document: document, label: label, token: token))
        if undoStack.count > Self.limit {
            undoStack.removeFirst(undoStack.count - Self.limit)
        }
        redoStack.removeAll()
    }

    /// Ends a coalescing group so the next change with the same token starts a
    /// new undo step. Called when a gesture ends.
    mutating func endCoalescing() {
        guard var last = undoStack.last else { return }
        guard last.token != nil else { return }
        last.token = nil
        undoStack[undoStack.count - 1] = last
    }

    /// Returns the document to restore, given the document currently on screen.
    mutating func undo(current: EditDocument) -> Entry? {
        guard var entry = undoStack.popLast() else { return nil }
        redoStack.append(Entry(document: current, label: entry.label, token: nil))
        entry.token = nil
        return entry
    }

    mutating func redo(current: EditDocument) -> Entry? {
        guard var entry = redoStack.popLast() else { return nil }
        undoStack.append(Entry(document: current, label: entry.label, token: nil))
        entry.token = nil
        return entry
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
