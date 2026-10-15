import AVFoundation
import Foundation
import Security

public enum LANMacSubtitleSettings {
    private static let addressKey = "LovortLANMacSubtitleAddress"
    private static let keychainService = "com.hviper.lovortplayer.lan-mac-subtitles"

    public static var address: String {
        get { UserDefaults.standard.string(forKey: addressKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: addressKey) }
    }

    public static var accessToken: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: "access-token",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: "access-token"
            ]
            SecItemDelete(query as CFDictionary)
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var item = query
            item[kSecValueData as String] = Data(trimmed.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    public static func baseURL() throws -> URL {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = raw.contains("://") ? raw : "http://\(raw)"
        guard let components = URLComponents(string: value), components.scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              isLocalHost(host), let url = components.url else {
            throw error("请输入 Mac 的局域网地址，例如 192.168.1.20:8765")
        }
        return url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 127)
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "LANMacSubtitle", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public actor LANMacSubtitleService {
    public static let modelIdentifier = "mlx-whisper-large-v3-turbo"
    private let exporter = LocalWhisperSubtitleService()

    private struct Health: Decodable {
        let service: String
        let model: String
    }

    private struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    private struct Transcription: Decodable {
        let segments: [Segment]
    }

    public init() {}

    public func testConnection() async throws -> String {
        let (baseURL, token) = try configuration()
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.setValue(token, forHTTPHeaderField: "X-Lovort-Token")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)
        let health = try JSONDecoder().decode(Health.self, from: data)
        guard health.service == "lovort-mac-subtitles", health.model == Self.modelIdentifier else {
            throw LANMacSubtitleSettings.error("Mac 服务版本或模型不匹配")
        }
        return "Mac 字幕服务已连接 · Large V3 Turbo"
    }

    func transcribeProgressively(
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        preferredStartTime: TimeInterval,
        existingLines: [SubtitleLine],
        completedChunkIndexes: Set<Int>,
        onProgress: (@Sendable (String) -> Void)?,
        onEvent: (@Sendable (SubtitleProgressEvent) -> Void)?,
        onPartialResult: (@Sendable (LocalWhisperSubtitleService.ProgressiveUpdate) async -> [SubtitleLine]?)?
    ) async throws -> [SubtitleLine] {
        let (baseURL, token) = try configuration()
        _ = try await testConnection()
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = AudioTrackSelection.orderedTracks(tracks, sourceLanguage: sourceLanguage).first else {
            throw LANMacSubtitleSettings.error("视频中没有可用音轨")
        }
        let trackRange = try await track.load(.timeRange)
        let duration = CMTimeGetSeconds(trackRange.duration)
        guard duration.isFinite, duration > 0 else { throw LANMacSubtitleSettings.error("无法读取音频时长") }
        let chunkDuration = LocalWhisperSubtitleService.chunkDuration
        let total = max(1, Int(ceil(duration / chunkDuration)))
        let preferred = max(0, min(total - 1, Int(preferredStartTime / chunkDuration)))
        let pending = LocalWhisperSubtitleService.chunkProcessingOrder(
            totalChunks: total, preferredChunk: preferred, completed: completedChunkIndexes)
        var lines = existingLines
        var completed = completedChunkIndexes
        if let updated = await onPartialResult?(LocalWhisperSubtitleService.ProgressiveUpdate(
            lines: lines, completedChunkIndexes: completed.sorted(), totalChunkCount: total,
            latestChunkIndex: -1, latestChunkLines: [])) { lines = updated }

        for index in pending {
            try Task.checkCancellation()
            let start = Double(index) * chunkDuration
            let length = min(chunkDuration, duration - start)
            let sliceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lovort-mac-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: sliceURL) }
            onEvent?(.phase(.preparingAudio))
            onProgress?("正在提取第 \(completed.count + 1)/\(total) 个音频分片…")
            try await exporter.exportAudioSlice(mediaURL: audioURL, sourceLanguage: sourceLanguage,
                start: start, duration: length, outputURL: sliceURL)
            try Task.checkCancellation()
            onEvent?(.phase(.transcribing))
            onProgress?("Mac 正在转写第 \(completed.count + 1)/\(total) 个分片…")
            let result = try await upload(sliceURL, to: baseURL, token: token,
                language: sourceLanguage.whisperCode)
            try Task.checkCancellation()
            let chunkLines = result.segments.compactMap { segment -> SubtitleLine? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite,
                      segment.start >= 0, segment.end > segment.start,
                      segment.end <= length + 1 else { return nil }
                return SubtitleLine(startTime: start + segment.start,
                    endTime: start + min(segment.end, length), originalText: text)
            }
            lines.removeAll { $0.startTime >= start && $0.startTime < start + length }
            lines.append(contentsOf: chunkLines)
            lines.sort { $0.startTime < $1.startTime }
            completed.insert(index)
            onEvent?(.transcription(completed: completed.count, total: total))
            if let updated = await onPartialResult?(LocalWhisperSubtitleService.ProgressiveUpdate(
                lines: lines, completedChunkIndexes: completed.sorted(), totalChunkCount: total,
                latestChunkIndex: index, latestChunkLines: chunkLines)) { lines = updated }
        }
        guard !lines.isEmpty else { throw LANMacSubtitleSettings.error("Mac 未检测到清晰人声") }
        return lines
    }

    private func configuration() throws -> (URL, String) {
        let url = try LANMacSubtitleSettings.baseURL()
        let token = LANMacSubtitleSettings.accessToken
        guard !token.isEmpty else { throw LANMacSubtitleSettings.error("请先在设置中填写 Mac 服务访问口令") }
        return (url, token)
    }

    private func upload(_ file: URL, to baseURL: URL, token: String, language: String?) async throws -> Transcription {
        var components = URLComponents(url: baseURL.appendingPathComponent("transcribe"), resolvingAgainstBaseURL: false)!
        if let language { components.queryItems = [URLQueryItem(name: "language", value: language)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Lovort-Token")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try check(response: response, data: data)
        return try JSONDecoder().decode(Transcription.self, from: data)
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LANMacSubtitleSettings.error("Mac 服务没有返回有效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw LANMacSubtitleSettings.error("Mac 服务错误 \(http.statusCode)：\(detail)")
        }
    }
}
