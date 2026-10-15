#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import AVKit

#if os(iOS)
import MediaPlayer

@MainActor
public final class PictureInPictureState: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published public private(set) var isAvailable = false
    @Published public private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private weak var attachedLayer: AVPlayerLayer?

    public func attach(to layer: AVPlayerLayer) {
        guard attachedLayer !== layer else { return }
        controller?.delegate = nil
        controller = nil
        attachedLayer = layer
        isAvailable = AVPictureInPictureController.isPictureInPictureSupported()
        guard isAvailable else { return }
        let pip = AVPictureInPictureController(playerLayer: layer)
        pip?.delegate = self
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
        controller = pip
    }

    public func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        else if controller.isPictureInPicturePossible { controller.startPictureInPicture() }
    }

    public func detach(from layer: AVPlayerLayer) {
        guard attachedLayer === layer else { return }
        controller?.delegate = nil
        controller = nil
        attachedLayer = nil
        isActive = false
        isAvailable = false
    }

    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
    }
}

public struct AirPlayRoutePicker: UIViewRepresentable {
    public init() {}
    public func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .cyan
        view.prioritizesVideoDevices = true
        return view
    }
    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

public struct NativeVideoPlayerView: UIViewRepresentable {
    public let player: AVPlayer?
    public let pictureInPicture: PictureInPictureState?

    public init(player: AVPlayer?, pictureInPicture: PictureInPictureState? = nil) {
        self.player = player
        self.pictureInPicture = pictureInPicture
    }

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        pictureInPicture?.attach(to: view.playerLayer)
        return view
    }

    public func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
        pictureInPicture?.attach(to: uiView.playerLayer)
    }

    public static func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) {
        uiView.player = nil
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
