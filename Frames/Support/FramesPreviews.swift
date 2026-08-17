#if DEBUG
import SwiftUI

/// Fixtures for SwiftUI previews.
///
/// Previews must never reach for the photo library or the file system: a
/// preview that only works on the machine that has the right photo in it is not
/// a preview. These documents are built from described-but-absent media, which
/// is enough for every view that draws chrome rather than pixels.
enum PreviewFixtures {
    static var videoAsset: SourceAsset {
        SourceAsset(
            fileName: "preview.mov",
            kind: .video,
            duration: 24,
            displaySize: CGSize(width: 1920, height: 1080),
            nominalFrameRate: 30,
            hasAudioTrack: true
        )
    }

    static var photoAsset: SourceAsset {
        SourceAsset(
            fileName: "preview.jpg",
            kind: .photo,
            displaySize: CGSize(width: 4032, height: 3024)
        )
    }

    static var videoDocument: EditDocument {
        var document = EditDocument.video(asset: videoAsset)
        _ = try? document.split(at: 8)
        _ = try? document.split(at: 16)
        document.grade.filter = FilterInstance(presetID: "warmCinema", intensity: 0.7)
        document.grade.adjustments[.exposure] = 0.18
        document.textOverlays = [
            TextOverlay(string: "Frames", timeRange: TimeRange(start: 2, duration: 4))
        ]
        document.blurRegions = [BlurRegion.make(scope: .face)]
        return document
    }

    static var photoDocument: EditDocument {
        var document = EditDocument.photo(asset: photoAsset)
        document.grade.adjustments[.contrast] = 0.25
        document.grade.adjustments[.vibrance] = 0.3
        return document
    }

    @MainActor static var videoSession: EditorSession {
        EditorSession(document: videoDocument)
    }

    @MainActor static var photoSession: EditorSession {
        EditorSession(document: photoDocument)
    }
}

// MARK: - Previews

#Preview("Chooser") {
    MediaChooserView()
        .environment(AppModel())
}

#Preview("Timeline") {
    let session = PreviewFixtures.videoSession
    return VStack {
        Spacer()
        TimelineView(session: session, playback: PlaybackEngine())
        Spacer()
    }
    .background(Color(.systemBackground))
}

#Preview("Transport") {
    TransportControls(session: PreviewFixtures.videoSession, playback: PlaybackEngine())
}

#Preview("Adjust") {
    AdjustInspector(session: PreviewFixtures.photoSession) {}
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color(.secondarySystemBackground))
}

#Preview("Filters") {
    FilterInspector(session: PreviewFixtures.photoSession) {}
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color(.secondarySystemBackground))
}

#Preview("Blur") {
    BlurInspector(session: PreviewFixtures.photoSession, focus: .blur) {}
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color(.secondarySystemBackground))
}

#Preview("Crop") {
    CropInspector(session: PreviewFixtures.photoSession) {}
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color(.secondarySystemBackground))
}

#Preview("Text") {
    TextInspector(session: PreviewFixtures.photoSession, focus: .font) {}
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color(.secondarySystemBackground))
}

#Preview("Portrait") {
    PortraitInspector(session: PreviewFixtures.photoSession)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color(.secondarySystemBackground))
}

#Preview("Retouch") {
    RetouchInspector(session: PreviewFixtures.photoSession) {}
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color(.secondarySystemBackground))
}

#Preview("Export") {
    ExportView(session: PreviewFixtures.videoSession) {}
        .environment(AppModel())
}

#Preview("Tool strip") {
    VStack(spacing: 20) {
        ToolStrip(items: EditorBottomArea.videoTools, selected: "adjust") { _ in }
        ToolStrip(items: EditorBottomArea.clipTools, selected: nil) { _ in }
        ToolStrip(items: EditorBottomArea.textTools, selected: "font") { _ in }
    }
    .background(Color(.systemBackground))
}

#Preview("Parameter slider") {
    @Previewable @State var value: Double = 0.3
    return VStack(spacing: 24) {
        ParameterSlider(title: "Exposure", value: $value, range: -1...1)
        ParameterSlider(title: "Grain", value: $value, range: 0...1, neutral: 0)
    }
    .padding()
}

#Preview("Arabic") {
    MediaChooserView()
        .environment(AppModel())
        .environment(\.locale, Locale(identifier: "ar"))
        .environment(\.layoutDirection, .rightToLeft)
}
#endif
