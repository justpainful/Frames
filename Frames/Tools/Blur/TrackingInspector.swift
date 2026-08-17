import CoreImage
import SwiftUI

/// Object tracking.
///
/// The workflow is: pause, put a box around the thing, tap Track. Frames then
/// follows it forward through the clip and caches the result in the document,
/// so the blur that is attached to it moves with it in the preview and in the
/// export without re-running Vision.
struct TrackingInspector: View {
    let session: EditorSession
    let playback: PlaybackEngine
    let onDone: () -> Void

    @Environment(AppModel.self) private var app
    @State private var progress: Double?
    @State private var trackingTask: Task<Void, Never>?

    private var region: BlurRegion? {
        guard case .blur(let id) = session.selection else { return nil }
        return session.document.blurRegions.first { $0.id == id }
    }

    private var trackedObject: TrackedObject? {
        guard let id = region?.mask?.trackedObjectID else { return nil }
        return session.document.trackedObjects.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Tracking", comment: "Tool title"), onDone: {
            trackingTask?.cancel()
            onDone()
        }) {
            if session.document.kind != .video {
                Text("Tracking follows something through a video, so it needs a video.",
                     comment: "Tracking empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let region {
                controls(for: region)
            } else {
                Text("Select a blur to make it follow something.", comment: "Tracking empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func controls(for region: BlurRegion) -> some View {
        VStack(spacing: 12) {
            if let progress {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text("Following the region…", comment: "Tracking status")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            trackingTask?.cancel()
                            self.progress = nil
                        } label: {
                            Text("Stop", comment: "Tracking action")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
            } else {
                Text("Position the blur over what you want to follow, then track it forward from here.",
                     comment: "Tracking explanation")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        startTracking(region)
                    } label: {
                        Label {
                            Text("Track Forward", comment: "Tracking action")
                        } icon: {
                            Image(systemName: "dot.viewfinder")
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)

                    if trackedObject != nil {
                        Button {
                            clearTracking(region)
                        } label: {
                            Label {
                                Text("Clear", comment: "Tracking action")
                            } icon: {
                                Image(systemName: "xmark")
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                    }
                }

                if let object = trackedObject, let range = object.timeRange {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                        Text(
                            String(
                                localized: "Following from \(range.start.framesTimecode) to \(range.end.framesTimecode)",
                                comment: "Tracking status"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let lost = object.lostConfidenceAt {
                        Label {
                            Text(
                                String(
                                    localized: "Lost it at \(lost.framesTimecode). Move the blur back onto the subject there and track again.",
                                    comment: "Tracking warning"
                                )
                            )
                            .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func startTracking(_ region: BlurRegion) {
        playback.pause()
        trackingTask?.cancel()

        let startTime = session.currentTime
        let endTime = session.document.videoDuration
        guard endTime > startTime + 0.1 else { return }

        // Four samples a second is enough for a blur to look locked on, and a
        // fraction of the cost of every frame.
        let step: TimeInterval = 0.25
        let objectID = region.mask?.trackedObjectID ?? UUID()
        let startRect = region.mask?.boundingBox(at: startTime) ?? CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

        progress = 0
        trackingTask = Task {
            defer { progress = nil }

            await VisionService.shared.beginTracking(objectID, in: startRect)
            var samples: [TrackingSample] = [
                TrackingSample(time: startTime, rect: startRect, confidence: 1)
            ]
            var lostAt: TimeInterval?

            var time = startTime + step
            while time <= endTime {
                if Task.isCancelled { break }
                guard let frame = await VideoFrameSampler.frame(
                    at: time,
                    in: session.document,
                    maxPixelSize: 640
                ) else { break }

                do {
                    guard let sample = try await VisionService.shared.track(objectID, in: frame) else {
                        lostAt = time
                        break
                    }
                    samples.append(
                        TrackingSample(time: time, rect: sample.rect, confidence: sample.confidence)
                    )
                } catch {
                    lostAt = time
                    break
                }

                progress = min((time - startTime) / max(endTime - startTime, 0.001), 1)
                time += step
            }

            await VisionService.shared.endTracking(objectID)
            guard samples.count > 1 else {
                app.present(.visionUnavailable("nothing to follow in that region"))
                Haptics.failure()
                return
            }

            var object = TrackedObject(
                id: objectID,
                label: String(localized: "Tracked region", comment: "Tracked object label"),
                samples: samples
            )
            object.lostConfidenceAt = lostAt

            session.perform(String(localized: "Track", comment: "Undo action")) { document in
                document.trackedObjects.removeAll { $0.id == objectID }
                document.trackedObjects.append(object)
                if let index = document.blurRegions.firstIndex(where: { $0.id == region.id }) {
                    document.blurRegions[index].mask?.trackedObjectID = objectID
                }
            }
            Haptics.success()
        }
    }

    private func clearTracking(_ region: BlurRegion) {
        guard let objectID = region.mask?.trackedObjectID else { return }
        session.perform(String(localized: "Clear Tracking", comment: "Undo action")) { document in
            document.trackedObjects.removeAll { $0.id == objectID }
            if let index = document.blurRegions.firstIndex(where: { $0.id == region.id }) {
                document.blurRegions[index].mask?.trackedObjectID = nil
            }
        }
        Task { await VisionService.shared.endTracking(objectID) }
        Haptics.snap()
    }
}
