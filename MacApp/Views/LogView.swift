import SwiftUI
import AppKit

public struct LogView: View {
    @ObservedObject var logStore: LogStore

    @State private var filterQuery: String = ""
    @State private var autoScroll: Bool = true
    @State private var hasCopiedAll: Bool = false

    public init(logStore: LogStore) {
        self.logStore = logStore
    }

    private var filteredEntries: [LogEntry] {
        let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return logStore.entries }
        return logStore.entries.filter {
            $0.message.localizedCaseInsensitiveContains(query) ||
            $0.timestampText.contains(query)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Log Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("运行日志")
                        .font(.headline)
                    Text("\(logStore.entries.count) / \(logStore.maxCapacity)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                // Filter search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("过滤日志...", text: $filterQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 140)
                    if !filterQuery.isEmpty {
                        Button {
                            filterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )

                Toggle(isOn: $autoScroll) {
                    Label("自动滚动", systemImage: "arrow.down.to.line")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Button {
                    copyAllLogs()
                } label: {
                    Label(hasCopiedAll ? "已复制" : "复制全部", systemImage: hasCopiedAll ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(logStore.entries.isEmpty)

                Button {
                    logStore.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(logStore.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Console output area
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(logStore.entries.isEmpty ? "暂无日志输出" : "无匹配过滤结果")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredEntries) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("[\(entry.timestampText)]")
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.8))

                                    Text(entry.message)
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(entry.isError ? .red : .primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    .onChange(of: logStore.entries.count) { _, _ in
                        if autoScroll, let last = filteredEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func copyAllLogs() {
        let text = logStore.exportPlainText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation {
            hasCopiedAll = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation {
                    hasCopiedAll = false
                }
            }
        }
    }
}
