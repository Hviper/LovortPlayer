import SwiftUI
#if os(iOS)
import MediaPlayer
import AVFoundation
import UIKit
#endif

@MainActor
public final class SystemVolumeController: ObservableObject {
    public static let shared = SystemVolumeController()

    #if os(iOS)
    private var volumeSlider: UISlider?
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    #endif

    private init() {
        #if os(iOS)
        setupVolumeView()
        #endif
    }

    #if os(iOS)
    private func setupVolumeView() {
        volumeView.clipsToBounds = true
        volumeView.isHidden = false
        volumeView.alpha = 0.001
        findSlider()
    }

    @discardableResult
    private func findSlider() -> UISlider? {
        if let slider = volumeSlider { return slider }
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                self.volumeSlider = slider
                return slider
            }
        }
        // 若尚未挂载到 window，尝试挂载到当前活动 keyWindow
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }),
           let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
            if volumeView.superview == nil {
                window.addSubview(volumeView)
            }
            volumeView.layoutIfNeeded()
            for subview in volumeView.subviews {
                if let slider = subview as? UISlider {
                    self.volumeSlider = slider
                    return slider
                }
            }
        }
        return nil
    }
    #endif

    /// 获取当前系统音量 (0.0 ~ 1.0)
    public func getCurrentVolume() -> Float {
        #if os(iOS)
        if let slider = findSlider() {
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
        if let slider = findSlider() {
            DispatchQueue.main.async {
                slider.setValue(clamped, animated: false)
                slider.sendActions(for: .touchUpInside)
            }
        }
        #endif
    }
}
