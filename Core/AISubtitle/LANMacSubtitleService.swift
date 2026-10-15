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
    private let session: URLSession
    private let pollInterval: Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    private struct Health: Decodable {
        let service: String
        let version: Int
        let model: String
    }

    private struct Segment: Decodable {
        let chunk: Int
        let start: Double
        let end: Double
        let text: String
    }

    private struct RemoteJob: Decodable {
        let status: String
        let completedChunks: [Int]
        let totalChunks: Int
        let segments: [Segment]
        let error: String?

        enum CodingKeys: String, CodingKey {
            case status, segments, error
            case completedChunks = "completed_chunks"
            case totalChunks = "total_chunks"
        }
    }

    public init() {
        session = .shared
        pollInterval = .seconds(4)
        sleeper = { try await Task.sleep(for: $0) }
    }

    init(session: URLSession, pollInterval: Duration,
         sleeper: @escaping @Sendable (Duration) async throws -> Void) {
        self.session = session
        self.pollInterval = pollInterval
        self.sleeper = sleeper
    }

    public func testConnection() async throws -> String {
        let (baseURL, token) = try configuration()
        return try await healthCheck(baseURL: baseURL, token: token)
    }

    private func healthCheck(baseURL: URL, token: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.setValue(token, forHTTPHeaderField: "X-Lovort-Token")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data)
        let health = try JSONDecoder().decode(Health.self, from: data)
        guard health.service == "lovort-mac-subtitles", health.version >= 2,
              health.model == Self.modelIdentifier else {
            throw LANMacSubtitleSettings.error("Mac 服务版本或模型不匹配")
        }
        return "Mac 字幕服务已连接 · Large V3 Turbo"
    }

    func transcribeProgressively(
        audioURL: URL,
        sourceLanguage: SubtitleSourceLanguage,
        jobID: UUID,
        preferredStartTime: TimeInterval,
        existingLines: [SubtitleLine],
        completedChunkIndexes: Set<Int>,
        onProgress: (@Sendable (String) -> Void)?,
        onEvent: (@Sendable (SubtitleProgressEvent) -> Void)?,
        onPartialResult: (@Sendable (LocalWhisperSubtitleService.ProgressiveUpdate) async -> [SubtitleLine]?)?
    ) async throws -> [SubtitleLine] {
        let (baseURL, token) = try configuration()
        _ = try await retryTransientNetworkOperation(
            maximumAttempts: 3,
            retryStatus: "连接 Mac 暂时超时，正在自动重试…",
            recoveredStatus: "已重新连接 Mac，正在检查字幕任务…",
            onProgress: onProgress
        ) {
            try await healthCheck(baseURL: baseURL, token: token)
        }
        var job = try await retryTransientNetworkOperation(
            maximumAttempts: 3,
            retryStatus: "读取 Mac 字幕任务超时，正在自动重试…",
            recoveredStatus: "已重新连接 Mac，正在继续字幕任务…",
            onProgress: onProgress
        ) {
            try await fetchJob(jobID, from: baseURL, token: token)
        }
        if job == nil || job?.status == "failed" {
            let asset = AVURLAsset(url: audioURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = AudioTrackSelection.orderedTracks(tracks, sourceLanguage: sourceLanguage).first else {
                throw LANMacSubtitleSettings.error("视频中没有可用音轨")
            }
            let range = try await track.load(.timeRange)
            let duration = CMTimeGetSeconds(range.duration)
            guard duration.isFinite, duration > 0 else { throw LANMacSubtitleSettings.error("无法读取音频时长") }
            let audioFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("lovort-mac-job-\(jobID.uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audioFile) }
            onEvent?(.phase(.preparingAudio))
            onProgress?("正在准备所选音轨，请保持 App 前台…")
            try await exporter.exportAudioSlice(mediaURL: audioURL, sourceLanguage: sourceLanguage,
                start: 0, duration: duration, outputURL: audioFile)
            try Task.checkCancellation()
            let size = (try audioFile.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 0, size <= 512 * 1_024 * 1_024 else {
                throw LANMacSubtitleSettings.error("音轨超过 Mac 服务 512 MiB 上传限制")
            }
            onProgress?("正在上传音轨，请保持 App 前台…")
            job = try await submit(audioFile, jobID: jobID, to: baseURL,
                token: token, language: sourceLanguage.whisperCode,
                preferredStartTime: preferredStartTime)
        }
        onEvent?(.phase(.transcribing))
        onProgress?("Mac 已接收音轨；现在可以锁屏，返回后会自动领取字幕")

        let chunkDuration = LocalWhisperSubtitleService.chunkDuration
        var lines = existingLines
        var completed = completedChunkIndexes
        while true {
            try Task.checkCancellation()
            guard let current = job else { throw LANMacSubtitleSettings.error("Mac 字幕任务不存在，请重试") }
            if current.status == "failed" {
                throw LANMacSubtitleSettings.error("Mac 转写失败：\(current.error ?? "未知错误")")
            }
            let total = max(1, current.totalChunks)
            for index in current.completedChunks.sorted() where !completed.contains(index) {
                let start = Double(index) * chunkDuration
                let chunkLines = current.segments.filter { $0.chunk == index }.compactMap { segment -> SubtitleLine? in
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite,
                          segment.start >= start, segment.end > segment.start,
                          segment.end <= start + chunkDuration + 1 else { return nil }
                    return SubtitleLine(startTime: segment.start, endTime: segment.end, originalText: text)
                }
                lines.removeAll { $0.startTime >= start && $0.startTime < start + chunkDuration }
                lines.append(contentsOf: chunkLines)
                lines.sort { $0.startTime < $1.startTime }
                completed.insert(index)
                onEvent?(.transcription(completed: completed.count, total: total))
                if let updated = await onPartialResult?(LocalWhisperSubtitleService.ProgressiveUpdate(
                    lines: lines, completedChunkIndexes: completed.sorted(), totalChunkCount: total,
                    latestChunkIndex: index, latestChunkLines: chunkLines)) { lines = updated }
            }
            if current.status == "completed" { break }
            try await sleeper(pollInterval)
            job = try await retryTransientNetworkOperation(
                retryStatus: "与 Mac 的连接暂时中断，Mac 仍在转写；正在自动重连…",
                recoveredStatus: "已重新连接 Mac，继续领取字幕…",
                onProgress: onProgress
            ) {
                try await fetchJob(jobID, from: baseURL, token: token)
            }
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

    private func jobURL(_ id: UUID, baseURL: URL, language: String? = nil,
                        preferredStartTime: TimeInterval? = nil) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("jobs/\(id.uuidString)"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let language { items.append(URLQueryItem(name: "language", value: language)) }
        if let preferredStartTime, preferredStartTime.isFinite {
            items.append(URLQueryItem(name: "preferred_start", value: String(max(0, preferredStartTime))))
        }
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    private func fetchJob(_ id: UUID, from baseURL: URL, token: String) async throws -> RemoteJob? {
        var request = URLRequest(url: jobURL(id, baseURL: baseURL))
        request.setValue(token, forHTTPHeaderField: "X-Lovort-Token")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(response: response, data: data)
        return try JSONDecoder().decode(RemoteJob.self, from: data)
    }

    private func submit(_ file: URL, jobID: UUID, to baseURL: URL,
                        token: String, language: String?, preferredStartTime: TimeInterval) async throws -> RemoteJob {
        var request = URLRequest(url: jobURL(jobID, baseURL: baseURL, language: language,
            preferredStartTime: preferredStartTime))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Lovort-Token")
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try check(response: response, data: data)
        return try JSONDecoder().decode(RemoteJob.self, from: data)
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

    func retryTransientNetworkOperation<T>(
        maximumAttempts: Int? = nil,
        retryStatus: String = "与 Mac 的连接暂时中断，正在自动重连…",
        recoveredStatus: String? = "已重新连接 Mac…",
        onProgress: (@Sendable (String) -> Void)?,
        operation: () async throws -> T
    ) async throws -> T {
        var failureCount = 0
        while true {
            try Task.checkCancellation()
            do {
                let result = try await operation()
                if failureCount > 0, let recoveredStatus { onProgress?(recoveredStatus) }
                return result
            } catch let error as CancellationError {
                throw error
            } catch {
                try Task.checkCancellation()
                guard Self.isTransientNetworkError(error) else { throw error }
                failureCount += 1
                if let maximumAttempts, failureCount >= maximumAttempts { throw error }
                onProgress?(retryStatus)
                try await sleeper(Self.reconnectDelay(after: failureCount))
            }
        }
    }

    static func isTransientNetworkError(_ error: Error) -> Bool {
        let code: URLError.Code
        if let urlError = error as? URLError {
            code = urlError.code
        } else {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else { return false }
            code = URLError.Code(rawValue: nsError.code)
        }
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func reconnectDelay(after failureCount: Int) -> Duration {
        let seconds: [Double] = [2, 4, 8, 15, 30]
        return .seconds(seconds[min(max(1, failureCount), seconds.count) - 1])
    }
}
