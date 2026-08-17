import SwiftUI

/// The Frames mark, drawn as vectors rather than shipped as a bitmap so it is
/// crisp at any size and adapts to light and dark automatically.
///
/// Two overlapping frames — one landscape, one portrait. It reads as the app's
/// name, and says photo and video, horizontal and vertical, without a single
/// literal camera.
struct FramesMark: View {
    var lineWidth: CGFloat = 0.047
    var accent: Color = .accentColor
    var primary: Color = .primary

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let stroke = side * lineWidth
            let long = side * 0.86
            let short = side * 0.53
            let radius = side * 0.105

            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(accent, lineWidth: stroke)
                    .frame(width: short, height: long)

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(primary, lineWidth: stroke)
                    .frame(width: long, height: short)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The mark with the wordmark beside it, for the chooser screen.
struct FramesWordmark: View {
    var body: some View {
        HStack(spacing: 12) {
            FramesMark()
                .frame(width: 34, height: 34)
            Text("Frames")
                .font(.system(.largeTitle, design: .default, weight: .semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Frames", comment: "App name"))
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Mark") {
    VStack(spacing: 32) {
        FramesMark().frame(width: 120, height: 120)
        FramesWordmark()
    }
    .padding()
}
