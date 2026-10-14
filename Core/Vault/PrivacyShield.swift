#if os(iOS)
import UIKit

@MainActor
public final class PrivacyShield {
    public static let shared = PrivacyShield()
    private var windows: [String: UIWindow] = [:]
    private init() {}
    public func setVisible(_ visible: Bool) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let key = scene.session.persistentIdentifier
            if visible {
                let window = windows[key] ?? UIWindow(windowScene: scene)
                let controller = UIViewController()
                controller.view.backgroundColor = .black
                let label = UILabel()
                label.text = "LovortPlayer"
                label.textColor = .white
                label.textAlignment = .center
                label.translatesAutoresizingMaskIntoConstraints = false
                controller.view.addSubview(label)
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor), label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
                window.rootViewController = controller
                window.windowLevel = .alert + 1
                window.isHidden = false
                windows[key] = window
            } else { windows[key]?.isHidden = true; windows[key] = nil }
        }
    }
}
#endif
