import AVFoundation
import SwiftUI
import UIKit

/// Shows an `AVPlayer` without rebuilding the player graph.
///
/// SwiftUI has no native surface that exposes an `AVPlayerLayer` directly, and
/// `VideoPlayer` brings its own transport controls that the editor replaces.
/// This is the one place UIKit is bridged for video.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        // Assigning the same player again would interrupt playback, so only
        // touch it when it has genuinely changed.
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
    }
}

/// A `UIView` whose backing layer is an `AVPlayerLayer`, so the layer resizes
/// with the view for free.
final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Safe by construction: `layerClass` guarantees the type.
        layer as! AVPlayerLayer
    }
}
