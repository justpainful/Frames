import SwiftUI

/// Controls for an image overlay: its look, its opacity, and cutting the
/// background out of it.
struct OverlayInspector: View {
    let session: EditorSession
    let focus: EditorDetail
    let onDone: () -> Void

    @Environment(AppModel.self) private var app
    @State private var isCuttingOut = false

    private var overlay: ImageOverlay? {
        guard case .imageOverlay(let id) = session.selection else { return nil }
        return session.document.imageOverlays.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Image", comment: "Tool title"), onDone: onDone) {
            if let overlay {
                switch focus {
                case .removeBackground:
                    cutoutControls(overlay)
                case .overlayOpacity:
                    opacityControls(overlay)
                default:
                    styleControls(overlay)
                }
            } else {
                Text("Select an image to change it.", comment: "Overlay empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func cutoutControls(_ overlay: ImageOverlay) -> some View {
        VStack(spacing: 10) {
            Text("Frames finds the subject on this device and keeps the original image, so this can be turned off again.",
                 comment: "Cut out explanation")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if overlay.isBackgroundRemoved {
                Button {
                    session.updateImageOverlay(overlay.id) { $0.isBackgroundRemoved = false }
                    Haptics.snap()
                } label: {
                    Label {
                        Text("Restore Background", comment: "Cut out action")
                    } icon: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    Task { await cutOut(overlay) }
                } label: {
                    Label {
                        Text("Remove Background", comment: "Cut out action")
                    } icon: {
                        Image(systemName: "person.and.background.dotted")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(isCuttingOut)
                .overlay {
                    if isCuttingOut { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func opacityControls(_ overlay: ImageOverlay) -> some View {
        ParameterSlider(
            title: String(localized: "Opacity", comment: "Overlay control"),
            value: Binding(
                get: { overlay.transform.opacity },
                set: { value in
                    session.updateImageOverlay(overlay.id, isFinal: false) { $0.transform.opacity = value }
                }
            ),
            range: 0...1,
            neutral: nil,
            format: { "\(Int(($0 * 100).rounded()))" }
        ) { editing in
            if !editing { session.endInteraction() }
        }
    }

    private func styleControls(_ overlay: ImageOverlay) -> some View {
        VStack(spacing: 10) {
            ParameterSlider(
                title: String(localized: "Corner Radius", comment: "Overlay control"),
                value: Binding(
                    get: { overlay.cornerRadius },
                    set: { value in
                        session.updateImageOverlay(overlay.id, isFinal: false) { $0.cornerRadius = value }
                    }
                ),
                range: 0...0.5,
                neutral: 0,
                format: { "\(Int(($0 * 200).rounded()))" }
            ) { editing in
                if !editing { session.endInteraction() }
            }

            Toggle(isOn: Binding(
                get: { overlay.border.isEnabled },
                set: { value in session.updateImageOverlay(overlay.id) { $0.border.isEnabled = value } }
            )) {
                Text("Border", comment: "Overlay control").font(.subheadline)
            }
            .toggleStyle(.switch)

            if overlay.border.isEnabled {
                ColorSwatchRow(color: Binding(
                    get: { overlay.border.color },
                    set: { value in session.updateImageOverlay(overlay.id) { $0.border.color = value } }
                ))
            }

            Toggle(isOn: Binding(
                get: { overlay.shadow.isEnabled },
                set: { value in session.updateImageOverlay(overlay.id) { $0.shadow.isEnabled = value } }
            )) {
                Text("Shadow", comment: "Overlay control").font(.subheadline)
            }
            .toggleStyle(.switch)

            SegmentedChoice(
                values: OverlayBlendMode.allCases,
                selection: Binding(
                    get: { overlay.blendMode },
                    set: { value in session.updateImageOverlay(overlay.id) { $0.blendMode = value } }
                ),
                label: { $0.displayName }
            )
        }
    }

    private func cutOut(_ overlay: ImageOverlay) async {
        isCuttingOut = true
        defer { isCuttingOut = false }

        guard let asset = session.document.asset(id: overlay.assetID) else { return }
        let url = SessionPaths.mediaURL(for: asset.fileName)

        do {
            let decoded = try await ImageLoader.shared.image(at: url, maxPixelSize: 3000)
            let source = CIImage(cgImage: decoded)
            let cutout = try await VisionService.shared.removeBackground(from: source)

            try SessionPaths.createDirectories()
            let fileName = "\(overlay.id.uuidString).png"
            let destination = SessionPaths.cutoutURL(for: fileName)
            // PNG because the whole point is the transparency.
            try RenderContext.shared.export.writePNGRepresentation(
                of: cutout,
                to: destination,
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            )

            session.updateImageOverlay(overlay.id) {
                $0.isBackgroundRemoved = true
                $0.cutoutFileName = fileName
            }
            Haptics.success()
        } catch let error as FramesError {
            app.present(error)
            Haptics.failure()
        } catch {
            app.present(.visionUnavailable(error.localizedDescription))
            Haptics.failure()
        }
    }
}
