import SwiftUI

/// The contextual bottom area.
///
/// Two rows at most: the controls for whatever is being edited, and the strip
/// of actions for whatever is selected. When nothing is selected, the strip is
/// the app's top-level tools. That is the entire navigation model — there are
/// no panels to back out of.
struct EditorBottomArea: View {
    let session: EditorSession
    let playback: PlaybackEngine
    @Binding var detail: EditorDetail?

    var body: some View {
        VStack(spacing: 10) {
            if let detail {
                EditorInspector(session: session, playback: playback, detail: detail) {
                    self.detail = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ToolStrip(items: items, selected: detail?.rawValue) { id in
                handle(id)
            }
            .frame(height: 62)
        }
        .animation(.snappy(duration: 0.25), value: detail)
        .animation(.snappy(duration: 0.25), value: session.selection)
    }

    // MARK: - Strips

    private var items: [ToolStripItem] {
        switch session.selection {
        case .none:
            session.document.kind == .video ? Self.videoTools : Self.photoTools
        case .clip:
            Self.clipTools
        case .text:
            Self.textTools
        case .blur:
            Self.blurTools
        case .audio:
            Self.audioTools
        case .imageOverlay:
            Self.imageOverlayTools
        case .drawing:
            Self.drawingTools
        case .selectiveAdjustment:
            Self.selectiveTools
        case .effect:
            Self.videoTools
        }
    }

    static let videoTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.cut.rawValue,
                      title: String(localized: "Cut", comment: "Tool"), symbol: "scissors"),
        ToolStripItem(id: EditorDetail.adjust.rawValue,
                      title: String(localized: "Adjust", comment: "Tool"), symbol: "slider.horizontal.3"),
        ToolStripItem(id: EditorDetail.filters.rawValue,
                      title: String(localized: "Filters", comment: "Tool"), symbol: "camera.filters"),
        ToolStripItem(id: EditorDetail.blur.rawValue,
                      title: String(localized: "Blur", comment: "Tool"), symbol: "drop.halffull"),
        ToolStripItem(id: EditorDetail.text.rawValue,
                      title: String(localized: "Text", comment: "Tool"), symbol: "textformat"),
        ToolStripItem(id: EditorDetail.more.rawValue,
                      title: String(localized: "More", comment: "Tool"), symbol: "plus")
    ]

    static let photoTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.crop.rawValue,
                      title: String(localized: "Crop", comment: "Tool"), symbol: "crop"),
        ToolStripItem(id: EditorDetail.adjust.rawValue,
                      title: String(localized: "Adjust", comment: "Tool"), symbol: "slider.horizontal.3"),
        ToolStripItem(id: EditorDetail.filters.rawValue,
                      title: String(localized: "Filters", comment: "Tool"), symbol: "camera.filters"),
        ToolStripItem(id: EditorDetail.blur.rawValue,
                      title: String(localized: "Blur", comment: "Tool"), symbol: "drop.halffull"),
        ToolStripItem(id: EditorDetail.text.rawValue,
                      title: String(localized: "Text", comment: "Tool"), symbol: "textformat"),
        ToolStripItem(id: EditorDetail.more.rawValue,
                      title: String(localized: "More", comment: "Tool"), symbol: "plus")
    ]

    static let clipTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.trim.rawValue,
                      title: String(localized: "Trim", comment: "Clip action"), symbol: "timeline.selection"),
        ToolStripItem(id: "split",
                      title: String(localized: "Split", comment: "Clip action"), symbol: "scissors"),
        ToolStripItem(id: "removeRange",
                      title: String(localized: "Remove Range", comment: "Clip action"), symbol: "rectangle.compress.vertical"),
        ToolStripItem(id: EditorDetail.speed.rawValue,
                      title: String(localized: "Speed", comment: "Clip action"), symbol: "speedometer"),
        ToolStripItem(id: EditorDetail.volume.rawValue,
                      title: String(localized: "Volume", comment: "Clip action"), symbol: "speaker.wave.2"),
        ToolStripItem(id: EditorDetail.crop.rawValue,
                      title: String(localized: "Crop", comment: "Clip action"), symbol: "crop"),
        ToolStripItem(id: EditorDetail.transition.rawValue,
                      title: String(localized: "Transition", comment: "Clip action"), symbol: "square.on.square.intersection.dashed"),
        ToolStripItem(id: "duplicate",
                      title: String(localized: "Duplicate", comment: "Clip action"), symbol: "plus.square.on.square"),
        ToolStripItem(id: "delete",
                      title: String(localized: "Delete", comment: "Clip action"), symbol: "trash", isDestructive: true)
    ]

    static let textTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.textContent.rawValue,
                      title: String(localized: "Edit", comment: "Text action"), symbol: "character.cursor.ibeam"),
        ToolStripItem(id: EditorDetail.font.rawValue,
                      title: String(localized: "Font", comment: "Text action"), symbol: "textformat.size"),
        ToolStripItem(id: EditorDetail.textStyle.rawValue,
                      title: String(localized: "Style", comment: "Text action"), symbol: "paintbrush"),
        ToolStripItem(id: EditorDetail.textColor.rawValue,
                      title: String(localized: "Color", comment: "Text action"), symbol: "paintpalette"),
        ToolStripItem(id: EditorDetail.textAlignment.rawValue,
                      title: String(localized: "Alignment", comment: "Text action"), symbol: "text.aligncenter"),
        ToolStripItem(id: EditorDetail.textAnimation.rawValue,
                      title: String(localized: "Animate", comment: "Text action"), symbol: "wand.and.stars"),
        ToolStripItem(id: EditorDetail.timing.rawValue,
                      title: String(localized: "Timing", comment: "Text action"), symbol: "clock"),
        ToolStripItem(id: "delete",
                      title: String(localized: "Delete", comment: "Text action"), symbol: "trash", isDestructive: true)
    ]

    static let blurTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.blurType.rawValue,
                      title: String(localized: "Type", comment: "Blur action"), symbol: "square.stack.3d.down.right"),
        ToolStripItem(id: EditorDetail.blurStrength.rawValue,
                      title: String(localized: "Strength", comment: "Blur action"), symbol: "dial.medium"),
        ToolStripItem(id: EditorDetail.blurMask.rawValue,
                      title: String(localized: "Mask", comment: "Blur action"), symbol: "circle.dashed"),
        ToolStripItem(id: EditorDetail.tracking.rawValue,
                      title: String(localized: "Tracking", comment: "Blur action"), symbol: "dot.viewfinder"),
        ToolStripItem(id: EditorDetail.timing.rawValue,
                      title: String(localized: "Timing", comment: "Blur action"), symbol: "clock"),
        ToolStripItem(id: "delete",
                      title: String(localized: "Delete", comment: "Blur action"), symbol: "trash", isDestructive: true)
    ]

    static let audioTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.volume.rawValue,
                      title: String(localized: "Volume", comment: "Audio action"), symbol: "speaker.wave.2"),
        ToolStripItem(id: EditorDetail.audioTrim.rawValue,
                      title: String(localized: "Trim", comment: "Audio action"), symbol: "timeline.selection"),
        ToolStripItem(id: "splitAudio",
                      title: String(localized: "Split", comment: "Audio action"), symbol: "scissors"),
        ToolStripItem(id: EditorDetail.fade.rawValue,
                      title: String(localized: "Fade", comment: "Audio action"), symbol: "waveform.path.ecg"),
        ToolStripItem(id: EditorDetail.speed.rawValue,
                      title: String(localized: "Speed", comment: "Audio action"), symbol: "speedometer"),
        ToolStripItem(id: "muteAudio",
                      title: String(localized: "Mute", comment: "Audio action"), symbol: "speaker.slash"),
        ToolStripItem(id: "delete",
                      title: String(localized: "Delete", comment: "Audio action"), symbol: "trash", isDestructive: true)
    ]

    static let imageOverlayTools: [ToolStripItem] = [
        ToolStripItem(id: "removeBackground",
                      title: String(localized: "Cut Out", comment: "Image action"), symbol: "person.and.background.dotted"),
        ToolStripItem(id: EditorDetail.overlayStyle.rawValue,
                      title: String(localized: "Style", comment: "Image action"), symbol: "paintbrush"),
        ToolStripItem(id: EditorDetail.overlayOpacity.rawValue,
                      title: String(localized: "Opacity", comment: "Image action"), symbol: "circle.lefthalf.filled"),
        ToolStripItem(id: EditorDetail.crop.rawValue,
                      title: String(localized: "Crop", comment: "Image action"), symbol: "crop"),
        ToolStripItem(id: EditorDetail.timing.rawValue,
                      title: String(localized: "Timing", comment: "Image action"), symbol: "clock"),
        ToolStripItem(id: "delete",
                      title: String(localized: "Delete", comment: "Image action"), symbol: "trash", isDestructive: true)
    ]

    static let drawingTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.draw.rawValue,
                      title: String(localized: "Draw", comment: "Drawing action"), symbol: "pencil.tip"),
        ToolStripItem(id: EditorDetail.shapes.rawValue,
                      title: String(localized: "Shapes", comment: "Drawing action"), symbol: "square.on.circle"),
        ToolStripItem(id: EditorDetail.overlayOpacity.rawValue,
                      title: String(localized: "Opacity", comment: "Drawing action"), symbol: "circle.lefthalf.filled"),
        ToolStripItem(id: EditorDetail.timing.rawValue,
                      title: String(localized: "Timing", comment: "Drawing action"), symbol: "clock"),
        ToolStripItem(id: "delete",
                      title: String(localized: "Delete", comment: "Drawing action"), symbol: "trash", isDestructive: true)
    ]

    static let selectiveTools: [ToolStripItem] = [
        ToolStripItem(id: EditorDetail.adjust.rawValue,
                      title: String(localized: "Adjust", comment: "Selective action"), symbol: "slider.horizontal.3"),
        ToolStripItem(id: EditorDetail.blurMask.rawValue,
                      title: String(localized: "Mask", comment: "Selective action"), symbol: "circle.dashed"),
        ToolStripItem(id: "delete",
                      title: String(localized: "Delete", comment: "Selective action"), symbol: "trash", isDestructive: true)
    ]

    // MARK: - Actions

    private func handle(_ id: String) {
        // A handful of strip items are actions rather than panels, because
        // making the user open a panel to press one button is the exact kind of
        // step this app is trying to remove.
        switch id {
        case "split":
            session.splitAtPlayhead()
            return
        case "removeRange":
            session.beginRangeSelection()
            detail = .removeRange
            return
        case "duplicate":
            session.duplicateSelectedClip()
            return
        case "delete":
            deleteSelection()
            return
        case "splitAudio":
            if case .audio(let audioID) = session.selection {
                session.splitAudioClipAtPlayhead(audioID)
            }
            return
        case "muteAudio":
            if case .audio(let audioID) = session.selection {
                session.updateAudioClip(audioID) { $0.isMuted.toggle() }
                Haptics.snap()
            }
            return
        case "removeBackground":
            detail = .removeBackground
            return
        default:
            break
        }

        guard let route = EditorDetail(rawValue: id) else { return }
        detail = detail == route ? nil : route
    }

    private func deleteSelection() {
        switch session.selection {
        case .clip: session.deleteSelectedClip()
        case .text(let id): session.deleteText(id)
        case .blur(let id): session.deleteBlur(id)
        case .audio(let id): session.deleteAudioClip(id)
        case .imageOverlay(let id): session.deleteImageOverlay(id)
        case .drawing(let id): session.deleteDrawing(id)
        case .selectiveAdjustment(let id): session.deleteSelectiveAdjustment(id)
        case .effect, .none: break
        }
        detail = nil
    }
}

/// Which set of controls the inspector is showing.
enum EditorDetail: String, Hashable, Identifiable {
    case cut
    case trim
    case removeRange
    case speed
    case volume
    case crop
    case transition
    case adjust
    case filters
    case blur
    case blurType
    case blurStrength
    case blurMask
    case tracking
    case text
    case textContent
    case font
    case textStyle
    case textColor
    case textAlignment
    case textAnimation
    case timing
    case more
    case effects
    case background
    case audio
    case audioTrim
    case fade
    case draw
    case shapes
    case overlayStyle
    case overlayOpacity
    case removeBackground
    case retouch
    case portrait

    var id: String { rawValue }
}
