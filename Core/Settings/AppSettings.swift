import Foundation
import SwiftUI
import Combine

// MARK: - 播放方向枚举
public enum PlaybackOrientation: String, CaseIterable, Codable {
    case auto         = "auto"          // 重力感应自动旋转
    case portrait     = "portrait"      // 锁定竖屏
    case landscape    = "landscape"     // 锁定横屏
    case landscapeLeft  = "landscapeLeft"  // 锁定横屏（左）
    case landscapeRight = "landscapeRight" // 锁定横屏（右）

    public var displayName: String {
        switch self {
        case .auto:           return "重力感应（自动）"
        case .portrait:       return "锁定竖屏"
        case .landscape:      return "锁定横屏"
        case .landscapeLeft:  return "锁定横屏（左）"
        case .landscapeRight: return "锁定横屏（右）"
        }
    }

    public var iconName: String {
        switch self {
        case .auto:           return "rotate.right"
        case .portrait:       return "iphone.portrait"
        case .landscape:      return "iphone.landscape"
        case .landscapeLeft:  return "iphone.landscape"
        case .landscapeRight: return "iphone.landscape"
        }
    }
}

// MARK: - 主题颜色枚举
public enum AppThemeColor: String, CaseIterable, Codable {
    case cyan    = "cyan"
    case blue    = "blue"
    case purple  = "purple"
    case orange  = "orange"
    case green   = "green"
    case pink    = "pink"
    case white   = "white"

    public var displayName: String {
        switch self {
        case .cyan:   return "青色（默认）"
        case .blue:   return "蓝色"
        case .purple: return "紫色"
        case .orange: return "橙色"
        case .green:  return "绿色"
        case .pink:   return "粉色"
        case .white:  return "纯白"
        }
    }

    public var color: Color {
        switch self {
        case .cyan:   return Color.cyan
        case .blue:   return Color.blue
        case .purple: return Color.purple
        case .orange: return Color.orange
        case .green:  return Color.green
        case .pink:   return Color.pink
        case .white:  return Color.white
        }
    }
}

// MARK: - AppSettings（全局设置，UserDefaults 持久化）
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: 通用
    /// 主题颜色
    @Published public var themeColor: AppThemeColor {
        didSet { defaults.set(themeColor.rawValue, forKey: "settings.themeColor") }
    }

    // MARK: 播放设置
    /// 播放方向
    @Published public var playbackOrientation: PlaybackOrientation {
        didSet { defaults.set(playbackOrientation.rawValue, forKey: "settings.playbackOrientation") }
    }

    /// 默认音量（0.0 ~ 1.0），-1 表示"跟随系统"
    @Published public var defaultVolume: Float {
        didSet { defaults.set(defaultVolume, forKey: "settings.defaultVolume") }
    }

    /// 是否使用默认音量（false = 跟随系统）
    @Published public var useDefaultVolume: Bool {
        didSet { defaults.set(useDefaultVolume, forKey: "settings.useDefaultVolume") }
    }

    // MARK: 私密文件夹
    /// 是否在 Tab 列表中显示私密文件夹 Tab
    @Published public var showVaultInTabBar: Bool {
        didSet { defaults.set(showVaultInTabBar, forKey: "settings.showVaultInTabBar") }
    }

    /// 是否需要 Face ID / Touch ID 验证才能进入保险箱
    @Published public var vaultRequiresBiometrics: Bool {
        didSet { defaults.set(vaultRequiresBiometrics, forKey: "settings.vaultRequiresBiometrics") }
    }

    // MARK: 缓存
    /// 缓存大小（字节），实时计算
    @Published public var cacheSizeBytes: Int64 = 0

    private init() {
        // 读取持久化值，没有则用默认值
        let rawTheme = defaults.string(forKey: "settings.themeColor") ?? AppThemeColor.cyan.rawValue
        themeColor = AppThemeColor(rawValue: rawTheme) ?? .cyan

        let rawOrientation = defaults.string(forKey: "settings.playbackOrientation") ?? PlaybackOrientation.auto.rawValue
        playbackOrientation = PlaybackOrientation(rawValue: rawOrientation) ?? .auto

        let savedVolume = defaults.object(forKey: "settings.defaultVolume") as? Float ?? 0.8
        defaultVolume = savedVolume

        let savedUseDefault = defaults.object(forKey: "settings.useDefaultVolume") as? Bool ?? false
        useDefaultVolume = savedUseDefault

        let savedShowVault = defaults.object(forKey: "settings.showVaultInTabBar") as? Bool ?? true
        showVaultInTabBar = savedShowVault

        let savedBio = defaults.object(forKey: "settings.vaultRequiresBiometrics") as? Bool ?? true
        vaultRequiresBiometrics = savedBio

        refreshCacheSize()
    }

    // MARK: - 缓存管理
    public func refreshCacheSize() {
        Task.detached(priority: .utility) {
            let size = Self.calculateCacheSize()
            await MainActor.run {
                self.cacheSizeBytes = size
            }
        }
    }

    private static func calculateCacheSize() -> Int64 {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let tempDir = fm.temporaryDirectory
        var total: Int64 = 0
        for dir in [cacheDir, Optional(tempDir)].compactMap({ $0 }) {
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    total += Int64(size)
                }
            }
        }
        return total
    }

    public func clearCache() async {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        let tempDir = fm.temporaryDirectory

        for dir in [cacheDir, Optional(tempDir)].compactMap({ $0 }) {
            if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in contents {
                    try? fm.removeItem(at: url)
                }
            }
        }
        await MainActor.run {
            cacheSizeBytes = 0
        }
    }

    // MARK: - 还原所有设置
    public func resetAllSettings() {
        themeColor = .cyan
        playbackOrientation = .auto
        defaultVolume = 0.8
        useDefaultVolume = false
        showVaultInTabBar = true
        vaultRequiresBiometrics = true
    }

    // MARK: - 格式化缓存大小
    public var formattedCacheSize: String {
        let mb = Double(cacheSizeBytes) / 1_048_576
        if mb < 1 {
            return "\(cacheSizeBytes / 1024) KB"
        } else if mb < 1024 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.2f GB", mb / 1024)
        }
    }
}
