import SwiftUI
import AVKit

#if os(iOS)
public struct NativeVideoPlayerView: UIViewRepresentable {
    public let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    public func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
    }

    public class PlayerUIView: UIView {
        public override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        public var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        public var player: AVPlayer? {
            get { playerLayer.player }
            set {
                playerLayer.player = newValue
                playerLayer.videoGravity = .resizeAspect
            }
        }
    }
}
#elseif os(macOS)
public struct NativeVideoPlayerView: NSViewRepresentable {
    public let player: AVPlayer?

    public init(player: AVPlayer?) {
        self.player = player
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
#endif
