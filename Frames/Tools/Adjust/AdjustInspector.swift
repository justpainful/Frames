import CoreImage
import SwiftUI

/// The Adjust tool.
///
/// A horizontal strip of parameters, and one large accurate slider for whichever
/// one is selected. Double-tapping a parameter resets it; there is a reset for
/// the whole set. Nothing is nested more than one level deep.
struct AdjustInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    @State private var group: AdjustmentGroup = .light
    @State private var isAnalysing = false

    private var adjustments: AdjustmentSet { session.document.grade.adjustments }
    private var focused: AdjustmentParameter { session.focusedAdjustment ?? group.parameters[0] }

    var body: some View {
        InspectorSurface(title: String(localized: "Adjust", comment: "Tool title"), onDone: onDone) {
            VStack(spacing: 12) {
                ParameterSlider(
                    title: focused.displayName,
                    value: Binding(
                        get: { adjustments[focused] },
                        set: { session.setAdjustment(focused, to: $0, isFinal: false) }
                    ),
                    range: focused.range,
                    neutral: focused.defaultValue,
                    format: { focused.formattedValue($0) }
                ) { editing in
                    if !editing {
                        session.setAdjustment(focused, to: adjustments[focused], isFinal: true)
                    }
                }

                parameterStrip

                HStack(spacing: 10) {
                    SegmentedChoice(
                        values: AdjustmentGroup.allCases,
                        selection: Binding(
                            get: { group },
                            set: { newGroup in
                                group = newGroup
                                session.focusedAdjustment = newGroup.parameters.first
                            }
                        ),
                        label: { $0.displayName }
                    )

                    Spacer(minLength: 0)

                    Button {
                        Task { await runAutoEnhance() }
                    } label: {
                        Label {
                            Text("Auto", comment: "Adjust action")
                        } icon: {
                            Image(systemName: "wand.and.stars")
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.glass)
                    .disabled(isAnalysing)

                    Button {
                        session.resetAllAdjustments()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.glass)
                    .disabled(adjustments.isIdentity)
                    .accessibilityLabel(Text("Reset All", comment: "Adjust action"))
                }
            }
        }
        .onAppear {
            if session.focusedAdjustment == nil {
                session.focusedAdjustment = group.parameters.first
            } else if let focused = session.focusedAdjustment {
                group = focused.group
            }
        }
    }

    private var parameterStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(group.parameters) { parameter in
                    Button {
                        session.focusedAdjustment = parameter
                        Haptics.snap()
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .stroke(Color(.tertiarySystemFill), lineWidth: 2)
                                    .frame(width: 34, height: 34)
                                if adjustments.isActive(parameter) {
                                    Circle()
                                        .trim(from: 0, to: abs(adjustments[parameter]))
                                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 34, height: 34)
                                }
                                Image(systemName: parameter.symbolName)
                                    .font(.system(size: 14))
                            }
                            Text(parameter.displayName)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .frame(width: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(focused == parameter ? Color.accentColor : Color.primary)
                    // Double tap is the fastest way back to neutral, and it is
                    // the gesture people already try.
                    .onTapGesture(count: 2) {
                        session.resetAdjustment(parameter)
                    }
                    .accessibilityLabel(parameter.displayName)
                    .accessibilityValue(parameter.formattedValue(adjustments[parameter]))
                    .accessibilityAddTraits(focused == parameter ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .mask(EdgeFade())
    }

    private func runAutoEnhance() async {
        isAnalysing = true
        defer { isAnalysing = false }

        guard let asset = session.document.primaryAsset else { return }
        let url = SessionPaths.mediaURL(for: asset.fileName)

        // Auto reads a small version of the frame: none of the statistics it
        // uses need full resolution, and this keeps it instant.
        let image: CIImage?
        switch asset.kind {
        case .photo:
            image = (try? await ImageLoader.shared.image(at: url, maxPixelSize: 512))
                .map { CIImage(cgImage: $0) }
        case .video:
            image = await VideoFrameSampler.frame(at: session.currentTime, in: session.document, maxPixelSize: 512)
        }

        guard let image else {
            Haptics.failure()
            return
        }
        let result = AutoEnhanceAnalyzer.analyse(image, context: RenderContext.shared.preview)
        session.applyAutoEnhance(result)
        session.focusedAdjustment = result.activeParameters.first ?? .exposure
        if let first = result.activeParameters.first {
            group = first.group
        }
    }
}
