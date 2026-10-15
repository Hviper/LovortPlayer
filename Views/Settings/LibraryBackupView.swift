#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI
import UniformTypeIdentifiers

public struct LibraryBackupView: View {
    @ObservedObject private var vault = VaultManager.shared
    @State private var backupPassword = ""
    @State private var confirmation = ""
    @State private var vaultPIN = ""
    @State private var outputURL: URL?
    @State private var showImporter = false
    @State private var isWorking = false
    @State private var status = ""

    public init() {}

    public var body: some View {
        Form {
            Section("加密备份") {
                Text("备份包含本地视频、字幕、播放历史、播放列表、设置及保险箱密钥。API Key 和离线模型不会导出，恢复后需重新配置。")
                    .font(.footnote)
                SecureField("备份密码（至少 8 位）", text: $backupPassword)
                SecureField("再次输入备份密码", text: $confirmation)
                if vault.hasPassword && !vault.isUnlocked {
                    SecureField("保险箱密码", text: $vaultPIN)
                    Button("使用 Face ID / Touch ID 解锁保险箱") {
                        Task {
                            let result = await vault.authenticateWithBiometrics()
                            status = result.success ? "保险箱已解锁，可创建完整备份" : (result.error ?? "解锁失败")
                        }
                    }
                }
                Button("创建备份") { Task { await createBackup() } }
                    .disabled(isWorking)
                if let outputURL {
                    ShareLink(item: outputURL) {
                        Label("保存或分享备份文件", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("恢复") {
                Text("只支持在空媒体库中恢复。选择 .lovortbackup 文件并输入创建时的备份密码；完成后关闭并重新打开 App。")
                    .font(.footnote)
                Button("选择备份文件恢复") { showImporter = true }
                    .disabled(isWorking || backupPassword.isEmpty)
            }

            if isWorking || !status.isEmpty {
                Section("状态") {
                    if isWorking { ProgressView("正在处理大文件，请保持 App 在前台") }
                    Text(status).font(.footnote).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("备份与恢复")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url): Task { await restore(from: url) }
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func createBackup() async {
        guard backupPassword == confirmation else { status = "两次输入的备份密码不同"; return }
        if vault.hasPassword && !vault.isUnlocked {
            guard vault.verifyPassword(vaultPIN).success else { status = "请先解锁保险箱，确保私密视频可恢复"; return }
        }
        isWorking = true
        status = "正在打包并加密…"
        defer { isWorking = false }
        do {
            outputURL = try await LibraryBackupManager.shared.createBackup(password: backupPassword)
            status = "备份已创建。请点击上方按钮保存到“文件”或其他安全位置。"
            confirmation = ""
            vaultPIN = ""
        } catch { status = "备份失败：\(error.localizedDescription)" }
    }

    private func restore(from url: URL) async {
        isWorking = true
        status = "正在验证并恢复…"
        defer { isWorking = false }
        do {
            try await LibraryBackupManager.shared.restoreBackup(from: url, password: backupPassword)
            status = "恢复完成。请彻底关闭 App 后重新打开，视频、字幕和历史才会载入。"
            backupPassword = ""
            confirmation = ""
        } catch { status = "恢复失败：\(error.localizedDescription)" }
    }
}
