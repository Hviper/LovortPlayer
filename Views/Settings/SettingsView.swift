import SwiftUI

/// 完整的 Lovort 设置页面
public struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var isClearingCache = false
    @State private var showClearCacheDone = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // 通用 - 主题颜色
                        settingsSection(title: "通用", icon: "paintpalette") {
                            themeColorPicker
                        }

                        // 播放设置
                        settingsSection(title: "播放设置", icon: "play.rectangle") {
                            orientationPicker
                            divider
                            defaultVolumeRow
                        }

                        // 私密文件夹
                        settingsSection(title: "私密文件夹", icon: "lock.shield") {
                            vaultShowToggle
                            divider
                            vaultBiometricsToggle
                        }

                        // 存储与缓存
                        settingsSection(title: "存储与缓存", icon: "internaldrive") {
                            cacheRow
                        }

                        // 还原设置
                        settingsSection(title: "重置", icon: "arrow.counterclockwise") {
                            resetRow
                        }

                        // 版本信息
                        versionInfo

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("设置")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(settings.themeColor.color)
                        .fontWeight(.semibold)
                }
            }
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.05), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear { settings.refreshCacheSize() }
        .confirmationDialog("确认清除缓存？", isPresented: $showClearCacheConfirm, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) {
                isClearingCache = true
                Task {
                    await settings.clearCache()
                    isClearingCache = false
                    showClearCacheDone = true
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    showClearCacheDone = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将清除所有临时缓存文件，不影响已导入视频。")
        }
        .confirmationDialog("还原所有设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("还原默认设置", role: .destructive) {
                withAnimation { settings.resetAllSettings() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把所有设置恢复为出厂默认值，不影响已导入视频和保险箱密码。")
        }
    }

    // MARK: - Section 容器
    private func settingsSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 组标题
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(settings.themeColor.color.opacity(0.85))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.1, green: 0.11, blue: 0.13))
            )
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }

    // MARK: - 主题颜色选择器
    private var themeColorPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundColor(settings.themeColor.color)
                    .font(.system(size: 14))
                Text("主题颜色")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
                Text(settings.themeColor.displayName)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // 颜色球选择行
            HStack(spacing: 14) {
                ForEach(AppThemeColor.allCases, id: \.rawValue) { theme in
                    Button(action: {
                        withAnimation(.spring(response: 0.3)) {
                            settings.themeColor = theme
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 30, height: 30)
                            if settings.themeColor == theme {
                                Circle()
                                    .stroke(Color.white, lineWidth: 2.5)
                                    .frame(width: 36, height: 36)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    // MARK: - 播放方向
    private var orientationPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: settings.playbackOrientation.iconName)
                    .foregroundColor(settings.themeColor.color)
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text("播放方向")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            ForEach(PlaybackOrientation.allCases, id: \.rawValue) { orientation in
                Button(action: {
                    withAnimation { settings.playbackOrientation = orientation }
                }) {
                    HStack {
                        Text(orientation.displayName)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if settings.playbackOrientation == orientation {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(settings.themeColor.color)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        settings.playbackOrientation == orientation
                            ? settings.themeColor.color.opacity(0.08)
                            : Color.clear
                    )
                }
                .buttonStyle(.plain)

                if orientation != PlaybackOrientation.allCases.last {
                    divider
                }
            }
        }
    }

    // MARK: - 默认音量
    private var defaultVolumeRow: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "speaker.wave.2")
                    .foregroundColor(settings.themeColor.color)
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text("默认音量")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $settings.useDefaultVolume)
                    .tint(settings.themeColor.color)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if settings.useDefaultVolume {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "speaker")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                        Slider(value: $settings.defaultVolume, in: 0...1, step: 0.05)
                            .tint(settings.themeColor.color)
                        Image(systemName: "speaker.wave.3")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 16)

                    Text("打开视频时音量：\(Int(settings.defaultVolume * 100))%")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.bottom, 12)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.useDefaultVolume)
    }

    // MARK: - 私密保险箱 Tab 开关
    private var vaultShowToggle: some View {
        HStack {
            Image(systemName: "eye")
                .foregroundColor(settings.themeColor.color)
                .font(.system(size: 14))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("在列表显示")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Text("在主页 Tab 栏中显示「私密文件夹」入口")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $settings.showVaultInTabBar)
                .tint(settings.themeColor.color)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 面容 ID 验证开关
    private var vaultBiometricsToggle: some View {
        HStack {
            Image(systemName: "faceid")
                .foregroundColor(settings.themeColor.color)
                .font(.system(size: 14))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("面容 ID 验证")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Text("进入私密文件夹时需要 Face ID / Touch ID 验证")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $settings.vaultRequiresBiometrics)
                .tint(settings.themeColor.color)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 缓存行
    private var cacheRow: some View {
        Button(action: { showClearCacheConfirm = true }) {
            HStack {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.85))
                    .font(.system(size: 14))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("清除缓存")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                    if isClearingCache {
                        Text("正在清除...")
                            .font(.system(size: 12))
                            .foregroundColor(.orange.opacity(0.8))
                    } else if showClearCacheDone {
                        Text("清除完成 ✓")
                            .font(.system(size: 12))
                            .foregroundColor(.green.opacity(0.8))
                    } else {
                        Text("当前缓存：\(settings.formattedCacheSize)")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                Spacer()
                if isClearingCache {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 还原所有设置
    private var resetRow: some View {
        Button(action: { showResetConfirm = true }) {
            HStack {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundColor(.orange.opacity(0.85))
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text("还原所有设置")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 版本信息
    private var versionInfo: some View {
        VStack(spacing: 4) {
            Text("LovortPlayer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
            Text("v1.0 · Lovort 沉浸黑灰 · AV1 软解引擎")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}
