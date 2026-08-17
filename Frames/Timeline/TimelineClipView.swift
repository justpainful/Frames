import CoreGraphics
import SwiftUI

/// One clip in the timeline, drawn as a filmstrip.
///
/// Thumbnails arrive asynchronously and are cached by the provider, so
/// re-laying out during a pinch never blocks and never re-decodes what is
/// already on screen.
struct TimelineClipView: View {
    let clip: VideoClip
    let asset: SourceAsset?
    let scale: TimelineScale
    let isSelected: Bool
    let height: CGFloat

    @State private var frames: [Int: CGImage] = [:]
    @State private var generationToken = UUID()

    private var width: CGFloat { scale.width(for: clip.timelineDuration) }
    private var thumbnailWidth: CGFloat { max(height * 0.62, 22) }

    var body: some View {
        ZStack(alignment: .leading) {
            filmstrip
            if clip.isFrozen {
                freezeBadge
            }
            if clip.speed != 1 || clip.isMuted {
                badges
            }
        }
        .frame(width: max(width, 3), height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: isSelected ? 2.5 : 0.5
                )
        }
        .task(id: TaskKey(width: width, assetID: asset?.id, source: clip.source)) {
            await loadThumbnails()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Video clip", comment: "Accessibility label"))
        .accessibilityValue(clip.timelineDuration.framesShortTimecode)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private struct TaskKey: Hashable {
        let width: CGFloat
        let assetID: UUID?
        let source: TimeRange
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(thumbnailCount, 1), id: \.self) { index in
                Group {
                    if let image = frames[index] {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(.tertiarySystemFill))
                    }
                }
                .frame(width: thumbnailWidth, height: height)
                .clipped()
            }
        }
        .frame(width: max(width, 3), alignment: .leading)
        .clipped()
    }

    private var freezeBadge: some View {
        Image(systemName: "snowflake")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: Circle())
            .padding(4)
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer()
            HStack(spacing: 4) {
                if clip.speed != 1 {
                    Text(speedLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                if clip.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(4)
        }
    }

    private var speedLabel: String {
        let value = clip.speed
        return value == value.rounded()
            ? "\(Int(value))×"
            : String(format: "%.2g×", value)
    }

    private var thumbnailCount: Int {
        scale.thumbnailCount(forWidth: width, thumbnailWidth: thumbnailWidth)
    }

    private func loadThumbnails() async {
        guard let asset, asset.kind == .video else { return }
        let count = thumbnailCount
        guard count > 0 else { return }

        // One sample per visible thumbnail, taken from the middle of the slice
        // it represents so the strip reads as a continuous shot.
        let times: [TimeInterval] = (0..<count).map { index in
            let progress = (Double(index) + 0.5) / Double(count)
            return clip.sourceTime(forOffset: clip.timelineDuration * progress)
        }

        // Anything already cached should appear immediately rather than after a
        // round trip through the generator.
        for (index, time) in times.enumerated() {
            if let cached = await ThumbnailProvider.shared.cachedThumbnail(
                assetID: asset.id, sourceTime: time, height: height
            ) {
                frames[index] = cached
            }
        }

        await ThumbnailProvider.shared.generate(
            for: asset,
            times: times,
            height: height
        ) { time, image in
            await MainActor.run {
                guard let index = nearestIndex(of: time, in: times) else { return }
                frames[index] = image
            }
        }
    }

    private func nearestIndex(of time: TimeInterval, in times: [TimeInterval]) -> Int? {
        times.indices.min { abs(times[$0] - time) < abs(times[$1] - time) }
    }
}
