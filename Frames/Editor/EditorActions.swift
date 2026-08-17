import CoreGraphics
import Foundation

/// Every change a tool can make, in one place.
///
/// Views call these; they never mutate the document themselves. Each one goes
/// through `perform`, so each one is undoable, autosaved and validated without
/// the call site having to remember. Continuous interactions pass a coalescing
/// token so a whole drag becomes a single undo step.
@MainActor
extension EditorSession {

    // MARK: - Cut

    func splitAtPlayhead() {
        guard document.kind == .video else { return }
        var newClipID: UUID?
        perform(String(localized: "Split", comment: "Undo action")) { document in
            newClipID = try? document.split(at: self.currentTime)
        }
        if let newClipID {
            select(.clip(newClipID))
            Haptics.edit()
        } else {
            Haptics.failure()
        }
    }

    func beginRangeSelection() {
        guard document.kind == .video else { return }
        let duration = document.duration
        // Start with a couple of seconds around the playhead: a range the user
        // can see and adjust, rather than an invisible zero-width one.
        let half = min(1.5, max(duration * 0.08, 0.4))
        let start = max(currentTime - half, 0)
        let end = min(currentTime + half, duration)
        pendingRemovalRange = TimeRange(start: start, end: max(end, start + 0.2))
        tool = .cut
    }

    func cancelRangeSelection() {
        pendingRemovalRange = nil
    }

    @discardableResult
    func commitRangeRemoval() -> Bool {
        guard let range = pendingRemovalRange else { return false }
        var succeeded = false
        perform(String(localized: "Remove Range", comment: "Undo action")) { document in
            do {
                _ = try document.removeRange(range)
                succeeded = true
            } catch {
                succeeded = false
            }
        }
        pendingRemovalRange = nil
        if succeeded {
            seek(to: min(range.start, document.duration))
            Haptics.edit()
        } else {
            Haptics.failure()
        }
        return succeeded
    }

    func deleteSelectedClip() {
        guard case .clip(let id) = selection else { return }
        var succeeded = false
        perform(String(localized: "Delete Clip", comment: "Undo action")) { document in
            succeeded = (try? document.deleteClip(id)) != nil
        }
        if succeeded {
            clearSelection()
            Haptics.edit()
        } else {
            Haptics.failure()
        }
    }

    func duplicateSelectedClip() {
        guard case .clip(let id) = selection else { return }
        var newID: UUID?
        perform(String(localized: "Duplicate Clip", comment: "Undo action")) { document in
            newID = try? document.duplicateClip(id)
        }
        if let newID {
            select(.clip(newID))
            Haptics.edit()
        }
    }

    func trimClip(_ clipID: UUID, headDelta: TimeInterval, tailDelta: TimeInterval, isFinal: Bool) {
        perform(
            String(localized: "Trim", comment: "Undo action"),
            coalescing: isFinal ? nil : "trim.\(clipID)"
        ) { document in
            _ = try? document.trimClip(clipID, headDelta: headDelta, tailDelta: tailDelta)
        }
        if isFinal { endInteraction() }
    }

    func setClipSource(_ clipID: UUID, start: TimeInterval, duration: TimeInterval, isFinal: Bool) {
        perform(
            String(localized: "Trim", comment: "Undo action"),
            coalescing: isFinal ? nil : "trim.\(clipID)"
        ) { document in
            _ = try? document.setClipSource(clipID, start: start, duration: duration)
        }
        if isFinal { endInteraction() }
    }

    func moveClip(from source: Int, to destination: Int) {
        perform(String(localized: "Reorder Clips", comment: "Undo action")) { document in
            document.moveClip(from: source, to: destination)
        }
        Haptics.edit()
    }

    // MARK: - Speed, freeze and volume

    func setSpeed(_ speed: Double, forClip clipID: UUID, isFinal: Bool) {
        perform(
            String(localized: "Speed", comment: "Undo action"),
            coalescing: isFinal ? nil : "speed.\(clipID)"
        ) { document in
            _ = try? document.setSpeed(speed, forClip: clipID)
        }
        if isFinal { endInteraction() }
    }

    func insertFreezeFrame(duration: TimeInterval = 1) {
        guard document.kind == .video else { return }
        var newID: UUID?
        perform(String(localized: "Freeze Frame", comment: "Undo action")) { document in
            newID = try? document.insertFreezeFrame(at: self.currentTime, duration: duration)
        }
        if let newID {
            select(.clip(newID))
            Haptics.edit()
        } else {
            Haptics.failure()
        }
    }

    func setClipVolume(_ volume: Double, forClip clipID: UUID, isFinal: Bool) {
        perform(
            String(localized: "Volume", comment: "Undo action"),
            coalescing: isFinal ? nil : "volume.\(clipID)"
        ) { document in
            guard let index = document.videoTrack.firstIndex(where: { $0.id == clipID }) else { return }
            document.videoTrack[index].volume = min(max(volume, 0), 2)
        }
        if isFinal { endInteraction() }
    }

    func toggleClipMute(_ clipID: UUID) {
        perform(String(localized: "Mute", comment: "Undo action")) { document in
            guard let index = document.videoTrack.firstIndex(where: { $0.id == clipID }) else { return }
            document.videoTrack[index].isMuted.toggle()
        }
        Haptics.snap()
    }

    func setTransition(_ transition: Transition, forClip clipID: UUID) {
        perform(String(localized: "Transition", comment: "Undo action")) { document in
            guard let index = document.videoTrack.firstIndex(where: { $0.id == clipID }),
                  index > 0
            else { return }
            document.videoTrack[index].transitionIn = transition
        }
        Haptics.snap()
    }

    // MARK: - Crop and framing

    func updateCrop(_ crop: CropState, isFinal: Bool) {
        perform(
            String(localized: "Crop", comment: "Undo action"),
            coalescing: isFinal ? nil : "crop"
        ) { document in
            document.applyCrop(crop, toClip: self.activeClipID)
        }
        if isFinal { endInteraction() }
    }

    func rotate(byQuarterTurns turns: Int) {
        perform(String(localized: "Rotate", comment: "Undo action")) { document in
            var crop = document.currentCrop(forClip: self.activeClipID)
            crop.quarterTurns += turns
            crop.normalize()
            document.applyCrop(crop, toClip: self.activeClipID)
        }
        Haptics.snap()
    }

    func flip(horizontal: Bool) {
        perform(String(localized: "Flip", comment: "Undo action")) { document in
            var crop = document.currentCrop(forClip: self.activeClipID)
            if horizontal {
                crop.flipHorizontal.toggle()
            } else {
                crop.flipVertical.toggle()
            }
            document.applyCrop(crop, toClip: self.activeClipID)
        }
        Haptics.snap()
    }

    func setOutputAspect(_ aspect: AspectPreset) {
        perform(String(localized: "Aspect Ratio", comment: "Undo action")) { document in
            document.outputAspect = aspect
        }
        Haptics.snap()
    }

    func setBackground(_ background: BackgroundStyle, isFinal: Bool = true) {
        perform(
            String(localized: "Background", comment: "Undo action"),
            coalescing: isFinal ? nil : "background"
        ) { document in
            document.background = background
        }
        if isFinal { endInteraction() }
    }

    func setSafeAreaGuides(enabled: Bool) {
        perform(String(localized: "Guides", comment: "Undo action")) { document in
            document.safeAreaGuides.isEnabled = enabled
        }
    }

    // MARK: - Grade

    func setAdjustment(_ parameter: AdjustmentParameter, to value: Double, isFinal: Bool) {
        perform(
            parameter.displayName,
            coalescing: isFinal ? nil : "adjust.\(parameter.rawValue)"
        ) { document in
            document.grade.adjustments[parameter] = value
        }
        if isFinal { endInteraction() }
    }

    func resetAdjustment(_ parameter: AdjustmentParameter) {
        perform(String(localized: "Reset", comment: "Undo action")) { document in
            document.grade.adjustments.reset(parameter)
        }
        Haptics.snap()
    }

    func resetAllAdjustments() {
        perform(String(localized: "Reset All", comment: "Undo action")) { document in
            document.grade.adjustments.resetAll()
        }
        Haptics.edit()
    }

    func applyAutoEnhance(_ adjustments: AdjustmentSet) {
        perform(String(localized: "Auto Enhance", comment: "Undo action")) { document in
            document.grade.adjustments = adjustments
        }
        Haptics.edit()
    }

    func setFilter(_ presetID: String?) {
        perform(String(localized: "Filter", comment: "Undo action")) { document in
            if let presetID, presetID != FilterCatalog.none.id {
                let intensity = document.grade.filter?.intensity ?? 1
                document.grade.filter = FilterInstance(presetID: presetID, intensity: intensity)
            } else {
                document.grade.filter = nil
            }
        }
        Haptics.snap()
    }

    func setFilterIntensity(_ intensity: Double, isFinal: Bool) {
        perform(
            String(localized: "Filter Intensity", comment: "Undo action"),
            coalescing: isFinal ? nil : "filter.intensity"
        ) { document in
            guard var filter = document.grade.filter else { return }
            filter.intensity = min(max(intensity, 0), 1)
            document.grade.filter = filter
        }
        if isFinal { endInteraction() }
    }

    // MARK: - Blur

    @discardableResult
    func addBlur(scope: BlurScope) -> UUID {
        let region = BlurRegion.make(scope: scope)
        perform(String(localized: "Add Blur", comment: "Undo action")) { document in
            document.blurRegions.append(region)
        }
        select(.blur(region.id))
        Haptics.edit()
        return region.id
    }

    func updateBlur(_ id: UUID, isFinal: Bool = true, _ mutate: (inout BlurRegion) -> Void) {
        perform(
            String(localized: "Blur", comment: "Undo action"),
            coalescing: isFinal ? nil : "blur.\(id)"
        ) { document in
            guard let index = document.blurRegions.firstIndex(where: { $0.id == id }) else { return }
            mutate(&document.blurRegions[index])
        }
        if isFinal { endInteraction() }
    }

    func deleteBlur(_ id: UUID) {
        perform(String(localized: "Delete Blur", comment: "Undo action")) { document in
            document.blurRegions.removeAll { $0.id == id }
        }
        clearSelection()
        Haptics.edit()
    }

    // MARK: - Selective adjustments

    @discardableResult
    func addSelectiveAdjustment() -> UUID {
        let adjustment = SelectiveAdjustment()
        perform(String(localized: "Add Selective Adjustment", comment: "Undo action")) { document in
            document.selectiveAdjustments.append(adjustment)
        }
        select(.selectiveAdjustment(adjustment.id))
        Haptics.edit()
        return adjustment.id
    }

    func updateSelectiveAdjustment(_ id: UUID, isFinal: Bool = true, _ mutate: (inout SelectiveAdjustment) -> Void) {
        perform(
            String(localized: "Selective Adjustment", comment: "Undo action"),
            coalescing: isFinal ? nil : "selective.\(id)"
        ) { document in
            guard let index = document.selectiveAdjustments.firstIndex(where: { $0.id == id }) else { return }
            mutate(&document.selectiveAdjustments[index])
        }
        if isFinal { endInteraction() }
    }

    func deleteSelectiveAdjustment(_ id: UUID) {
        perform(String(localized: "Delete Selective Adjustment", comment: "Undo action")) { document in
            document.selectiveAdjustments.removeAll { $0.id == id }
        }
        clearSelection()
        Haptics.edit()
    }

    // MARK: - Text

    @discardableResult
    func addText() -> UUID {
        var overlay = TextOverlay()
        if document.kind == .video {
            // A new text layer covers a sensible span around the playhead
            // rather than the whole video.
            let duration = min(3.0, max(document.duration - currentTime, 0.5))
            overlay.timeRange = TimeRange(start: currentTime, duration: duration)
        }
        perform(String(localized: "Add Text", comment: "Undo action")) { document in
            document.textOverlays.append(overlay)
        }
        select(.text(overlay.id))
        Haptics.edit()
        return overlay.id
    }

    func updateText(_ id: UUID, isFinal: Bool = true, _ mutate: (inout TextOverlay) -> Void) {
        perform(
            String(localized: "Text", comment: "Undo action"),
            coalescing: isFinal ? nil : "text.\(id)"
        ) { document in
            guard let index = document.textOverlays.firstIndex(where: { $0.id == id }) else { return }
            mutate(&document.textOverlays[index])
        }
        if isFinal { endInteraction() }
    }

    func deleteText(_ id: UUID) {
        perform(String(localized: "Delete Text", comment: "Undo action")) { document in
            document.textOverlays.removeAll { $0.id == id }
        }
        clearSelection()
        Haptics.edit()
    }

    /// Removes a text layer the user created but never typed into, so cancelling
    /// out of the keyboard does not leave an invisible object behind.
    func discardEmptyText(_ id: UUID) {
        guard let overlay = document.textOverlays.first(where: { $0.id == id }), overlay.isEmpty else { return }
        mutateWithoutHistory { document in
            document.textOverlays.removeAll { $0.id == id }
        }
        clearSelection()
    }

    // MARK: - Image overlays

    @discardableResult
    func addImageOverlay(asset: SourceAsset) -> UUID {
        var overlay = ImageOverlay(assetID: asset.id)
        if document.kind == .video {
            let duration = min(4.0, max(document.duration - currentTime, 0.5))
            overlay.timeRange = TimeRange(start: currentTime, duration: duration)
        }
        perform(String(localized: "Add Image", comment: "Undo action")) { document in
            document.addAsset(asset)
            document.imageOverlays.append(overlay)
        }
        select(.imageOverlay(overlay.id))
        Haptics.edit()
        return overlay.id
    }

    func updateImageOverlay(_ id: UUID, isFinal: Bool = true, _ mutate: (inout ImageOverlay) -> Void) {
        perform(
            String(localized: "Image", comment: "Undo action"),
            coalescing: isFinal ? nil : "overlay.\(id)"
        ) { document in
            guard let index = document.imageOverlays.firstIndex(where: { $0.id == id }) else { return }
            mutate(&document.imageOverlays[index])
        }
        if isFinal { endInteraction() }
    }

    func deleteImageOverlay(_ id: UUID) {
        perform(String(localized: "Delete Image", comment: "Undo action")) { document in
            document.imageOverlays.removeAll { $0.id == id }
        }
        clearSelection()
        Haptics.edit()
    }

    // MARK: - Drawing

    @discardableResult
    func addDrawing() -> UUID {
        var drawing = DrawingOverlay()
        if document.kind == .video {
            let duration = min(4.0, max(document.duration - currentTime, 0.5))
            drawing.timeRange = TimeRange(start: currentTime, duration: duration)
        }
        perform(String(localized: "Add Drawing", comment: "Undo action")) { document in
            document.drawings.append(drawing)
        }
        select(.drawing(drawing.id))
        return drawing.id
    }

    func updateDrawing(_ id: UUID, isFinal: Bool = true, _ mutate: (inout DrawingOverlay) -> Void) {
        perform(
            String(localized: "Drawing", comment: "Undo action"),
            coalescing: isFinal ? nil : "drawing.\(id)"
        ) { document in
            guard let index = document.drawings.firstIndex(where: { $0.id == id }) else { return }
            mutate(&document.drawings[index])
        }
        if isFinal { endInteraction() }
    }

    func deleteDrawing(_ id: UUID) {
        perform(String(localized: "Delete Drawing", comment: "Undo action")) { document in
            document.drawings.removeAll { $0.id == id }
        }
        clearSelection()
        Haptics.edit()
    }

    func discardEmptyDrawing(_ id: UUID) {
        guard let drawing = document.drawings.first(where: { $0.id == id }), drawing.isEmpty else { return }
        mutateWithoutHistory { document in
            document.drawings.removeAll { $0.id == id }
        }
        clearSelection()
    }

    // MARK: - Effects

    @discardableResult
    func addEffect(_ kind: EffectKind) -> UUID {
        let effect = EffectInstance(kind: kind)
        perform(String(localized: "Add Effect", comment: "Undo action")) { document in
            // One instance per kind: stacking two identical effects is never
            // what someone means by tapping it twice.
            document.effects.removeAll { $0.kind == kind }
            document.effects.append(effect)
        }
        Haptics.snap()
        return effect.id
    }

    func setEffectIntensity(_ id: UUID, to intensity: Double, isFinal: Bool) {
        perform(
            String(localized: "Effect Intensity", comment: "Undo action"),
            coalescing: isFinal ? nil : "effect.\(id)"
        ) { document in
            guard let index = document.effects.firstIndex(where: { $0.id == id }) else { return }
            document.effects[index].intensity = min(max(intensity, 0), 1)
        }
        if isFinal { endInteraction() }
    }

    func removeEffect(kind: EffectKind) {
        perform(String(localized: "Remove Effect", comment: "Undo action")) { document in
            document.effects.removeAll { $0.kind == kind }
        }
        Haptics.snap()
    }

    // MARK: - Audio

    @discardableResult
    func addAudioClip(asset: SourceAsset, role: AudioRole, at start: TimeInterval, label: String = "") -> UUID {
        let clip = AudioClip(
            assetID: asset.id,
            role: role,
            source: TimeRange(start: 0, duration: asset.duration),
            timelineStart: start,
            label: label
        )
        perform(String(localized: "Add Audio", comment: "Undo action")) { document in
            document.addAsset(asset)
            document.audioClips.append(clip)
        }
        select(.audio(clip.id))
        Haptics.edit()
        return clip.id
    }

    func updateAudioClip(_ id: UUID, isFinal: Bool = true, _ mutate: (inout AudioClip) -> Void) {
        perform(
            String(localized: "Audio", comment: "Undo action"),
            coalescing: isFinal ? nil : "audio.\(id)"
        ) { document in
            guard let index = document.audioClips.firstIndex(where: { $0.id == id }) else { return }
            mutate(&document.audioClips[index])
        }
        if isFinal { endInteraction() }
    }

    func deleteAudioClip(_ id: UUID) {
        perform(String(localized: "Delete Audio", comment: "Undo action")) { document in
            document.audioClips.removeAll { $0.id == id }
        }
        clearSelection()
        Haptics.edit()
    }

    func splitAudioClipAtPlayhead(_ id: UUID) {
        var didSplit = false
        perform(String(localized: "Split Audio", comment: "Undo action")) { document in
            guard let index = document.audioClips.firstIndex(where: { $0.id == id }) else { return }
            let clip = document.audioClips[index]
            let offset = self.currentTime - clip.timelineStart
            guard offset > 0.1, clip.timelineDuration - offset > 0.1 else { return }

            let sourceOffset = offset * clip.speed
            var head = clip
            head.source = TimeRange(start: clip.source.start, duration: sourceOffset)
            head.fadeOut = 0

            var tail = clip
            tail.id = UUID()
            tail.source = TimeRange(
                start: clip.source.start + sourceOffset,
                duration: clip.source.duration - sourceOffset
            )
            tail.timelineStart = self.currentTime
            tail.fadeIn = 0

            document.audioClips[index] = head
            document.audioClips.insert(tail, at: index + 1)
            didSplit = true
        }
        Haptics.edit()
        if !didSplit { Haptics.failure() }
    }

    func setAutoDuck(_ enabled: Bool) {
        perform(String(localized: "Auto Duck", comment: "Undo action")) { document in
            document.audioMix.autoDuck = enabled
        }
        Haptics.snap()
    }

    // MARK: - Keyframes

    /// Toggles a keyframe for the selected layer's property at the playhead.
    func toggleKeyframe(_ property: KeyframeProperty) {
        perform(String(localized: "Keyframe", comment: "Undo action")) { document in
            let time = self.currentTime
            switch self.selection {
            case .text(let id):
                guard let index = document.textOverlays.firstIndex(where: { $0.id == id }) else { return }
                Self.toggle(property, in: &document.textOverlays[index].keyframes,
                            at: time, current: document.textOverlays[index].transform)
            case .imageOverlay(let id):
                guard let index = document.imageOverlays.firstIndex(where: { $0.id == id }) else { return }
                Self.toggle(property, in: &document.imageOverlays[index].keyframes,
                            at: time, current: document.imageOverlays[index].transform)
            case .blur(let id):
                guard let index = document.blurRegions.firstIndex(where: { $0.id == id }) else { return }
                var keyframes = document.blurRegions[index].keyframes
                if keyframes.hasKeyframe(property, at: time) {
                    keyframes.removeKeyframe(property, at: time)
                } else {
                    keyframes.setKeyframe(property, value: document.blurRegions[index].strength, at: time)
                }
                document.blurRegions[index].keyframes = keyframes
            case .audio(let id):
                guard let index = document.audioClips.firstIndex(where: { $0.id == id }) else { return }
                var keyframes = document.audioClips[index].keyframes
                if keyframes.hasKeyframe(property, at: time) {
                    keyframes.removeKeyframe(property, at: time)
                } else {
                    keyframes.setKeyframe(property, value: document.audioClips[index].volume, at: time)
                }
                document.audioClips[index].keyframes = keyframes
            case .clip(let id):
                guard let index = document.videoTrack.firstIndex(where: { $0.id == id }),
                      let clipStart = document.startTime(ofClip: id)
                else { return }
                var keyframes = document.videoTrack[index].keyframes
                let offset = time - clipStart
                if keyframes.hasKeyframe(property, at: offset) {
                    keyframes.removeKeyframe(property, at: offset)
                } else {
                    keyframes.setKeyframe(property, value: document.videoTrack[index].volume, at: offset)
                }
                document.videoTrack[index].keyframes = keyframes
            default:
                break
            }
        }
        Haptics.snap()
    }

    private static func toggle(
        _ property: KeyframeProperty,
        in keyframes: inout KeyframeSet,
        at time: TimeInterval,
        current transform: LayerTransform
    ) {
        if keyframes.hasKeyframe(property, at: time) {
            keyframes.removeKeyframe(property, at: time)
            return
        }
        let value: Double = switch property {
        case .positionX: transform.position.x
        case .positionY: transform.position.y
        case .scale: transform.scale
        case .rotation: transform.rotation
        case .opacity: transform.opacity
        default: 0
        }
        keyframes.setKeyframe(property, value: value, at: time)
    }
}

// MARK: - Document helpers used by the actions

extension EditDocument {
    /// The crop the crop tool should edit: the selected clip's, or the photo's.
    func currentCrop(forClip clipID: UUID?) -> CropState {
        if let clipID, let clip = videoTrack.first(where: { $0.id == clipID }) {
            return clip.crop
        }
        return photo?.crop ?? .identity
    }

    mutating func applyCrop(_ crop: CropState, toClip clipID: UUID?) {
        var normalized = crop
        normalized.normalize()
        if let clipID, let index = videoTrack.firstIndex(where: { $0.id == clipID }) {
            videoTrack[index].crop = normalized
        } else if photo != nil {
            photo?.crop = normalized
        } else if !videoTrack.isEmpty {
            videoTrack[0].crop = normalized
        }
    }
}
