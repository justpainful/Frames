import SwiftUI

/// The one large, accurate slider every parameter uses.
///
/// A single slider design for every adjustment means the user learns it once.
/// It is deliberately tall, has a detent at the parameter's neutral value, and
/// reports its value continuously so the preview follows the finger rather than
/// the release.
struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Where the "no change" detent sits, if there is one.
    var neutral: Double? = 0
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var hasSnapped = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(format(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            GeometryReader { proxy in
                track(width: proxy.size.width)
            }
            .frame(height: 30)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            default: break
            }
        }
    }

    private func track(width: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let progress = span > 0 ? (value - range.lowerBound) / span : 0
        let neutralProgress = neutral.map { span > 0 ? ($0 - range.lowerBound) / span : 0 }
        let knobX = width * CGFloat(progress)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color(.tertiarySystemFill))
                .frame(height: 5)

            // Fill runs from the neutral point, so a bipolar parameter reads as
            // "how far from normal" rather than "how far from the left".
            if let neutralProgress {
                let start = min(CGFloat(neutralProgress), CGFloat(progress))
                let end = max(CGFloat(neutralProgress), CGFloat(progress))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max((end - start) * width, 0), height: 5)
                    .offset(x: start * width)
            } else {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: knobX, height: 5)
            }

            if let neutralProgress, neutralProgress > 0.01, neutralProgress < 0.99 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 1.5, height: 11)
                    .offset(x: CGFloat(neutralProgress) * width - 0.75)
            }

            Circle()
                .fill(.white)
                .frame(width: isDragging ? 26 : 22, height: isDragging ? 26 : 22)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .offset(x: knobX - (isDragging ? 13 : 11))
                .animation(.snappy(duration: 0.15), value: isDragging)
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !isDragging {
                        isDragging = true
                        Haptics.prepare()
                        onEditingChanged(true)
                    }
                    let raw = range.lowerBound + Double(gesture.location.x / max(width, 1)) * span
                    let clamped = min(max(raw, range.lowerBound), range.upperBound)

                    // A detent at neutral: getting back to "off" should not
                    // require surgery.
                    if let neutral, abs(clamped - neutral) < span * 0.02 {
                        if !hasSnapped {
                            hasSnapped = true
                            Haptics.snap()
                        }
                        value = neutral
                    } else {
                        hasSnapped = false
                        value = clamped
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    hasSnapped = false
                    onEditingChanged(false)
                }
        )
    }
}

/// A compact horizontal picker for a small set of named choices.
struct SegmentedChoice<Value: Hashable & Identifiable>: View {
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var symbol: ((Value) -> String)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(values) { value in
                    Button {
                        selection = value
                        Haptics.snap()
                    } label: {
                        HStack(spacing: 5) {
                            if let symbol {
                                Image(systemName: symbol(value))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text(label(value))
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selection == value {
                            Capsule().fill(Color.accentColor)
                        } else {
                            Capsule().fill(Color(.tertiarySystemFill))
                        }
                    }
                    .foregroundStyle(selection == value ? Color.white : Color.primary)
                    .accessibilityAddTraits(selection == value ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .mask(EdgeFade())
    }
}
