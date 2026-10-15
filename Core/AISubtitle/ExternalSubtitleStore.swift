import Foundation

@MainActor
public final class ExternalSubtitleStore {
    public static let shared = ExternalSubtitleStore()
    private init() {}

    public func importSubtitle(from source: URL, for videoURL: URL, isPrivate: Bool) async throws -> [SubtitleLine] {
        let ext = source.pathExtension.lowercased()
        guard ["srt", "ass"].contains(ext) else { throw error("请选择 SRT 或 ASS 字幕文件") }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 8 * 1024 * 1024 else { throw error("字幕文件需小于 8 MB") }
        let data = try Data(contentsOf: source)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw error("字幕编码无法读取，请使用 UTF-8 或 UTF-16")
        }
        let lines = Self.parse(text, ext: ext)
        guard !lines.isEmpty else { throw error("未找到有效的字幕时间轴") }

        try await persist(data, ext: ext, for: videoURL, isPrivate: isPrivate)
        return lines
    }

    public func saveEdited(_ lines: [SubtitleLine], for videoURL: URL, isPrivate: Bool) async throws {
        guard !lines.isEmpty,
              lines.allSatisfy({ $0.endTime > $0.startTime && $0.startTime >= 0 && !$0.originalText.isEmpty }) else {
            throw error("字幕时间或内容无效")
        }
        try await persist(JSONEncoder().encode(lines), ext: "json", for: videoURL, isPrivate: isPrivate)
    }

    private func persist(_ data: Data, ext: String, for videoURL: URL, isPrivate: Bool) async throws {
        let fm = FileManager.default
        if isPrivate {
            let destination = privateURL(for: videoURL, ext: ext)
            let stage = fm.temporaryDirectory.appendingPathComponent("ExternalSubtitle-\(UUID().uuidString).\(ext)")
            let encrypted = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).vault")
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage); try? fm.removeItem(at: encrypted) }
            try data.write(to: stage, options: .atomic)
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: stage.path)
            #endif
            try await VaultManager.shared.encryptFile(at: stage, destinationURL: encrypted)
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: encrypted) }
            else { try fm.moveItem(at: encrypted, to: destination) }
            for other in ["json", "srt", "ass"] where other != ext { try? fm.removeItem(at: privateURL(for: videoURL, ext: other)) }
        } else {
            let destination = publicURL(for: videoURL, ext: ext)
            try data.write(to: destination, options: .atomic)
            #if os(iOS)
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            #endif
            for other in ["json", "srt", "ass"] where other != ext { try? fm.removeItem(at: publicURL(for: videoURL, ext: other)) }
        }
    }

    public func load(for videoURL: URL, isPrivate: Bool) async -> [SubtitleLine]? {
        for ext in ["json", "srt", "ass"] {
            let url = isPrivate ? privateURL(for: videoURL, ext: ext) : publicURL(for: videoURL, ext: ext)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let readable: URL
            if isPrivate {
                guard let unlocked = try? await VaultManager.shared.readableURL(for: url) else { continue }
                readable = unlocked
            } else { readable = url }
            defer { if isPrivate { VaultManager.shared.releaseReadableURL(readable) } }
            guard let data = try? Data(contentsOf: readable) else { continue }
            let lines: [SubtitleLine]
            if ext == "json" { lines = (try? JSONDecoder().decode([SubtitleLine].self, from: data)) ?? [] }
            else if let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                lines = Self.parse(content, ext: ext)
            } else { continue }
            if !lines.isEmpty { return lines }
        }
        return nil
    }

    private static func parse(_ content: String, ext: String) -> [SubtitleLine] {
        ext == "ass" ? ASSParser.parse(content) : SRTParser.parse(srtString: content)
    }

    private func publicURL(for videoURL: URL, ext: String) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("external.\(ext)")
    }

    private func privateURL(for videoURL: URL, ext: String) -> URL {
        let identity = MediaIdentityStore.shared.id(for: videoURL)
        let name = videoURL.deletingPathExtension().deletingPathExtension().lastPathComponent
        return MediaLibraryManager.shared.vaultDirectory
            .appendingPathComponent(".Subtitles", isDirectory: true)
            .appendingPathComponent(identity.uuidString, isDirectory: true)
            .appendingPathComponent("\(name).external.\(ext).vault")
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "ExternalSubtitle", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
