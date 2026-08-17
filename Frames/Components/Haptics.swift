import SwiftUI
import UIKit

/// Haptic feedback, used sparingly.
///
/// Frames only buzzes when something *snapped* — a trim handle meeting a clip
/// edge, a text layer meeting the centre line, a split landing. Tapping a
/// button is not an event worth vibrating for, and an editor that buzzes
/// constantly stops communicating anything.
@MainActor
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notification = UINotificationFeedbackGenerator()

    /// Call before a gesture that will produce feedback, so the first tick is
    /// not late.
    static func prepare() {
        selection.prepare()
        impact.prepare()
        soft.prepare()
    }

    /// Crossing a snap point: a clip edge, a keyframe, the centre guide.
    static func snap() {
        guard !isReduced else { return }
        selection.selectionChanged()
    }

    /// A structural edit landed: split, delete, range removed.
    static func edit() {
        guard !isReduced else { return }
        impact.impactOccurred(intensity: 0.7)
    }

    /// Reaching a limit: the start or end of a clip, minimum duration.
    static func boundary() {
        guard !isReduced else { return }
        soft.impactOccurred(intensity: 0.55)
    }

    static func success() {
        guard !isReduced else { return }
        notification.notificationOccurred(.success)
    }

    static func failure() {
        guard !isReduced else { return }
        notification.notificationOccurred(.error)
    }

    /// Respects the system setting, which some people rely on rather than
    /// merely prefer.
    private static var isReduced: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
}
