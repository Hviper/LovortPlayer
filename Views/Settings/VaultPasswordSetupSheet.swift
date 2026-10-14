#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI

struct VaultPasswordSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void = {}
    @State private var currentPIN = ""
    @State private var pin = ""
    @State private var confirm = ""
    @State private var saving = false
    @State private var errorText: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("保险箱密码") {
                    if VaultManager.shared.hasPassword, !VaultManager.shared.isUnlocked { SecureField("当前密码", text: $currentPIN) }
                    SecureField("6–12 位数字密码", text: $pin)
                    SecureField("再次输入新密码", text: $confirm)
                    Text("没有默认密码。切到后台或离开私密页面后会自动锁定。密码用于设备端验证，不会上传。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorText { Text(errorText).foregroundStyle(.red) }
                Button(saving ? "正在验证…" : "保存密码") {
                    saving = true
                    Task { @MainActor in
                    defer { saving = false }
                    do {
                        if VaultManager.shared.hasPassword, !VaultManager.shared.isUnlocked,
                           !VaultManager.shared.verifyPassword(currentPIN).success {
                            errorText = "当前密码不正确，或请等待 \(VaultManager.shared.retryAfter) 秒后重试"; return
                        }
                        guard pin == confirm else { errorText = "两次密码不一致"; return }
                        try await VaultManager.shared.setPassword(pin)
                        _ = VaultManager.shared.verifyPassword(pin)
                        onComplete()
                        dismiss()
                    } catch { errorText = error.localizedDescription }
                    }
                }.disabled(saving || pin.isEmpty || confirm.isEmpty)
            }
            .navigationTitle(VaultManager.shared.hasPassword ? "修改保险箱密码" : "设置保险箱密码")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
