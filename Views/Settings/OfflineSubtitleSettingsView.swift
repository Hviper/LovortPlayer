#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

public struct OfflineSubtitleSettingsView: View {
    @ObservedObject private var models = OfflineWhisperModelManager.shared
    @State private var selectedModel = AISubtitleCoordinator.shared.offlineModel
    @AppStorage("settings.subtitleCompletionNotifications") private var notificationsEnabled = false
    @State private var modelToDelete: OfflineWhisperModel?
    @State private var notificationMessage: String?
    @State private var isImportingModel = false
    @State private var transferringModel: OfflineWhisperModel?
    @State private var isInstallingArchive = false
    @State private var exportedArchives: [OfflineWhisperModel: URL] = [:]

    public init() {}

    public var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NavigationLink {
                        LANMacSubtitleSettingsView()
                    } label: {
                        Label("局域网 Mac 字幕服务", systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("提前安装模型后，即使没有网络，也可以为视频生成原文字幕。模型下载可在离开本页面后继续。")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.65))
                        Text("模型文件保存在 App 专用目录，删除模型不会删除已经生成的字幕。")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            isImportingModel = true
                        } label: {
                            Label("从文件导入离线模型", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInstallingArchive)
                        Text("可从另一台设备分享模型 ZIP 包并导入，无需重新下载。导入时请预留约两倍模型大小的空间。")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                        if isInstallingArchive {
                            ProgressView("正在校验并安装模型…")
                                .tint(AppSettings.shared.themeColor.color)
                        }
                        if let notificationMessage {
                            Text(notificationMessage)
                                .font(.system(size: 11))
                                .foregroundColor(.orange.opacity(0.9))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.055)))

                    ForEach(OfflineWhisperModel.allCases) { model in
                        modelCard(model)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("字幕完成后发送系统通知", isOn: $notificationsEnabled)
                            .tint(AppSettings.shared.themeColor.color)
                            .foregroundColor(.white)
                            .onChange(of: notificationsEnabled) { enabled in
                                if enabled { requestNotificationPermission() }
                            }
                        Text("App 内完成提示始终开启。系统通知需要用户授权，仅在任务实际完成时发送。")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.055)))
                }
                .padding(16)
            }
        }
        .navigationTitle("离线字幕与模型")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { models.refreshInstalledState() }
        .fileImporter(isPresented: $isImportingModel, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                isInstallingArchive = true
                Task {
                    defer { isInstallingArchive = false }
                    do {
                        let model = try await models.importArchive(from: url)
                        notificationMessage = "已导入 \(model.displayName)，可以离线使用"
                    } catch {
                        notificationMessage = "模型导入失败：\(error.localizedDescription)"
                    }
                }
            case .failure(let error):
                notificationMessage = "无法打开模型文件：\(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            "删除离线模型？",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除模型", role: .destructive) {
                if let modelToDelete {
                    do {
                        try models.delete(modelToDelete)
                    } catch {
                        notificationMessage = error.localizedDescription
                    }
                }
                modelToDelete = nil
            }
            Button("取消", role: .cancel) { modelToDelete = nil }
        } message: {
            Text("将释放该模型占用的空间，已生成字幕不会受到影响。")
        }
    }

    private func modelCard(_ model: OfflineWhisperModel) -> some View {
        let record = models.record(for: model)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(model.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        if selectedModel == model {
                            Text("默认")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(AppSettings.shared.themeColor.color))
                        }
                    }
                    Text(model.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.48))
                }
                Spacer()
                statusLabel(record.state)
            }

            if record.state == .downloading {
                VStack(spacing: 5) {
                    ProgressView(value: record.progress)
                        .tint(AppSettings.shared.themeColor.color)
                    HStack {
                        Text(record.progress >= 0.999
                             ? "正在校验并安装模型…"
                             : "正在下载 \(Int(record.progress * 100))%")
                        Spacer()
                        Text("约 \(formattedBytes(record.completedBytes)) / \(formattedBytes(record.totalBytes))")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                }
            }

            if let error = record.errorMessage, record.state == .failed {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.orange.opacity(0.9))
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                if record.state == .installed {
                    if selectedModel != model {
                        Button("设为默认") {
                            selectedModel = model
                            AISubtitleCoordinator.shared.offlineModel = model
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("删除", role: .destructive) { modelToDelete = model }
                        .buttonStyle(.bordered)
                    if let archiveURL = exportedArchives[model] {
                        ShareLink(item: archiveURL) {
                            Label("分享模型", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            transferringModel = model
                            Task {
                                defer { transferringModel = nil }
                                do {
                                    exportedArchives[model] = try await models.exportArchive(for: model)
                                    notificationMessage = "模型包已准备好，点击“分享模型”保存或发送"
                                } catch {
                                    notificationMessage = "模型打包失败：\(error.localizedDescription)"
                                }
                            }
                        } label: {
                            if transferringModel == model {
                                ProgressView()
                            } else {
                                Label("准备分享", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(transferringModel != nil)
                    }
                } else if record.state != .downloading {
                    Button(record.state == .failed ? "重试下载" : "预先下载") {
                        models.beginDownload(model)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Text(record.state == .installed && record.completedBytes > 0
                     ? "占用 \(formattedBytes(record.completedBytes))"
                     : "预计 \(formattedBytes(model.estimatedSizeBytes))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.38))
            }
            .tint(AppSettings.shared.themeColor.color)
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func statusLabel(_ state: OfflineModelInstallState) -> some View {
        let value: (String, Color) = {
            switch state {
            case .notInstalled: return ("未安装", .white.opacity(0.45))
            case .downloading: return ("下载中", .cyan)
            case .installed: return ("已安装", .green)
            case .failed: return ("下载失败", .orange)
            }
        }()
        return Text(value.0)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(value.1)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "计算中" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if !granted {
                    notificationsEnabled = false
                    notificationMessage = error?.localizedDescription ?? "通知权限未开启，可稍后在系统设置中允许。"
                } else {
                    notificationMessage = nil
                }
            }
        }
    }
}
