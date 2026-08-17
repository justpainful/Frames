import SwiftUI
import UIKit

/// The export sheet.
///
/// Three choices, an estimate, and a button. Codec, bitrate and colour live
/// behind Advanced, because nobody should need to know what HEVC is to save a
/// video.
struct ExportView: View {
    let session: EditorSession
    let onFinished: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var settings = ExportSettings.default
    @State private var isShowingAdvanced = false
    @State private var progress: ExportProgress?
    @State private var finishedURL: URL?
    @State private var isShowingShareSheet = false
    @State private var exportTask: Task<Void, Never>?

    private var document: EditDocument { session.document }
    private var isVideo: Bool { document.kind == .video }

    private var sourceLongEdge: CGFloat {
        document.primaryAsset.map { max($0.displaySize.width, $0.displaySize.height) } ?? 1920
    }

    private var sourceFrameRate: Double {
        document.primaryAsset?.nominalFrameRate ?? 30
    }

    var body: some View {
        NavigationStack {
            Group {
                if let finishedURL {
                    successView(url: finishedURL)
                } else if let progress {
                    progressView(progress)
                } else {
                    optionsForm
                }
            }
            .navigationTitle(Text("Export", comment: "Export sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if finishedURL == nil {
                        Button {
                            exportTask?.cancel()
                            dismiss()
                        } label: {
                            Text("Cancel", comment: "Export action")
                        }
                    }
                }
            }
        }
        .presentationDetents(finishedURL == nil ? [.medium, .large] : [.medium])
        // Without this the sheet is translucent over live video, and every
        // material in it samples moving frames.
        .presentationBackground(Color(.systemGroupedBackground))
        .sheet(isPresented: $isShowingShareSheet) {
            if let finishedURL {
                ShareSheet(items: [finishedURL])
            }
        }
        .onAppear {
            settings = settings.resolved(
                forSourceLongEdge: sourceLongEdge,
                sourceFrameRate: sourceFrameRate
            )
        }
    }

    // MARK: - Options

    private var optionsForm: some View {
        Form {
            Section {
                Picker(selection: $settings.resolution) {
                    ForEach(ExportSettings.availableResolutions(sourceLongEdge: sourceLongEdge)) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    Text("Resolution", comment: "Export option")
                }

                if isVideo {
                    Picker(selection: $settings.frameRate) {
                        ForEach(ExportSettings.availableFrameRates(sourceFrameRate: sourceFrameRate)) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        Text("Frame Rate", comment: "Export option")
                    }
                }

                Picker(selection: $settings.quality) {
                    ForEach(ExportSettings.Quality.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    Text("Quality", comment: "Export option")
                }
            } footer: {
                Text(estimateText)
            }

            Section {
                DisclosureGroup(isExpanded: $isShowingAdvanced) {
                    if isVideo {
                        Picker(selection: $settings.videoCodec) {
                            ForEach(ExportSettings.VideoCodec.allCases) { option in
                                VStack(alignment: .leading) {
                                    Text(option.displayName)
                                    Text(option.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(option)
                            }
                        } label: {
                            Text("Codec", comment: "Export option")
                        }

                        Picker(selection: $settings.audioQuality) {
                            ForEach(ExportSettings.AudioQuality.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        } label: {
                            Text("Audio", comment: "Export option")
                        }
                    } else {
                        Picker(selection: $settings.stillFormat) {
                            ForEach(ExportSettings.StillFormat.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        } label: {
                            Text("Format", comment: "Export option")
                        }
                    }

                    Toggle(isOn: $settings.preservesWideColor) {
                        Text("Keep Wide Color", comment: "Export option")
                    }
                } label: {
                    Text("Advanced", comment: "Export section")
                }
            }

        }
        .safeAreaInset(edge: .bottom) {
            // Save lives in a bar of its own rather than as a list row. A glass
            // button on a clear row samples whatever is behind the *sheet*,
            // which over live video reads as a smear rather than a button.
            Button {
                startExport()
            } label: {
                Text("Save", comment: "Export action")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(.bar)
        }
    }

    private var estimateText: String {
        guard isVideo else {
            return String(localized: "Saved to your photo library.", comment: "Export footer")
        }
        let longEdge = settings.resolution.longEdge(sourceLongEdge: sourceLongEdge)
        let aspect = document.outputAspectRatio
        let size = aspect >= 1
            ? CGSize(width: longEdge, height: longEdge / aspect)
            : CGSize(width: longEdge * aspect, height: longEdge)
        let frameRate = settings.frameRate.value ?? sourceFrameRate
        let bytes = settings.estimatedFileSize(
            duration: document.duration,
            size: size,
            frameRate: frameRate
        )
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "About \(formatted).", comment: "Export size estimate")
    }

    // MARK: - Progress and result

    private func progressView(_ progress: ExportProgress) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)
            Text(statusText(for: progress))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func statusText(for progress: ExportProgress) -> String {
        switch progress {
        case .preparing:
            String(localized: "Getting ready…", comment: "Export status")
        case .rendering(let value):
            String(localized: "Rendering \(Int(value * 100))%", comment: "Export status")
        case .saving:
            String(localized: "Saving to Photos…", comment: "Export status")
        case .finished:
            String(localized: "Done", comment: "Export status")
        case .failed(let error):
            error.message
        }
    }

    private func successView(url: URL) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Saved to Photos", comment: "Export success")
                .font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 12) {
                Button {
                    isShowingShareSheet = true
                } label: {
                    Text("Share", comment: "Export action")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    finish(url: url)
                } label: {
                    Text("Done", comment: "Export action")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Actions

    private func startExport() {
        let service = ExportService()
        let document = session.document
        let settings = self.settings

        progress = .preparing
        exportTask = Task {
            do {
                let url = try await service.export(document: document, settings: settings) { update in
                    Task { @MainActor in
                        self.progress = update
                    }
                }
                progress = .saving
                try await service.saveToPhotos(url, kind: document.kind)
                progress = .finished(url)
                finishedURL = url
                Haptics.success()
            } catch let error as FramesError {
                progress = nil
                app.present(error)
                Haptics.failure()
            } catch {
                progress = nil
                app.present(.exportFailed(error.localizedDescription))
                Haptics.failure()
            }
        }
    }

    /// Finishing an export ends the recoverable session: the work is safe in the
    /// library now, so keeping a copy on disk would only be clutter.
    private func finish(url: URL) {
        Task {
            await ExportService().discardRender(at: url)
            await session.finish()
            dismiss()
            onFinished()
        }
    }
}

/// The system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
