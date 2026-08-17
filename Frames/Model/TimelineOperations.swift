import Foundation

/// Why a timeline edit was refused.
///
/// Operations return a result rather than silently doing nothing, so the UI can
/// explain the refusal (and so the tests can assert on it).
enum TimelineEditError: Error, Equatable {
    case noSuchClip
    case notAVideoEdit
    case rangeOutOfBounds
    case rangeTooShort
    case wouldEmptyTimeline
    case resultingClipTooShort
    case splitTooCloseToEdge
}

extension EditDocument {

    // MARK: - Trim

    /// Moves a clip's in- and out-points by the given timeline deltas.
    ///
    /// Positive `headDelta` shortens from the left, positive `tailDelta`
    /// shortens from the right. Negative values extend the clip back towards
    /// the source's own limits, which is what makes trimming reversible without
    /// re-importing.
    @discardableResult
    mutating func trimClip(
        _ clipID: UUID,
        headDelta: TimeInterval = 0,
        tailDelta: TimeInterval = 0
    ) throws -> TimeRange {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        guard let index = videoTrack.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.noSuchClip
        }

        var clip = videoTrack[index]
        let assetDuration = asset(id: clip.assetID)?.duration ?? clip.source.end
        let speed = max(clip.speed, VideoClip.minimumSpeed)

        if clip.isFrozen {
            let newDuration = clip.timelineDuration - headDelta - tailDelta
            guard newDuration >= VideoClip.minimumDuration else {
                throw TimelineEditError.resultingClipTooShort
            }
            clip.freezeDuration = newDuration
        } else {
            // Work in source seconds, then validate once against both the
            // source bounds and the minimum clip length.
            let headSource = headDelta * speed
            let tailSource = tailDelta * speed
            var newStart = clip.source.start
            var newDuration = clip.source.duration

            if clip.isReversed {
                newStart += tailSource
                newDuration -= headSource + tailSource
            } else {
                newStart += headSource
                newDuration -= headSource + tailSource
            }

            guard newStart >= -0.0001 else { throw TimelineEditError.rangeOutOfBounds }
            newStart = max(0, newStart)
            guard newStart + newDuration <= assetDuration + 0.0001 else {
                throw TimelineEditError.rangeOutOfBounds
            }
            guard newDuration / speed >= VideoClip.minimumDuration else {
                throw TimelineEditError.resultingClipTooShort
            }
            clip.source = TimeRange(start: newStart, duration: newDuration)
        }

        if headDelta != 0 {
            clip.keyframes.shift(by: -headDelta)
        }
        videoTrack[index] = clip
        touch()
        return TimeRange(start: clip.source.start, duration: clip.source.duration)
    }

    /// Sets a clip's source range outright. Used by the trim handles, which
    /// already know the absolute in- and out-points they want.
    @discardableResult
    mutating func setClipSource(
        _ clipID: UUID,
        start: TimeInterval,
        duration: TimeInterval
    ) throws -> TimeRange {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        guard let index = videoTrack.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.noSuchClip
        }
        var clip = videoTrack[index]
        let assetDuration = asset(id: clip.assetID)?.duration ?? (start + duration)
        let speed = max(clip.speed, VideoClip.minimumSpeed)

        guard start >= -0.0001, start + duration <= assetDuration + 0.0001 else {
            throw TimelineEditError.rangeOutOfBounds
        }
        guard duration / speed >= VideoClip.minimumDuration else {
            throw TimelineEditError.resultingClipTooShort
        }
        clip.source = TimeRange(start: max(0, start), duration: duration)
        videoTrack[index] = clip
        touch()
        return clip.source
    }

    // MARK: - Split

    /// Splits the video track at a timeline position. Returns the id of the new
    /// trailing clip.
    @discardableResult
    mutating func split(at time: TimeInterval) throws -> UUID {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        guard let located = clip(at: time) else { throw TimelineEditError.noSuchClip }
        guard let start = startTime(ofClip: located.clip.id) else { throw TimelineEditError.noSuchClip }

        let offset = time - start
        guard let halves = located.clip.splitting(atOffset: offset) else {
            throw TimelineEditError.splitTooCloseToEdge
        }

        videoTrack.replaceSubrange(located.index...located.index, with: [halves.head, halves.tail])
        touch()
        return halves.tail.id
    }

    // MARK: - Remove range
    //
    // The headline operation. Deleting an arbitrary span is what people
    // actually want, and making them split twice and delete the middle is the
    // single most common piece of busywork in mobile video editors.

    /// Removes an arbitrary span from the timeline and closes the gap.
    ///
    /// Clips that fall entirely inside the span are deleted; clips that
    /// straddle either edge are trimmed; a clip containing the whole span is
    /// split around it. Overlays and audio that sit after the span shift back
    /// by its duration, so the edit stays in sync.
    @discardableResult
    mutating func removeRange(_ range: TimeRange) throws -> Int {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        let total = videoDuration
        guard range.duration > 0 else { throw TimelineEditError.rangeTooShort }
        guard range.start >= -0.0001, range.end <= total + 0.0001 else {
            throw TimelineEditError.rangeOutOfBounds
        }
        guard total - range.duration >= VideoClip.minimumDuration else {
            throw TimelineEditError.wouldEmptyTimeline
        }

        let removal = TimeRange(start: max(0, range.start), end: min(range.end, total))
        var rebuilt: [VideoClip] = []
        var removedClipCount = 0
        var cursor: TimeInterval = 0

        for clip in videoTrack {
            let clipRange = TimeRange(start: cursor, duration: clip.timelineDuration)
            cursor = clipRange.end

            guard let overlap = clipRange.intersection(removal) else {
                rebuilt.append(clip)
                continue
            }

            let leadingKept = overlap.start - clipRange.start
            let trailingKept = clipRange.end - overlap.end

            if leadingKept <= 0.0001 && trailingKept <= 0.0001 {
                // Entirely inside the removed span.
                removedClipCount += 1
                continue
            }

            if leadingKept > 0.0001 && trailingKept > 0.0001 {
                // The span is strictly inside this clip: split around it.
                guard let halves = clip.splitting(atOffset: leadingKept) else {
                    // Too close to an edge to split cleanly — trim the side that
                    // survives the check instead of refusing the whole edit.
                    var trimmed = clip
                    if leadingKept >= trailingKept {
                        if trimmed.trimTail(by: clip.timelineDuration - leadingKept) {
                            rebuilt.append(trimmed)
                        } else {
                            removedClipCount += 1
                        }
                    } else {
                        if trimmed.trimHead(by: clip.timelineDuration - trailingKept) {
                            rebuilt.append(trimmed)
                        } else {
                            removedClipCount += 1
                        }
                    }
                    continue
                }
                var tail = halves.tail
                if tail.trimHead(by: overlap.duration) {
                    rebuilt.append(halves.head)
                    rebuilt.append(tail)
                } else {
                    rebuilt.append(halves.head)
                    removedClipCount += 1
                }
                continue
            }

            var trimmed = clip
            if leadingKept > 0.0001 {
                // Overlap runs to the clip's end: keep the head.
                if trimmed.trimTail(by: overlap.duration) {
                    rebuilt.append(trimmed)
                } else {
                    removedClipCount += 1
                }
            } else {
                // Overlap starts at the clip's start: keep the tail.
                if trimmed.trimHead(by: overlap.duration) {
                    rebuilt.append(trimmed)
                } else {
                    removedClipCount += 1
                }
            }
        }

        guard !rebuilt.isEmpty else { throw TimelineEditError.wouldEmptyTimeline }

        videoTrack = rebuilt
        // The first clip can never carry a transition in — there is nothing to
        // transition from.
        videoTrack[0].transitionIn = .none

        closeGapForTimeBasedLayers(removing: removal)
        touch()
        return removedClipCount
    }

    /// Shifts everything that is positioned in timeline time so it stays where
    /// the user put it relative to the picture.
    ///
    /// Audio that straddles the removed span is shortened by the overlap rather
    /// than split: the clip keeps its start and its source in-point, so a music
    /// bed stays anchored where it was placed. A layer whose whole life was
    /// inside the removed span is deleted, because there is no longer any
    /// moment at which it could be seen.
    private mutating func closeGapForTimeBasedLayers(removing removal: TimeRange) {
        audioClips = audioClips.compactMap { clip in
            guard case .some(let adjusted) = adjustedRange(clip.timelineRange, removing: removal) else {
                return nil
            }
            guard let adjusted else { return clip }
            var copy = clip
            copy.timelineStart = adjusted.start
            copy.source.duration = adjusted.duration * max(copy.speed, 0.01)
            return copy.timelineDuration >= 0.05 ? copy : nil
        }

        textOverlays = textOverlays.compactMap { overlay in
            guard case .some(let adjusted) = adjustedRange(overlay.timeRange, removing: removal) else {
                return nil
            }
            var copy = overlay
            copy.timeRange = adjusted
            return copy
        }

        imageOverlays = imageOverlays.compactMap { overlay in
            guard case .some(let adjusted) = adjustedRange(overlay.timeRange, removing: removal) else {
                return nil
            }
            var copy = overlay
            copy.timeRange = adjusted
            return copy
        }

        drawings = drawings.compactMap { drawing in
            guard case .some(let adjusted) = adjustedRange(drawing.timeRange, removing: removal) else {
                return nil
            }
            var copy = drawing
            copy.timeRange = adjusted
            return copy
        }

        blurRegions = blurRegions.compactMap { region in
            guard case .some(let adjusted) = adjustedRange(region.timeRange, removing: removal) else {
                return nil
            }
            var copy = region
            copy.timeRange = adjusted
            return copy
        }

        effects = effects.compactMap { effect in
            guard case .some(let adjusted) = adjustedRange(effect.timeRange, removing: removal) else {
                return nil
            }
            var copy = effect
            copy.timeRange = adjusted
            return copy
        }

        selectiveAdjustments = selectiveAdjustments.compactMap { adjustment in
            guard case .some(let adjusted) = adjustedRange(adjustment.timeRange, removing: removal) else {
                return nil
            }
            var copy = adjustment
            copy.timeRange = adjusted
            return copy
        }

        for index in trackedObjects.indices {
            let shifted = trackedObjects[index].samples
                .filter { !removal.contains($0.time) }
                .map {
                    TrackingSample(
                        time: shiftTime($0.time, removing: removal),
                        rect: $0.rect,
                        confidence: $0.confidence
                    )
                }
            trackedObjects[index].replaceSamples(shifted)
        }
        trackedObjects.removeAll(where: \.isEmpty)
    }

    /// `.some(range)` when the layer survives, `.some(nil)` when it was always
    /// visible and stays that way, and `nil` when it should be deleted.
    private func adjustedRange(_ range: TimeRange?, removing removal: TimeRange) -> TimeRange?? {
        guard let range else { return .some(nil) }
        let newStart = shiftTime(range.start, removing: removal)
        let newEnd = shiftTime(range.end, removing: removal)
        guard newEnd - newStart > 0.05 else { return nil }
        return .some(TimeRange(start: newStart, end: newEnd))
    }

    private func shiftTime(_ time: TimeInterval, removing removal: TimeRange) -> TimeInterval {
        if time <= removal.start { return time }
        if time >= removal.end { return time - removal.duration }
        return removal.start
    }

    // MARK: - Clip management

    @discardableResult
    mutating func deleteClip(_ clipID: UUID) throws -> Int {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        guard let index = videoTrack.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.noSuchClip
        }
        guard videoTrack.count > 1 else { throw TimelineEditError.wouldEmptyTimeline }
        guard let range = timelineRange(ofClip: clipID) else { throw TimelineEditError.noSuchClip }

        videoTrack.remove(at: index)
        videoTrack[0].transitionIn = .none
        closeGapForTimeBasedLayers(removing: range)
        touch()
        return index
    }

    @discardableResult
    mutating func duplicateClip(_ clipID: UUID) throws -> UUID {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        guard let index = videoTrack.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.noSuchClip
        }
        var copy = videoTrack[index]
        copy.id = UUID()
        copy.transitionIn = .none
        videoTrack.insert(copy, at: index + 1)
        touch()
        return copy.id
    }

    mutating func moveClip(from source: Int, to destination: Int) {
        guard kind == .video,
              videoTrack.indices.contains(source),
              destination >= 0, destination <= videoTrack.count
        else { return }
        let clip = videoTrack.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        videoTrack.insert(clip, at: min(max(target, 0), videoTrack.count))
        videoTrack[0].transitionIn = .none
        touch()
    }

    /// Inserts a freeze frame at the playhead, splitting the clip under it.
    @discardableResult
    mutating func insertFreezeFrame(at time: TimeInterval, duration: TimeInterval = 1.0) throws -> UUID {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        guard let located = clip(at: time) else { throw TimelineEditError.noSuchClip }

        let sourceTime = located.clip.sourceTime(forOffset: located.offset)
        let freeze = VideoClip.freeze(
            assetID: located.clip.assetID,
            sourceTime: sourceTime,
            duration: duration,
            inheriting: located.clip
        )

        if let halves = located.clip.splitting(atOffset: located.offset) {
            videoTrack.replaceSubrange(
                located.index...located.index,
                with: [halves.head, freeze, halves.tail]
            )
        } else if located.offset < located.clip.timelineDuration / 2 {
            videoTrack.insert(freeze, at: located.index)
        } else {
            videoTrack.insert(freeze, at: located.index + 1)
        }
        videoTrack[0].transitionIn = .none
        touch()
        return freeze.id
    }

    @discardableResult
    mutating func setSpeed(_ speed: Double, forClip clipID: UUID) throws -> TimeInterval {
        guard kind == .video else { throw TimelineEditError.notAVideoEdit }
        guard let index = videoTrack.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.noSuchClip
        }
        let clamped = min(max(speed, VideoClip.minimumSpeed), VideoClip.maximumSpeed)
        guard videoTrack[index].source.duration / clamped >= VideoClip.minimumDuration else {
            throw TimelineEditError.resultingClipTooShort
        }
        videoTrack[index].speed = clamped
        touch()
        return videoTrack[index].timelineDuration
    }

    // MARK: - Validation

    /// Invariants the timeline must always satisfy. Called by the tests, and by
    /// the session after every mutation in debug builds.
    var timelineIsValid: Bool {
        guard kind == .video else { return videoTrack.isEmpty }
        guard !videoTrack.isEmpty else { return false }
        guard videoTrack.first?.transitionIn.isActive != true else { return false }
        for clip in videoTrack {
            guard clip.timelineDuration >= VideoClip.minimumDuration - 0.0001 else { return false }
            guard asset(id: clip.assetID) != nil else { return false }
            if !clip.isFrozen {
                guard clip.source.start >= -0.0001 else { return false }
                if let asset = asset(id: clip.assetID) {
                    guard clip.source.end <= asset.duration + 0.05 else { return false }
                }
            }
        }
        return true
    }
}
