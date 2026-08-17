import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import OSLog

/// The result of turning a document into something AVFoundation can play.
struct BuiltComposition: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let outputSize: CGSize
    let frameRate: Double
    /// Changes whenever anything structural changes, so the player can decide
    /// whether it needs a new item at all.
    let structureSignature: Int
}

/// Builds the AVFoundation object graph for a video document.
///
/// The composition carries *structure* — which piece of which file plays when.
/// Everything visual is left to `FramesVideoCompositor`, which is why changing a
/// filter does not require rebuilding the composition, and why changing the
/// timeline does.
actor CompositionEngine {
    private let logger = FramesLog.render

    /// Tracks alternate so a transition can overlap two clips.
    private static let videoTrackCount = 2

    func build(
        document: EditDocument,
        quality: RenderQuality,
        overrideOutputSize: CGSize? = nil
    ) async throws -> BuiltComposition {
        guard document.kind == .video, !document.videoTrack.isEmpty else {
            throw FramesError.renderFailed("not a video document")
        }

        let signpost = FramesLog.signposter.beginInterval("buildComposition")
        defer { FramesLog.signposter.endInterval("buildComposition", signpost) }

        let composition = AVMutableComposition()
        var videoTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<Self.videoTrackCount {
            guard let track = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw FramesError.renderFailed("could not create a video track")
            }
            videoTracks.append(track)
        }
        let sourceAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var placements: [ClipPlacement] = []
        var cursor = CMTime.zero
        var sourceFrameRate: Double = 30
        var maximumDisplaySize = CGSize.zero
        var audioParameters: [AVMutableAudioMixInputParameters] = []

        if let sourceAudioTrack {
            audioParameters.append(AVMutableAudioMixInputParameters(track: sourceAudioTrack))
        }

        for (index, clip) in document.videoTrack.enumerated() {
            guard let assetDescription = document.asset(id: clip.assetID) else { continue }
            let url = SessionPaths.mediaURL(for: assetDescription.fileName)
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

            guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                logger.error("Clip \(index) has no video track; skipping")
                continue
            }
            let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
            let naturalSize = try await sourceVideoTrack.load(.naturalSize)
            let nominalRate = Double(try await sourceVideoTrack.load(.nominalFrameRate))
            if nominalRate > 0 { sourceFrameRate = max(sourceFrameRate, nominalRate) }

            let transformed = naturalSize.applying(preferredTransform)
            maximumDisplaySize.width = max(maximumDisplaySize.width, abs(transformed.width))
            maximumDisplaySize.height = max(maximumDisplaySize.height, abs(transformed.height))

            let destination = videoTracks[index % Self.videoTrackCount]
            let timelineDuration = CMTime(seconds: clip.timelineDuration, preferredTimescale: 600)

            let sourceRange: CMTimeRange
            if clip.isFrozen {
                // A freeze is one frame stretched: insert a single frame and
                // scale it to the held duration.
                let frameDuration = CMTime(
                    value: 1,
                    timescale: CMTimeScale(max(nominalRate.rounded(), 1))
                )
                sourceRange = CMTimeRange(
                    start: CMTime(seconds: clip.source.start, preferredTimescale: 600),
                    duration: frameDuration
                )
            } else {
                sourceRange = CMTimeRange(
                    start: CMTime(seconds: clip.source.start, preferredTimescale: 600),
                    duration: CMTime(seconds: clip.source.duration, preferredTimescale: 600)
                )
            }

            do {
                try destination.insertTimeRange(sourceRange, of: sourceVideoTrack, at: cursor)
            } catch {
                logger.error("Could not insert clip \(index): \(error.localizedDescription, privacy: .public)")
                continue
            }

            let insertedRange = CMTimeRange(start: cursor, duration: sourceRange.duration)
            if clip.isFrozen || abs(clip.speed - 1) > 0.001 {
                destination.scaleTimeRange(insertedRange, toDuration: timelineDuration)
            }

            // Source audio follows the picture, unless the clip is silent —
            // a frozen frame has no meaningful audio to carry.
            if let sourceAudioTrack,
               !clip.isFrozen,
               let audioSource = try? await asset.loadTracks(withMediaType: .audio).first {
                do {
                    try sourceAudioTrack.insertTimeRange(sourceRange, of: audioSource, at: cursor)
                    if abs(clip.speed - 1) > 0.001 {
                        sourceAudioTrack.scaleTimeRange(
                            CMTimeRange(start: cursor, duration: sourceRange.duration),
                            toDuration: timelineDuration
                        )
                    }
                } catch {
                    logger.notice("Clip \(index) audio could not be inserted: \(error.localizedDescription, privacy: .public)")
                }
            } else if let sourceAudioTrack {
                try? sourceAudioTrack.insertEmptyTimeRange(
                    CMTimeRange(start: cursor, duration: timelineDuration)
                )
            }

            if let parameters = audioParameters.first {
                applyClipVolume(clip, from: cursor, duration: timelineDuration, to: parameters)
            }

            placements.append(
                ClipPlacement(
                    clip: clip,
                    timelineRange: TimeRange(
                        start: CMTimeGetSeconds(cursor),
                        duration: clip.timelineDuration
                    ),
                    preferredTransform: preferredTransform,
                    naturalSize: naturalSize,
                    trackID: destination.trackID
                )
            )

            cursor = CMTimeAdd(cursor, timelineDuration)
        }

        guard !placements.isEmpty else {
            throw FramesError.renderFailed("no clips could be composed")
        }

        try await insertAudioClips(document: document, into: composition, parameters: &audioParameters)
        applyDucking(document: document, parameters: audioParameters)

        let outputSize = overrideOutputSize
            ?? resolveOutputSize(document: document, sourceSize: maximumDisplaySize, placements: placements)
        let frameRate = sourceFrameRate

        let videoComposition = try await makeVideoComposition(
            document: document,
            placements: placements,
            outputSize: outputSize,
            frameRate: frameRate,
            quality: quality
        )

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioParameters.isEmpty ? nil : audioMix,
            outputSize: outputSize,
            frameRate: frameRate,
            structureSignature: Self.structureSignature(of: document)
        )
    }

    // MARK: - Video composition

    private func makeVideoComposition(
        document: EditDocument,
        placements: [ClipPlacement],
        outputSize: CGSize,
        frameRate: Double,
        quality: RenderQuality
    ) async throws -> AVVideoComposition {
        let resolver = FrameResourceResolver()
        // The compositor cannot await, so overlay images and drawings are
        // resolved here, once, and travel with the plan.
        let resources = await resolver.resources(
            for: document,
            sourceImage: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize)),
            time: 0,
            outputSize: outputSize,
            quality: quality
        )

        let requirements = FrameComposer.detectionRequirements(for: document)
        let needsPerFrameVision = requirements.needsFaces
            || requirements.needsPersonInstances
            || requirements.needsSubject
            || !requirements.trackedObjectIDs.isEmpty

        let plan = VideoRenderPlan(
            document: document,
            outputSize: outputSize,
            overlays: resources.overlays,
            backgroundImage: resources.backgroundImage,
            quality: quality,
            analyzer: needsPerFrameVision ? FrameAnalyzer(requirements: requirements) : nil
        )

        var instructions: [FramesCompositionInstruction] = []

        for (index, placement) in placements.enumerated() {
            let start = CMTime(seconds: placement.timelineRange.start, preferredTimescale: 600)
            let duration = CMTime(seconds: placement.timelineRange.duration, preferredTimescale: 600)
            let transition = placement.clip.transitionIn
            let previous = index > 0 ? placements[index - 1] : nil

            if index > 0, transition.isActive, let previous {
                // The transition overlaps the end of the previous clip, so this
                // clip's own range starts after it.
                let overlap = min(
                    transition.duration,
                    min(previous.timelineRange.duration, placement.timelineRange.duration) * 0.5
                )
                let overlapDuration = CMTime(seconds: overlap, preferredTimescale: 600)
                if overlap > 0.01 {
                    instructions.append(
                        FramesCompositionInstruction(
                            timeRange: CMTimeRange(start: start, duration: overlapDuration),
                            plan: plan,
                            placement: placement,
                            outgoing: previous,
                            transition: transition
                        )
                    )
                    instructions.append(
                        FramesCompositionInstruction(
                            timeRange: CMTimeRange(
                                start: CMTimeAdd(start, overlapDuration),
                                duration: CMTimeSubtract(duration, overlapDuration)
                            ),
                            plan: plan,
                            placement: placement
                        )
                    )
                    continue
                }
            }

            instructions.append(
                FramesCompositionInstruction(
                    timeRange: CMTimeRange(start: start, duration: duration),
                    plan: plan,
                    placement: placement
                )
            )
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = FramesVideoCompositor.self
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(frameRate.rounded(), 1))
        )
        videoComposition.instructions = instructions
        return videoComposition
    }

    // MARK: - Audio

    private func insertAudioClips(
        document: EditDocument,
        into composition: AVMutableComposition,
        parameters: inout [AVMutableAudioMixInputParameters]
    ) async throws {
        for clip in document.audioClips {
            guard let assetDescription = document.asset(id: clip.assetID) else { continue }
            let url = SessionPaths.mediaURL(for: assetDescription.fileName)
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first else { continue }
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: clip.source.start, preferredTimescale: 600),
                duration: CMTime(seconds: clip.source.duration, preferredTimescale: 600)
            )
            let at = CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
            do {
                try track.insertTimeRange(sourceRange, of: sourceTrack, at: at)
            } catch {
                logger.notice("Audio clip could not be inserted: \(error.localizedDescription, privacy: .public)")
                continue
            }

            if abs(clip.speed - 1) > 0.001 {
                track.scaleTimeRange(
                    CMTimeRange(start: at, duration: sourceRange.duration),
                    toDuration: CMTime(seconds: clip.timelineDuration, preferredTimescale: 600)
                )
            }

            let inputParameters = AVMutableAudioMixInputParameters(track: track)
            applyAudioClipVolume(clip, to: inputParameters)
            parameters.append(inputParameters)
        }
    }

    private func applyClipVolume(
        _ clip: VideoClip,
        from start: CMTime,
        duration: CMTime,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        let range = CMTimeRange(start: start, duration: duration)
        let gain = Float(clip.isMuted ? 0 : clip.volume)

        if clip.keyframes.isAnimated(.volume) {
            // Volume keyframes become a chain of ramps, which is exactly what an
            // audio mix understands.
            let times = clip.keyframes.allTimes
            var previousTime: TimeInterval = 0
            var previousValue = clip.gain(at: 0)
            for time in times where time > 0 {
                let value = clip.gain(at: time)
                parameters.setVolumeRamp(
                    fromStartVolume: Float(previousValue),
                    toEndVolume: Float(value),
                    timeRange: CMTimeRange(
                        start: CMTimeAdd(start, CMTime(seconds: previousTime, preferredTimescale: 600)),
                        duration: CMTime(seconds: time - previousTime, preferredTimescale: 600)
                    )
                )
                previousTime = time
                previousValue = value
            }
            if previousTime < clip.timelineDuration {
                parameters.setVolume(Float(previousValue), at: CMTimeAdd(
                    start,
                    CMTime(seconds: previousTime, preferredTimescale: 600)
                ))
            }
        } else {
            parameters.setVolume(gain, at: start)
            parameters.setVolume(gain, at: CMTimeAdd(start, duration))
        }
        _ = range
    }

    private func applyAudioClipVolume(
        _ clip: AudioClip,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        let start = CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
        let duration = CMTime(seconds: clip.timelineDuration, preferredTimescale: 600)
        let base = Float(clip.isMuted ? 0 : clip.volume)

        parameters.setVolume(base, at: start)

        if clip.fadeIn > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: base,
                timeRange: CMTimeRange(
                    start: start,
                    duration: CMTime(seconds: clip.fadeIn, preferredTimescale: 600)
                )
            )
        }
        if clip.fadeOut > 0 {
            let fadeStart = CMTimeSubtract(
                CMTimeAdd(start, duration),
                CMTime(seconds: clip.fadeOut, preferredTimescale: 600)
            )
            parameters.setVolumeRamp(
                fromStartVolume: base,
                toEndVolume: 0,
                timeRange: CMTimeRange(
                    start: fadeStart,
                    duration: CMTime(seconds: clip.fadeOut, preferredTimescale: 600)
                )
            )
        }
    }

    /// Lowers music while a voiceover is playing.
    ///
    /// Implemented as ramps on the mix rather than by rewriting the audio, so
    /// the user can turn it off and get their original levels back.
    private func applyDucking(document: EditDocument, parameters: [AVMutableAudioMixInputParameters]) {
        guard document.audioMix.autoDuck else { return }
        let spoken = document.audioClips.filter { $0.role.isSpokenContent && !$0.isMuted }
        guard !spoken.isEmpty else { return }

        let duckable = document.audioClips.enumerated().filter { $0.element.role.isDuckable }
        guard !duckable.isEmpty else { return }

        let ramp = max(document.audioMix.duckRamp, 0.05)
        let amount = Float(1 - document.audioMix.duckAmount)

        for (index, clip) in duckable {
            // Audio clip parameters were appended in document order after the
            // source-audio parameters, which is the one at index 0.
            let parameterIndex = index + 1
            guard parameters.indices.contains(parameterIndex) else { continue }
            let parameter = parameters[parameterIndex]
            let base = Float(clip.isMuted ? 0 : clip.volume)

            for voice in spoken {
                let voiceRange = voice.timelineRange
                guard voiceRange.intersects(clip.timelineRange) else { continue }

                let duckStart = CMTime(seconds: max(voiceRange.start - ramp, 0), preferredTimescale: 600)
                parameter.setVolumeRamp(
                    fromStartVolume: base,
                    toEndVolume: base * amount,
                    timeRange: CMTimeRange(
                        start: duckStart,
                        duration: CMTime(seconds: ramp, preferredTimescale: 600)
                    )
                )
                parameter.setVolumeRamp(
                    fromStartVolume: base * amount,
                    toEndVolume: base,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: voiceRange.end, preferredTimescale: 600),
                        duration: CMTime(seconds: ramp, preferredTimescale: 600)
                    )
                )
            }
        }
    }

    // MARK: - Geometry

    private func resolveOutputSize(
        document: EditDocument,
        sourceSize: CGSize,
        placements: [ClipPlacement]
    ) -> CGSize {
        let base = sourceSize.width > 0 && sourceSize.height > 0
            ? sourceSize
            : CGSize(width: 1920, height: 1080)

        let croppedAspect: CGFloat
        if let first = placements.first {
            let sourceAspect = base.height > 0 ? base.width / base.height : 1
            croppedAspect = first.clip.outputAspectRatio(sourceAspectRatio: sourceAspect)
        } else {
            croppedAspect = base.height > 0 ? base.width / base.height : 1
        }

        let aspect = document.outputAspect.ratio ?? croppedAspect
        let longEdge = max(base.width, base.height)

        let size: CGSize = aspect >= 1
            ? CGSize(width: longEdge, height: longEdge / aspect)
            : CGSize(width: longEdge * aspect, height: longEdge)

        // Encoders want even dimensions.
        return CGSize(
            width: max((size.width / 2).rounded() * 2, 16),
            height: max((size.height / 2).rounded() * 2, 16)
        )
    }

    /// Only the parts of the document that change the AVFoundation structure.
    /// Colour, overlays and blur are deliberately excluded: they change what
    /// the compositor draws, not what the composition contains.
    static func structureSignature(of document: EditDocument) -> Int {
        var hasher = Hasher()
        hasher.combine(document.videoTrack)
        hasher.combine(document.audioClips)
        hasher.combine(document.audioMix)
        hasher.combine(document.outputAspect)
        hasher.combine(document.assets)
        return hasher.finalize()
    }
}
