import SwiftUI

/// Play, pause, step and the timecode.
///
/// Deliberately small and above the timeline rather than over the media: the
/// picture is what the user is looking at, and transport controls that sit on
/// top of it are the first thing to get in the way.
struct TransportControls: View {
    let session: EditorSession
    let playback: PlaybackEngine

    var body: some View {
        // Transport on the left, timecode on the right, and nothing stretched
        // across the gap between them: the two halves are read separately, so a
        // single spacer is the whole layout.
        HStack(spacing: 12) {
            Button {
                playback.step(byFrames: -1)
                session.seek(to: playback.currentTime)
            } label: {
                Image(systemName: "backward.frame.fill")
                    .font(.footnote)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Previous Frame", comment: "Playback action"))

            Button {
                playback.togglePlayback()
                Haptics.snap()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .accessibilityLabel(
                playback.isPlaying
                    ? Text("Pause", comment: "Playback action")
                    : Text("Play", comment: "Playback action")
            )

            Button {
                playback.step(byFrames: 1)
                session.seek(to: playback.currentTime)
            } label: {
                Image(systemName: "forward.frame.fill")
                    .font(.footnote)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Next Frame", comment: "Playback action"))

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Text(session.currentTime.framesTimecode)
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .accessibilityLabel(Text("Current time", comment: "Accessibility label"))
                    .accessibilityValue(session.currentTime.framesTimecode)

                Text(verbatim: "/")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(session.document.duration.framesTimecode)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Duration", comment: "Accessibility label"))
                    .accessibilityValue(session.document.duration.framesTimecode)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 2)
    }
}
