import SwiftUI

/// The Crop tool's controls.
///
/// The crop rectangle itself is dragged on the canvas; this row is the presets,
/// the orientation actions and straightening.
struct CropInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    private var crop: CropState {
        session.document.currentCrop(forClip: session.activeClipID)
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Crop", comment: "Tool title"), onDone: onDone) {
            VStack(spacing: 12) {
                ParameterSlider(
                    title: String(localized: "Straighten", comment: "Crop control"),
                    value: Binding(
                        get: { crop.straightenAngle * 180 / .pi },
                        set: { degrees in
                            var updated = crop
                            updated.straightenAngle = degrees * .pi / 180
                            session.updateCrop(updated, isFinal: false)
                        }
                    ),
                    range: -20...20,
                    neutral: 0,
                    format: { String(format: "%.0f°", $0) }
                ) { editing in
                    if !editing { session.updateCrop(crop, isFinal: true) }
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(AspectPreset.allCases) { preset in
                            Button {
                                applyAspect(preset)
                            } label: {
                                Text(preset.displayName)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background {
                                Capsule().fill(
                                    crop.aspect == preset
                                        ? Color.accentColor
                                        : Color(.tertiarySystemFill)
                                )
                            }
                            .foregroundStyle(crop.aspect == preset ? Color.white : Color.primary)
                            .accessibilityAddTraits(
                                crop.aspect == preset ? [.isSelected, .isButton] : .isButton
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)

                HStack(spacing: 10) {
                    orientationButton("rotate.left", label: String(localized: "Rotate Left", comment: "Crop action")) {
                        session.rotate(byQuarterTurns: -1)
                    }
                    orientationButton("rotate.right", label: String(localized: "Rotate Right", comment: "Crop action")) {
                        session.rotate(byQuarterTurns: 1)
                    }
                    orientationButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                                      label: String(localized: "Flip Horizontal", comment: "Crop action")) {
                        session.flip(horizontal: true)
                    }
                    orientationButton("arrow.up.and.down.righttriangle.up.righttriangle.down",
                                      label: String(localized: "Flip Vertical", comment: "Crop action")) {
                        session.flip(horizontal: false)
                    }

                    Spacer(minLength: 0)

                    Button {
                        session.updateCrop(.identity, isFinal: true)
                        Haptics.snap()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.glass)
                    .disabled(crop.isIdentity)
                    .accessibilityLabel(Text("Reset Crop", comment: "Crop action"))
                }
            }
        }
    }

    private func orientationButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }

    private func applyAspect(_ preset: AspectPreset) {
        var updated = crop
        updated.aspect = preset

        // Fit the largest rect of the chosen ratio inside the current crop, so
        // choosing a ratio never throws away more of the picture than it has to.
        if let ratio = preset.ratio {
            let sourceAspect = session.document.sourceAspectRatio
            let targetInSourceSpace = ratio / max(sourceAspect, 0.001)
            var width = updated.rect.width
            var height = width / targetInSourceSpace
            if height > updated.rect.height {
                height = updated.rect.height
                width = height * targetInSourceSpace
            }
            updated.rect = CGRect(
                x: updated.rect.midX - width / 2,
                y: updated.rect.midY - height / 2,
                width: width,
                height: height
            )
        } else if preset == .original {
            updated.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        updated.normalize()
        session.updateCrop(updated, isFinal: true)
        session.setOutputAspect(preset == .free ? .original : preset)
        Haptics.snap()
    }
}
