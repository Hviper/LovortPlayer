import Foundation

public struct VideoItem: Identifiable, Sendable, Codable {
    public let id: UUID
    public var title: String
    public var fileURL: URL
    public var duration: TimeInterval
    public var fileSize: Int64
    public var isHidden: Bool
    public var createdAt: Date
    public var lastPlayedPosition: TimeInterval

    public init(
        id: UUID = UUID(),
        title: String,
        fileURL: URL,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        isHidden: Bool = false,
        createdAt: Date = Date(),
        lastPlayedPosition: TimeInterval = 0
    ) {
        self.id = id
        self.title = title
        self.fileURL = fileURL
        self.duration = duration
        self.fileSize = fileSize
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.lastPlayedPosition = lastPlayedPosition
    }
}

public struct SubtitleLine: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let originalText: String
    public let translatedText: String?

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        originalText: String,
        translatedText: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
        self.translatedText = translatedText
    }
}
