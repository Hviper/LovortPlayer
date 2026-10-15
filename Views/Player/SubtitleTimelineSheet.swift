#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI

public struct SubtitleTimelineSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingLine: SubtitleLine?

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(viewModel.subtitles) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            viewModel.seek(to: line.startTime)
                            viewModel.isAISubtitleEnabled = true
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(formatTime(line.startTime))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.cyan)
                                    .frame(width: 48, alignment: .leading)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(line.originalText)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                    if let translated = line.translatedText, !translated.isEmpty {
                                        Text(translated)
                                            .font(.system(size: 13))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if viewModel.currentSubtitle?.id == line.id {
                                    Image(systemName: "waveform").foregroundColor(.cyan)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { editingLine = line } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("编辑这条字幕")
                    }
                    .id(line.id)
                }
                .onAppear { scrollToCurrent(using: proxy) }
                .onChange(of: viewModel.currentSubtitle?.id) { _ in scrollToCurrent(using: proxy) }
            }
            .navigationTitle("字幕时间轴")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay {
                if viewModel.subtitles.isEmpty {
                    ContentUnavailableView("暂无字幕", systemImage: "captions.bubble", description: Text("请先生成或导入字幕"))
                }
            }
            .sheet(item: $editingLine) { line in
                SubtitleLineEditor(line: line, duration: viewModel.duration) { original, translated, start, end in
                    try await viewModel.editSubtitle(line.id, originalText: original,
                        translatedText: translated, startTime: start, endTime: end)
                }
            }
        }
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy) {
        guard let id = viewModel.currentSubtitle?.id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct SubtitleLineEditor: View {
    let line: SubtitleLine
    let duration: TimeInterval
    let onSave: (String, String?, TimeInterval, TimeInterval) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: String
    @State private var translation: String
    @State private var start: Double
    @State private var end: Double
    @State private var errorText: String?
    @State private var saving = false

    init(line: SubtitleLine, duration: TimeInterval,
         onSave: @escaping (String, String?, TimeInterval, TimeInterval) async throws -> Void) {
        self.line = line
        self.duration = duration
        self.onSave = onSave
        _original = State(initialValue: line.originalText)
        _translation = State(initialValue: line.translatedText ?? "")
        _start = State(initialValue: line.startTime)
        _end = State(initialValue: line.endTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("字幕内容") {
                    TextField("原文", text: $original, axis: .vertical).lineLimit(2...6)
                    TextField("译文（可留空）", text: $translation, axis: .vertical).lineLimit(2...6)
                }
                Section("时间轴") {
                    Stepper("开始：\(String(format: "%.2f", start)) 秒", value: $start,
                            in: 0...max(duration, end + 1), step: 0.1)
                    Stepper("结束：\(String(format: "%.2f", end)) 秒", value: $end,
                            in: 0...max(duration, end + 1), step: 0.1)
                }
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
            .navigationTitle("编辑字幕")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saving = true
                        Task {
                            do {
                                try await onSave(original, translation.isEmpty ? nil : translation, start, end)
                                dismiss()
                            } catch { errorText = error.localizedDescription }
                            saving = false
                        }
                    }
                    .disabled(saving || end <= start || original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
