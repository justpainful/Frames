import SwiftUI

/// The capture screen.
///
/// A viewfinder showing the *processed* picture, one row of Portrait presets,
/// and a shutter. Everything else is deliberately absent: the point of this
/// screen is to see what the recording will look like before it exists, and a
/// wall of controls over the viewfinder defeats that.
struct CameraView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var camera = CameraService()
    @State private var mode: CaptureMode = .video
    @State private var isShowingSettings = false
    @State private var isFinishing = false

    enum CaptureMode: String, CaseIterable, Identifiable {
        case photo
        case video

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .photo: String(localized: "Photo", comment: "Capture mode")
            case .video: String(localized: "Video", comment: "Capture mode")
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .ready:
                CameraPreviewView(camera: camera)
                    .ignoresSafeArea()
            case .unavailable(let error):
                unavailable(error)
            case .idle, .preparing:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if camera.status == .ready {
                    controls
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await camera.prepare() }
        .onDisappear {
            camera.cancelRecording()
            camera.stop()
        }
        .sheet(isPresented: $isShowingSettings) {
            CapturePortraitSettings(camera: camera)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                camera.cancelRecording()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel(Text("Close", comment: "Editor action"))

            Spacer()

            if camera.isRecording {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(camera.recordedDuration.framesTimecode)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            }

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel(Text("Portrait Settings", comment: "Capture action"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            presetRow

            if !camera.isRecording {
                HStack(spacing: 26) {
                    ForEach(CaptureMode.allCases) { option in
                        Button {
                            mode = option
                            Haptics.snap()
                        } label: {
                            Text(option.displayName)
                                .font(.subheadline.weight(mode == option ? .semibold : .regular))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(mode == option ? Color.yellow : Color.white.opacity(0.7))
                        .accessibilityAddTraits(mode == option ? [.isSelected, .isButton] : .isButton)
                    }
                }
            }

            HStack {
                Color.clear.frame(width: 52, height: 52)

                Spacer()

                shutter

                Spacer()

                Button {
                    camera.toggleCamera()
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.camera")
                        .font(.title3)
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.3 : 1)
                .accessibilityLabel(Text("Switch Camera", comment: "Capture action"))
            }
            .padding(.horizontal, 30)
        }
        .padding(.bottom, 26)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var shutter: some View {
        Button {
            Task { await triggerShutter() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)

                if camera.isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(mode == .video ? Color.red : Color.white)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isFinishing)
        .animation(.snappy(duration: 0.2), value: camera.isRecording)
        .accessibilityLabel(
            camera.isRecording
                ? Text("Stop Recording", comment: "Capture action")
                : (mode == .video
                    ? Text("Start Recording", comment: "Capture action")
                    : Text("Take Photo", comment: "Capture action"))
        )
    }

    private var presetRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                presetChip(
                    title: String(localized: "Off", comment: "Portrait preset"),
                    isSelected: !camera.portrait.isEnabled
                ) {
                    camera.portrait.isEnabled = false
                    Haptics.snap()
                }

                ForEach(PortraitSettings.Preset.allCases) { preset in
                    presetChip(
                        title: preset.displayName,
                        isSelected: camera.portrait.isEnabled
                            && camera.portrait.matchingPreset == preset
                    ) {
                        camera.portrait = preset.settings
                        Haptics.snap()
                    }
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func presetChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.black : Color.white)
        .background {
            Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.18))
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func unavailable(_ error: FramesError) -> some View {
        ContentUnavailableView {
            Label {
                Text(error.title)
            } icon: {
                Image(systemName: "camera.fill")
            }
        } description: {
            Text(error.message)
        } actions: {
            if error.suggestsSettings {
                Button {
                    app.openSystemSettings()
                } label: {
                    Text("Open Settings", comment: "Alert button")
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                dismiss()
            } label: {
                Text("Close", comment: "Editor action")
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Actions

    private func triggerShutter() async {
        guard !isFinishing else { return }
        switch mode {
        case .photo:
            isFinishing = true
            defer { isFinishing = false }
            do {
                let asset = try await camera.capturePhoto()
                camera.stop()
                dismiss()
                app.openEditor(with: asset)
            } catch let error as FramesError {
                app.present(error)
            } catch {
                app.present(.exportFailed(error.localizedDescription))
            }

        case .video:
            if camera.isRecording {
                isFinishing = true
                defer { isFinishing = false }
                do {
                    let asset = try await camera.stopRecording()
                    camera.stop()
                    dismiss()
                    app.openEditor(with: asset)
                } catch let error as FramesError {
                    app.present(error)
                } catch {
                    app.present(.exportFailed(error.localizedDescription))
                }
            } else {
                camera.startRecording()
            }
        }
    }
}

/// The full Portrait controls, reachable from the viewfinder without leaving it.
struct CapturePortraitSettings: View {
    let camera: CameraService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { camera.portrait.isEnabled },
                        set: { camera.portrait.isEnabled = $0 }
                    )) {
                        Text("Portrait Mode", comment: "Portrait control")
                    }
                } footer: {
                    Text("Cleans noise before lifting the shadows, then smooths skin without softening edges, hair or clothing.",
                         comment: "Portrait explanation")
                }

                if camera.portrait.isEnabled {
                    Section {
                        slider(String(localized: "Smoothing", comment: "Portrait control"),
                               value: \.smoothing)
                        slider(String(localized: "Detail", comment: "Retouch control"),
                               value: \.detailPreservation)
                        slider(String(localized: "Low Light", comment: "Portrait preset"),
                               value: \.lowLight)
                        slider(String(localized: "Color Noise", comment: "Portrait control"),
                               value: \.colorNoiseReduction)
                        slider(String(localized: "Glow", comment: "Portrait control"),
                               value: \.glow)
                        slider(String(localized: "Evenness", comment: "Portrait control"),
                               value: \.evenness)
                        slider(String(localized: "Stability", comment: "Portrait control"),
                               value: \.temporalStability)
                    }
                }
            }
            .navigationTitle(Text("Portrait", comment: "Tool"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Closes a tool")
                    }
                }
            }
        }
    }

    private func slider(
        _ title: String,
        value keyPath: WritableKeyPath<PortraitSettings, Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((camera.portrait[keyPath: keyPath] * 100).rounded()))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)

            Slider(
                value: Binding(
                    get: { camera.portrait[keyPath: keyPath] },
                    set: { camera.portrait[keyPath: keyPath] = $0 }
                ),
                in: 0...1
            )
            .accessibilityLabel(title)
        }
    }
}
