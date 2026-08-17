import SwiftUI

/// Routes the current detail to the controls for it.
///
/// Every branch here is a real set of controls. Nothing in this switch shows a
/// placeholder, because a control that does nothing is worse than no control.
struct EditorInspector: View {
    let session: EditorSession
    let playback: PlaybackEngine
    let detail: EditorDetail
    let onDone: () -> Void

    var body: some View {
        switch detail {
        case .cut, .trim:
            TrimInspector(session: session, playback: playback, onDone: onDone)
        case .removeRange:
            RemoveRangeInspector(session: session, onDone: onDone)
        case .speed:
            SpeedInspector(session: session, onDone: onDone)
        case .volume:
            VolumeInspector(session: session, onDone: onDone)
        case .crop:
            CropInspector(session: session, onDone: onDone)
        case .transition:
            TransitionInspector(session: session, onDone: onDone)
        case .adjust:
            AdjustInspector(session: session, onDone: onDone)
        case .filters:
            FilterInspector(session: session, onDone: onDone)
        case .blur, .blurType, .blurStrength, .blurMask:
            BlurInspector(session: session, focus: detail, onDone: onDone)
        case .tracking:
            TrackingInspector(session: session, playback: playback, onDone: onDone)
        case .text, .textContent, .font, .textStyle, .textColor, .textAlignment, .textAnimation:
            TextInspector(session: session, focus: detail, onDone: onDone)
        case .timing:
            TimingInspector(session: session, onDone: onDone)
        case .more:
            MoreToolsInspector(session: session, onDone: onDone)
        case .effects:
            EffectsInspector(session: session, onDone: onDone)
        case .background:
            BackgroundInspector(session: session, onDone: onDone)
        case .audio, .audioTrim, .fade:
            AudioInspector(session: session, focus: detail, onDone: onDone)
        case .draw, .shapes:
            DrawInspector(session: session, focus: detail, onDone: onDone)
        case .overlayStyle, .overlayOpacity, .removeBackground:
            OverlayInspector(session: session, focus: detail, onDone: onDone)
        case .retouch:
            RetouchInspector(session: session, onDone: onDone)
        case .portrait:
            PortraitInspector(session: session)
        }
    }
}
