import SwiftUI

/// The timeline.
///
/// The playhead is fixed at the centre and the content moves under it. That is
/// what makes a single drag do the obvious thing — scrubbing and scrolling are
/// the same gesture — and it means the frame the user is judging is always in
/// the same place on screen.
///
/// Tracks only exist when there is something on them. A plain video edit shows
/// one strip; text, audio and overlays each add a row the moment they are used.
struct TimelineView: View {
    let session: EditorSession
    let playback: PlaybackEngine

    @State private var scale = TimelineScale.default
    @State private var scaleAtGestureStart: TimelineScale?
    @State private var timeAtDragStart: TimeInterval?
    @State private var lastSnapPoint: TimeInterval?
    @State private var hasSizedToFit = false
    @State private var draggingClipID: UUID?
    @State private var reorderOffset: CGFloat = 0

    private let clipHeight: CGFloat = 52
    private let secondaryTrackHeight: CGFloat = 22
    private let rulerHeight: CGFloat = 18

    private var document: EditDocument { session.document }

    var body: some View {
        GeometryReader { proxy in
            let centre = proxy.size.width / 2
            let offset = centre - scale.point(for: session.currentTime)

            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())

                VStack(alignment: .leading, spacing: 5) {
                    TimelineRuler(scale: scale, duration: document.duration)
                        .frame(height: rulerHeight)

                    videoTrack

                    if !document.textOverlays.isEmpty || !document.imageOverlays.isEmpty
                        || !document.drawings.isEmpty || !document.blurRegions.isEmpty {
                        overlayTrack
                    }

                    if !document.audioClips.isEmpty {
                        audioTrack
                    }
                }
                .offset(x: offset)
                .animation(nil, value: session.currentTime)

                if let range = session.pendingRemovalRange {
                    RangeSelectionOverlay(
                        range: range,
                        scale: scale,
                        offset: offset,
                        height: rulerHeight + clipHeight + 5
                    ) { updated in
                        session.pendingRemovalRange = updated
                    }
                }

                TimelinePlayhead(height: totalHeight)
                    .position(x: centre, y: totalHeight / 2)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(scrubGesture)
            .simultaneousGesture(zoomGesture(viewportWidth: proxy.size.width))
            .onAppear {
                guard !hasSizedToFit, document.duration > 0 else { return }
                hasSizedToFit = true
                scale = TimelineScale.fitting(
                    duration: document.duration,
                    in: max(proxy.size.width - 32, 80)
                )
            }
        }
        .frame(height: totalHeight)
        // Time runs left to right everywhere, including in right-to-left
        // interfaces — the same choice Apple's own editors make. Mirroring the
        // timeline would put "later" on the left while the playhead, the
        // scrubbing direction and every video convention say otherwise.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Timeline", comment: "Accessibility label"))
    }

    private var totalHeight: CGFloat {
        var height = rulerHeight + clipHeight + 10
        if !document.textOverlays.isEmpty || !document.imageOverlays.isEmpty
            || !document.drawings.isEmpty || !document.blurRegions.isEmpty {
            height += secondaryTrackHeight + 5
        }
        if !document.audioClips.isEmpty {
            height += secondaryTrackHeight + 5
        }
        return height
    }

    // MARK: - Tracks

    private var videoTrack: some View {
        HStack(spacing: 0) {
            ForEach(Array(document.videoTrack.enumerated()), id: \.element.id) { index, clip in
                TimelineClipView(
                    clip: clip,
                    asset: document.asset(id: clip.assetID),
                    scale: scale,
                    isSelected: session.selection == .clip(clip.id),
                    height: clipHeight
                )
                .opacity(draggingClipID == clip.id ? 0.55 : 1)
                .scaleEffect(draggingClipID == clip.id ? 1.04 : 1)
                .offset(x: draggingClipID == clip.id ? reorderOffset : 0)
                .zIndex(draggingClipID == clip.id ? 1 : 0)
                .onTapGesture {
                    session.select(.clip(clip.id))
                    Haptics.snap()
                }
                // Long press then drag to reorder, so an ordinary horizontal
                // drag still scrubs the timeline rather than picking a clip up
                // by accident.
                .gesture(reorderGesture(clipID: clip.id, index: index))
                .overlay(alignment: .leading) {
                    if index > 0, clip.transitionIn.isActive {
                        TransitionBadge(kind: clip.transitionIn.kind)
                            .offset(x: -9)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: draggingClipID)
    }

    private func reorderGesture(clipID: UUID, index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    if draggingClipID != clipID {
                        draggingClipID = clipID
                        session.select(.clip(clipID))
                        Haptics.edit()
                    }
                    reorderOffset = drag?.translation.width ?? 0
                default:
                    break
                }
            }
            .onEnded { _ in
                defer {
                    draggingClipID = nil
                    reorderOffset = 0
                }
                guard draggingClipID == clipID else { return }
                let destination = destinationIndex(from: index, offset: reorderOffset)
                guard destination != index else { return }
                session.moveClip(from: index, to: destination)
            }
    }

    /// Where a dragged clip lands: the first position whose accumulated width
    /// the drag has passed. Measuring in widths rather than in a fixed step
    /// means short clips are as easy to move as long ones.
    private func destinationIndex(from index: Int, offset: CGFloat) -> Int {
        guard offset != 0 else { return index }
        var destination = index
        var travelled: CGFloat = 0

        if offset > 0 {
            var next = index + 1
            while next < document.videoTrack.count {
                travelled += scale.width(for: document.videoTrack[next].timelineDuration)
                if offset < travelled - scale.width(for: document.videoTrack[next].timelineDuration) / 2 {
                    break
                }
                destination = next
                next += 1
            }
        } else {
            var previous = index - 1
            while previous >= 0 {
                travelled += scale.width(for: document.videoTrack[previous].timelineDuration)
                if -offset < travelled - scale.width(for: document.videoTrack[previous].timelineDuration) / 2 {
                    break
                }
                destination = previous
                previous -= 1
            }
        }
        return destination
    }

    private var overlayTrack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(document.textOverlays) { overlay in
                secondaryChip(
                    range: overlay.timeRange ?? TimeRange(start: 0, duration: document.duration),
                    label: overlay.string.isEmpty
                        ? String(localized: "Text", comment: "Timeline chip")
                        : overlay.string,
                    symbol: "textformat",
                    tint: .orange,
                    isSelected: session.selection == .text(overlay.id)
                ) {
                    session.select(.text(overlay.id))
                }
            }
            ForEach(document.imageOverlays) { overlay in
                secondaryChip(
                    range: overlay.timeRange ?? TimeRange(start: 0, duration: document.duration),
                    label: String(localized: "Image", comment: "Timeline chip"),
                    symbol: "photo",
                    tint: .purple,
                    isSelected: session.selection == .imageOverlay(overlay.id)
                ) {
                    session.select(.imageOverlay(overlay.id))
                }
            }
            ForEach(document.blurRegions) { region in
                secondaryChip(
                    range: region.timeRange ?? TimeRange(start: 0, duration: document.duration),
                    label: region.displayName,
                    symbol: region.scope.symbolName,
                    tint: .teal,
                    isSelected: session.selection == .blur(region.id)
                ) {
                    session.select(.blur(region.id))
                }
            }
            ForEach(document.drawings) { drawing in
                secondaryChip(
                    range: drawing.timeRange ?? TimeRange(start: 0, duration: document.duration),
                    label: String(localized: "Drawing", comment: "Timeline chip"),
                    symbol: "scribble",
                    tint: .pink,
                    isSelected: session.selection == .drawing(drawing.id)
                ) {
                    session.select(.drawing(drawing.id))
                }
            }
        }
        .frame(height: secondaryTrackHeight, alignment: .topLeading)
    }

    private var audioTrack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(document.audioClips) { clip in
                AudioClipChip(
                    clip: clip,
                    asset: document.asset(id: clip.assetID),
                    scale: scale,
                    height: secondaryTrackHeight,
                    isSelected: session.selection == .audio(clip.id)
                )
                .offset(x: scale.point(for: clip.timelineStart))
                .onTapGesture { session.select(.audio(clip.id)) }
            }
        }
        .frame(height: secondaryTrackHeight, alignment: .topLeading)
    }

    private func secondaryChip(
        range: TimeRange,
        label: String,
        symbol: String,
        tint: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: max(scale.width(for: range.duration), 18), height: secondaryTrackHeight, alignment: .leading)
        .background(tint.opacity(isSelected ? 0.95 : 0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 1.5)
            }
        }
        .offset(x: scale.point(for: range.start))
        .onTapGesture(perform: action)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Gestures

    /// Dragging moves the content under the playhead, which is both scrolling
    /// and scrubbing.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if timeAtDragStart == nil {
                    timeAtDragStart = session.currentTime
                    playback.beginScrubbing()
                    Haptics.prepare()
                }
                guard let start = timeAtDragStart else { return }

                let proposed = start - scale.time(for: value.translation.width)
                let clamped = min(max(proposed, 0), max(document.duration, 0))
                let snapped = session.snappedTime(clamped, tolerance: scale.snapTolerance)

                if let snapped {
                    if lastSnapPoint != snapped {
                        lastSnapPoint = snapped
                        Haptics.snap()
                    }
                    session.seek(to: snapped)
                    playback.seek(to: snapped)
                } else {
                    lastSnapPoint = nil
                    session.seek(to: clamped)
                    playback.seek(to: clamped)
                }
            }
            .onEnded { _ in
                timeAtDragStart = nil
                lastSnapPoint = nil
                playback.endScrubbing()
                playback.seek(to: session.currentTime, precise: true)
            }
    }

    /// Pinch zooms around the playhead, which is the point the user is looking
    /// at, so the frame under it does not move.
    private func zoomGesture(viewportWidth: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let base = scaleAtGestureStart ?? scale
                if scaleAtGestureStart == nil {
                    scaleAtGestureStart = scale
                    Haptics.prepare()
                }
                let updated = base.scaled(by: value.magnification)
                if updated.isAtMinimum != scale.isAtMinimum || updated.isAtMaximum != scale.isAtMaximum {
                    Haptics.boundary()
                }
                scale = updated
                session.timelineZoom = Double(updated.pointsPerSecond)
            }
            .onEnded { _ in
                scaleAtGestureStart = nil
            }
    }
}

/// The fixed centre marker.
struct TimelinePlayhead: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.primary)
                .frame(width: 2, height: height)
            Circle()
                .fill(Color.primary)
                .frame(width: 8, height: 8)
                .offset(y: -height / 2 + 4)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 0)
        .accessibilityHidden(true)
    }
}

/// Ticks and times above the clips.
struct TimelineRuler: View {
    let scale: TimelineScale
    let duration: TimeInterval

    var body: some View {
        let interval = scale.tickInterval
        let count = max(Int(ceil(duration / max(interval, 0.001))) + 1, 1)

        ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { index in
                let time = Double(index) * interval
                VStack(alignment: .leading, spacing: 1) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 5)
                    Text(time.framesShortTimecode)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .offset(x: scale.point(for: time))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small marker where a transition sits between two clips.
struct TransitionBadge: View {
    let kind: TransitionKind

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color.black.opacity(0.55), in: Circle())
            .accessibilityLabel(kind.displayName)
    }
}
