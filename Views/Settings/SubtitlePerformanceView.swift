#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI

struct SubtitlePerformanceView: View {
    @State private var entries: [SubtitlePerformanceLog.Entry] = []
    var body: some View {
        List {
            Section {
                Text("记录本机实际耗时、并行数、计算配置和采样内存。用相同的短段预览比较不同模型及 1/2/4 并行；日志不含台词或 API 密钥。")
                    .font(.footnote)
                Button("刷新") { Task { entries = await SubtitlePerformanceLog.shared.snapshot() } }
                if let data = try? JSONEncoder().encode(entries), let text = String(data: data, encoding: .utf8) {
                    ShareLink("分享性能记录", item: text)
                }
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.stage)：\(String(format: "%.1f", entry.seconds)) 秒").font(.headline)
                    Text("\(entry.model) · 并行 \(entry.workers) · \(entry.backend)").font(.caption)
                    Text("热状态 \(entry.thermal) · 采样内存 \(entry.residentBytes / 1024 / 1024) MB").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("字幕性能记录")
        .task { entries = await SubtitlePerformanceLog.shared.snapshot() }
    }
}
