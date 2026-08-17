import SwiftUI

/// The band the user drags to choose what Remove Range will delete.
///
/// Remove Range is a first-class operation in Frames rather than a sequence of
/// two splits and a delete, and this is what makes it direct: two handles over
/// the timeline, a live duration readout, and one confirmation.
struct RangeSelectionOverlay: View {
    let range: TimeRange
    let scale: TimelineScale
    let offset: CGFloat
    let height: CGFloat
    let onChange: (TimeRange) -> Void

    @State private var dragOrigin: TimeRange?

    private let handleWidth: CGFloat = 18

    var body: some View {
        let startX = offset + scale.point(for: range.start)
        let width = max(scale.width(for: range.duration), 4)

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red.opacity(0.22))
                .frame(width: width, height: height)
                .overlay(alignment: .top) {
                    Text(range.duration.framesTimecode)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .offset(y: -6)
                        .fixedSize()
                }
                .offset(x: startX)
                .allowsHitTesting(false)

            handle(isLeading: true)
                .offset(x: startX - handleWidth / 2)
            handle(isLeading: false)
                .offset(x: startX + width - handleWidth / 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Range to remove", comment: "Accessibility label"))
        .accessibilityValue(range.duration.framesTimecode)
    }

    private func handle(isLeading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.red)
            .frame(width: handleWidth, height: height)
            .overlay {
                Image(systemName: isLeading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .contentShape(Rectangle().inset(by: -10))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = range
                            Haptics.prepare()
                        }
                        guard let origin = dragOrigin else { return }
                        let delta = scale.time(for: value.translation.width)

                        if isLeading {
                            let newStart = min(max(origin.start + delta, 0), origin.end - 0.05)
                            onChange(TimeRange(start: newStart, end: origin.end))
                        } else {
                            let newEnd = max(origin.end + delta, origin.start + 0.05)
                            onChange(TimeRange(start: origin.start, end: newEnd))
                        }
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        Haptics.snap()
                    }
            )
            .accessibilityLabel(
                isLeading
                    ? Text("Range start", comment: "Accessibility label")
                    : Text("Range end", comment: "Accessibility label")
            )
    }
}
