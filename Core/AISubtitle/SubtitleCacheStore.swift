import Foundation

public struct SubtitleDocument: Codable, Sendable {
    public let version: Int
    public let sourceLanguage: String
    public let targetLanguage: String
    public let engine: AISubtitleEngineType
    public let model: String?
    public let translationConfiguration: String?
    public let translationProvider: SubtitleTranslationProviderType?
    public let isComplete: Bool?
    public let translationComplete: Bool?
    public let gptEnhanced: Bool?
    public let completedChunkIndexes: [Int]?
    public let chunkDuration: TimeInterval?
    public let createdAt: Date
    public let videoFileSize: Int64?
    public let videoModificationDate: Date?
    public let lines: [SubtitleLine]

    public init(
        sourceLanguage: String,
        targetLanguage: String,
        engine: AISubtitleEngineType,
        model: String?,
        translationProvider: SubtitleTranslationProviderType? = nil,
        translationConfiguration: String? = nil,
        isComplete: Bool = true,
        translationComplete: Bool? = nil,
        gptEnhanced: Bool? = nil,
        completedChunkIndexes: [Int]? = nil,
        chunkDuration: TimeInterval? = nil,
        videoURL: URL? = nil,
        lines: [SubtitleLine]
    ) {
        self.version = 1
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.engine = engine
        self.model = model
        self.translationConfiguration = translationConfiguration
        self.translationProvider = translationProvider
        self.isComplete = isComplete
        self.translationComplete = translationComplete
        self.gptEnhanced = gptEnhanced
        self.completedChunkIndexes = completedChunkIndexes
        self.chunkDuration = chunkDuration
        self.createdAt = Date()
        if let videoURL,
           let values = try? videoURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            self.videoFileSize = values.fileSize.map(Int64.init)
            self.videoModificationDate = values.contentModificationDate
        } else {
            self.videoFileSize = nil
            self.videoModificationDate = nil
        }
        self.lines = lines
    }
}

public struct SubtitleCacheStore: Sendable {
    public init() {}

    public func load(for videoURL: URL) -> SubtitleDocument? {
        for url in cacheCandidates(for: videoURL) where FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(SubtitleDocument.self, from: data),
                  !document.lines.isEmpty else { continue }
            if !matchesVideo(document, videoURL: videoURL) { continue }
            return document
        }
        return nil
    }

    @discardableResult
    public func save(_ document: SubtitleDocument, for videoURL: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        let sidecarURL = sidecarURL(for: videoURL)
        do {
            try data.write(to: sidecarURL, options: .atomic)
            return sidecarURL
        } catch {
            let fallbackURL = fallbackURL(for: videoURL)
            try FileManager.default.createDirectory(
                at: fallbackURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fallbackURL, options: .atomic)
            return fallbackURL
        }
    }

    public func sidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("lovort-subtitles.json")
    }

    private func cacheCandidates(for videoURL: URL) -> [URL] {
        [sidecarURL(for: videoURL), fallbackURL(for: videoURL)]
    }

    private func fallbackURL(for videoURL: URL) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("SubtitleCache", isDirectory: true)
        let identifier = stableIdentifier(for: videoURL)
        return folder.appendingPathComponent("\(identifier)-\(videoURL.deletingPathExtension().lastPathComponent).json")
    }

    private func stableIdentifier(for videoURL: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in videoURL.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func matchesVideo(_ document: SubtitleDocument, videoURL: URL) -> Bool {
        guard document.videoFileSize != nil || document.videoModificationDate != nil else { return true }
        guard let values = try? videoURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        if let expectedSize = document.videoFileSize, Int64(values.fileSize ?? -1) != expectedSize { return false }
        if let expectedDate = document.videoModificationDate,
           let actualDate = values.contentModificationDate,
           abs(actualDate.timeIntervalSince(expectedDate)) > 1 { return false }
        return true
    }
}
