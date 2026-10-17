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
        let destination = isPrivate ? privateURL(for: videoURL, ext: ext) : publicURL(for: videoURL, ext: ext)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        #endif
        for other in ["json", "srt", "ass"] where other != ext {
            let otherURL = isPrivate ? privateURL(for: videoURL, ext: other) : publicURL(for: videoURL, ext: other)
            try? fm.removeItem(at: otherURL)
            if isPrivate {
                try? fm.removeItem(at: otherURL.appendingPathExtension("vault"))
            }
        }
        if isPrivate {
            try? fm.removeItem(at: destination.appendingPathExtension("vault"))
        }
    }

    public func load(for videoURL: URL, isPrivate: Bool) async -> [SubtitleLine]? {
        for ext in ["json", "srt", "ass"] {
            let targetURL = isPrivate ? privateURL(for: videoURL, ext: ext) : publicURL(for: videoURL, ext: ext)
            var fileURLToRead: URL?
            if FileManager.default.fileExists(atPath: targetURL.path) {
                fileURLToRead = targetURL
            } else if isPrivate {
                let legacyVault = targetURL.appendingPathExtension("vault")
                if FileManager.default.fileExists(atPath: legacyVault.path) {
                    fileURLToRead = legacyVault
                }
            }
            guard let url = fileURLToRead else { continue }
            let isLegacyVault = isPrivate && url.pathExtension.lowercased() == "vault"
            let readable: URL
            if isLegacyVault {
                guard let unlocked = try? await VaultManager.shared.readableURL(for: url) else { continue }
                readable = unlocked
            } else {
                readable = url
            }
            defer { if isLegacyVault { VaultManager.shared.releaseReadableURL(readable) } }
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
            .appendingPathComponent("\(name).external.\(ext)")
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "ExternalSubtitle", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
