import SwiftUI

public struct SubtitleTimelineSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(viewModel.subtitles) { line in
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
                                Image(systemName: "waveform")
                                    .foregroundColor(.cyan)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
