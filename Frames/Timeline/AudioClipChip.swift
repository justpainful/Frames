import SwiftUI

/// An audio clip on the timeline, drawn with its own waveform.
struct AudioClipChip: View {
    let clip: AudioClip
    let asset: SourceAsset?
    let scale: TimelineScale
    let height: CGFloat
    let isSelected: Bool

    @State private var waveform: Waveform?

    private var width: CGFloat { max(scale.width(for: clip.timelineDuration), 14) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(isSelected ? 0.9 : 0.65))

            if let waveform, !waveform.samples.isEmpty {
                WaveformShape(waveform: waveform, sourceRange: clip.source)
                    .fill(Color.white.opacity(0.85))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 3)
            }

            HStack(spacing: 3) {
                Image(systemName: clip.isMuted ? "speaker.slash.fill" : clip.role.symbolName)
                    .font(.system(size: 8, weight: .semibold))
                if width > 70 {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
        }
        .frame(width: width, height: height)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 1.5)
            }
        }
        .task(id: asset?.id) { await loadWaveform() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(clip.timelineDuration.framesShortTimecode)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var label: String {
        clip.label.isEmpty ? clip.role.displayName : clip.label
    }

    private var tint: Color {
        switch clip.role {
        case .voiceover: .green
        case .music: .blue
        case .extracted: .indigo
        case .soundEffect: .mint
        case .sourceAudio: .gray
        }
    }

    private func loadWaveform() async {
        guard let asset else { return }
        if let cached = await AudioWaveformGenerator.shared.cachedWaveform(for: asset) {
            waveform = cached
            return
        }
        waveform = try? await AudioWaveformGenerator.shared.waveform(for: asset)
    }
}

/// Draws the envelope for the portion of the source this clip uses.
struct WaveformShape: Shape {
    let waveform: Waveform
    let sourceRange: TimeRange

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard waveform.duration > 0, rect.width > 1, !waveform.samples.isEmpty else { return path }

        let columnWidth: CGFloat = 2
        let spacing: CGFloat = 1
        let step = columnWidth + spacing
        let columns = max(Int(rect.width / step), 1)
        let midY = rect.midY

        for column in 0..<columns {
            let progress = Double(column) / Double(columns)
            // Map across the clip's own source range, so trimming a clip shows
            // the part of the waveform it actually plays.
            let sourceTime = sourceRange.start + sourceRange.duration * progress
            let overall = sourceTime / waveform.duration
            let amplitude = CGFloat(waveform.value(at: overall))
            let barHeight = max(rect.height * amplitude, 1)

            path.addRoundedRect(
                in: CGRect(
                    x: rect.minX + CGFloat(column) * step,
                    y: midY - barHeight / 2,
                    width: columnWidth,
                    height: barHeight
                ),
                cornerSize: CGSize(width: 1, height: 1)
            )
        }
        return path
    }
}
