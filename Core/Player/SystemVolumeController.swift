import SwiftUI
#if os(iOS)
import MediaPlayer
#endif

@MainActor
public final class SystemVolumeController: ObservableObject {
    public static let shared = SystemVolumeController()

    #if os(iOS)
    private var volumeSlider: UISlider?
    private let volumeView = MPVolumeView(frame: .zero)
    #endif

    private init() {
        #if os(iOS)
        // 查找 MPVolumeView 内置的 UISlider
        volumeView.clipsToBounds = true
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                self.volumeSlider = slider
                break
            }
        }
        #endif
    }

    /// 获取当前系统音量 (0.0 ~ 1.0)
    public func getCurrentVolume() -> Float {
        #if os(iOS)
        if let slider = volumeSlider {
            return slider.value
        }
        return AVAudioSession.sharedInstance().outputVolume
        #else
        return 0.5
        #endif
    }

    /// 真正修改 iOS 系统硬件音量
    public func setVolume(_ volume: Float) {
        #if os(iOS)
        let clamped = max(0.0, min(1.0, volume))
        if let slider = volumeSlider {
            DispatchQueue.main.async {
                slider.setValue(clamped, animated: false)
                slider.sendActions(for: .touchUpInside)
            }
        }
        #endif
    }
}
