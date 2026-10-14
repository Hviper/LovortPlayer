import Foundation
#if os(iOS)
import UIKit
import Photos
#elseif os(macOS)
import AppKit
#endif

public enum VideoExportError: LocalizedError {
    case photoAccessDenied
    case unsupportedFormat(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .photoAccessDenied:
            return "未获得相册保存权限，请在 iPhone [设置] -> [隐私与安全性] -> [照片] 中允许 LovortPlayer 访问相册"
        case .unsupportedFormat(let format):
            return "系统相册不支持保存此视频编码/封装格式（\(format)），建议使用“存储到文件”或“系统分享”"
        case .failed(let reason):
            return "保存失败: \(reason)"
        }
    }
}

@MainActor
public final class VideoExportManager: NSObject {
    public static let shared = VideoExportManager()

    #if os(iOS)
    private var activePickerDelegate: DocumentExportDelegate?
    #endif

    private override init() {
        super.init()
    }

    // MARK: - 1. 保存到系统相册 (Photos Library)
    public func saveToPhotoLibrary(videoURL: URL) async throws {
        #if os(iOS)
        // 检查相册写入权限
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedStatus: PHAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolvedStatus = status
        }

        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            throw VideoExportError.photoAccessDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }
        } catch {
            let nsError = error as NSError
            // 某些特殊格式（如原始 AV1/MKV）系统相册底层拒绝导入
            if nsError.domain == "PHPhotosErrorDomain" || nsError.localizedDescription.contains("unsupported") {
                throw VideoExportError.unsupportedFormat(videoURL.pathExtension.uppercased())
            }
            throw VideoExportError.failed(error.localizedDescription)
        }
        #elseif os(macOS)
        throw VideoExportError.failed("macOS 请使用“存储到文件”导出视频")
        #endif
    }

    // MARK: - 2. 系统分享 (Share Sheet: AirDrop / 微信 / 信息 / 更多)
    public func shareVideo(url: URL, sourceView: UIView? = nil, sourceRect: CGRect? = nil, completion: (@MainActor @Sendable () -> Void)? = nil) {
        #if os(iOS)
        guard let topVC = UIApplication.topViewController else { completion?(); return }

        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        // 适配 iPad 弹出 Popover 防止 Crash
        if let popover = activityVC.popoverPresentationController {
            if let sourceView = sourceView {
                popover.sourceView = sourceView
                popover.sourceRect = sourceRect ?? sourceView.bounds
            } else {
                popover.sourceView = topVC.view
                let bounds = topVC.view.bounds
                popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }

        activityVC.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in completion?() }
        }
        topVC.present(activityVC, animated: true)
        #elseif os(macOS)
        if let view = NSApplication.shared.keyWindow?.contentView {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        #endif
    }

    // MARK: - 3. 存储到“文件” (Save to Files: iCloud Drive / 本地文件)
    public func saveToFiles(url: URL, sourceView: UIView? = nil, sourceRect: CGRect? = nil, completion: (@MainActor @Sendable () -> Void)? = nil) {
        #if os(iOS)
        guard let topVC = UIApplication.topViewController else { completion?(); return }

        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        let delegate = DocumentExportDelegate { [weak self] savedURL in
            if savedURL != nil {
                MediaLibraryManager.shared.showNotification(message: "已成功存储到“文件”")
            }
            self?.activePickerDelegate = nil
            completion?()
        }
        self.activePickerDelegate = delegate
        picker.delegate = delegate
        picker.modalPresentationStyle = .formSheet

        topVC.present(picker, animated: true)
        #elseif os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: url, to: dest)
                MediaLibraryManager.shared.showNotification(message: "已成功存储到：\(dest.lastPathComponent)")
            }
            completion?()
        }
        #endif
    }
}

#if os(iOS)
// MARK: - UIDocumentPickerDelegate 代理管理
@MainActor
private final class DocumentExportDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: (URL?) -> Void

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
        super.init()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }
}

// MARK: - 获取顶层 UIViewController
extension UIApplication {
    @MainActor
    public static var topViewController: UIViewController? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let rootVC = activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? activeScene?.windows.first?.rootViewController else {
            return nil
        }
        return getVisibleViewController(from: rootVC)
    }

    private static func getVisibleViewController(from vc: UIViewController) -> UIViewController {
        if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
            return getVisibleViewController(from: visible)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return getVisibleViewController(from: selected)
        }
        if let presented = vc.presentedViewController {
            return getVisibleViewController(from: presented)
        }
        return vc
    }
}
#endif
