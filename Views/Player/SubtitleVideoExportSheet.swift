import SwiftUI

/// Export is explicit: generating subtitles and sharing the original video do not change the source file.
struct SubtitleVideoExportSheet: View {
    let videoURL: URL
    let videoTitle: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subtitleTasks = SubtitleTaskManager.shared
    @State private var mode: SubtitleVideoExportMode = .burnedIn
    @State private var textMode: SubtitleExportTextMode = .bilingual
    @State private var progress: Double = 0
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var outputURL: URL?
    @State private var errorText: String?
    @State private var savedToPhotos = false
    @State private var savingToPhotos = false

    private var lines: [SubtitleLine] { subtitleTasks.subtitles(for: videoURL) ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(videoTitle).font(.headline)
                    Text("生成新的 MP4，原视频会保留。译文缺失时使用原文。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if subtitleTasks.task(for: videoURL)?.phase.isActive == true {
                        Text("字幕仍在生成，导出只包含点击时已完成的字幕。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("导出模式") {
                    Picker("模式", selection: $mode) {
                        ForEach(SubtitleVideoExportMode.allCases) { item in Text(item.title).tag(item) }
                    }
                    Text(mode.detail).font(.footnote).foregroundStyle(.secondary)
                    Picker("字幕内容", selection: $textMode) {
                        ForEach(SubtitleExportTextMode.allCases) { item in Text(item.title).tag(item) }
                    }
                }.disabled(exporting || savingToPhotos)
                Section {
                    if exporting {
                        ProgressView(value: progress)
                        Text("正在导出 \(Int(progress * 100))% · 请保持应用在前台")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("取消导出", role: .destructive) { cancelExport() }
                    } else {
                        Text("可用字幕：\(lines.count) 段").font(.footnote).foregroundStyle(.secondary)
                        Button(outputURL == nil ? "开始导出" : "重新导出") { startExport() }
                            .disabled(lines.isEmpty || savingToPhotos)
                    }
                    if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }
                if let outputURL {
                    Section("导出完成") {
                        Button { share(outputURL, toFiles: false) } label: {
                            Label("分享字幕视频", systemImage: "square.and.arrow.up")
                        }
                        Button { share(outputURL, toFiles: true) } label: {
                            Label("存储到“文件”", systemImage: "folder.badge.plus")
                        }
                        // Photos and messaging apps may strip soft subtitles when transcoding.
                        if mode == .burnedIn {
                            Button { saveToPhotos(outputURL) } label: {
                                Label(savingToPhotos ? "正在保存…" : savedToPhotos ? "已保存到相册" : "保存到系统相册", systemImage: "photo.badge.arrow.down")
                            }.disabled(savingToPhotos || savedToPhotos)
                        } else {
                            Text("内嵌字幕建议通过“文件”或 AirDrop 分享原文件；接收方播放器及转码可能影响字幕显示。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.disabled(exporting)
                }
            }
            .navigationTitle("导出带字幕视频")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .interactiveDismissDisabled(exporting || savingToPhotos)
            .onDisappear { cancelExport(); discardOutput() }
            .onChange(of: mode) { _, _ in discardOutput(); savedToPhotos = false }
            .onChange(of: textMode) { _, _ in discardOutput(); savedToPhotos = false }
        }
    }

    private func startExport() {
        let snapshot = lines
        let id = UUID()
        requestID = id
        progress = 0
        errorText = nil
        discardOutput()
        savedToPhotos = false
        exporting = true
        exportTask = Task { @MainActor in
            do {
                let url = try await SubtitleVideoExporter.shared.export(videoURL: videoURL, lines: snapshot, mode: mode, textMode: textMode) { value in
                    if requestID == id { progress = value }
                }
                guard requestID == id, !Task.isCancelled else { SubtitleVideoExporter.shared.retire(url); return }
                outputURL = url
            } catch is CancellationError {
                // User cancellation is not an export failure.
            } catch {
                if requestID == id { errorText = error.localizedDescription }
            }
            if requestID == id { exporting = false; exportTask = nil }
        }
    }

    private func cancelExport() {
        requestID = UUID()
        exportTask?.cancel()
        exportTask = nil
        exporting = false
    }

    private func discardOutput() {
        if let outputURL { SubtitleVideoExporter.shared.retire(outputURL) }
        outputURL = nil
    }

    private func share(_ url: URL, toFiles: Bool) {
        SubtitleVideoExporter.shared.retain(url)
        let completion: @MainActor @Sendable () -> Void = { SubtitleVideoExporter.shared.release(url) }
        if toFiles { VideoExportManager.shared.saveToFiles(url: url, completion: completion) }
        else { VideoExportManager.shared.shareVideo(url: url, completion: completion) }
    }

    private func saveToPhotos(_ url: URL) {
        savingToPhotos = true
        SubtitleVideoExporter.shared.retain(url)
        Task { @MainActor in
            defer { savingToPhotos = false; SubtitleVideoExporter.shared.release(url) }
            do { try await VideoExportManager.shared.saveToPhotoLibrary(videoURL: url); savedToPhotos = true }
            catch { errorText = error.localizedDescription }
        }
    }
}
