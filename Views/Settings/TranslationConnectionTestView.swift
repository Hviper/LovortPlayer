import SwiftUI
#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif

public struct TranslationConnectionTestView: View {
    let configuration: TranslationConnectionConfiguration
    @State private var task: Task<Void, Never>?
    @State private var message = ""
    @State private var succeeded = false
    @State private var requestID: UUID?

    public init(configuration: TranslationConnectionConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    startTest()
                } label: {
                    HStack(spacing: 6) {
                        if task != nil { ProgressView() }
                        Text(task == nil ? "测试连接" : "正在测试…")
                    }
                }
                .disabled(task != nil)
                if task != nil {
                    Button("取消") { reset() }
                }
            }
            Text("使用当前输入配置翻译一条测试短句，可能产生少量 API 费用；测试不会保存或切换翻译服务。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(.footnote)
                    .foregroundStyle(succeeded ? Color.green : Color.orange)
                    .textSelection(.enabled)
            }
        }
        .onChange(of: configuration) { _, _ in reset() }
        .onDisappear { reset() }
    }

    private func reset() {
        requestID = nil
        task?.cancel()
        task = nil
        message = ""
        succeeded = false
    }

    private func startTest() {
        reset()
        let snapshot = configuration
        let id = UUID()
        requestID = id
        task = Task { @MainActor in
            let start = Date()
            do {
                _ = try await TranslationConnectionTester.test(snapshot)
                guard !Task.isCancelled, requestID == id else { return }
                succeeded = true
                let model = snapshot.settings.provider == .openAI ? snapshot.openAIModel : snapshot.settings.model
                message = "连接成功，已收到有效翻译（\(String(format: "%.1f", Date().timeIntervalSince(start))) 秒）" + (model.isEmpty ? "" : "\n模型：\(model)")
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                succeeded = false
                message = TranslationConnectionTester.errorMessage(error)
            }
            task = nil
        }
    }
}
