import Foundation
import SwiftUI

public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case processing
    case completed
    case failed

    public var displayName: String {
        switch self {
        case .queued: return "排队中"
        case .processing: return "转写中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .queued: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    public var statusColor: Color {
        switch self {
        case .queued: return .orange
        case .processing: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

public struct JobSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(chunk)-\(start)-\(end)" }
    public let chunk: Int
    public let start: Double
    public let end: Double
    public let text: String

    public init(chunk: Int, start: Double, end: Double, text: String) {
        self.chunk = chunk
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptionJob: Identifiable, Equatable, Sendable {
    public let id: String
    public let status: JobStatus
    public let language: String?
    public let preferredStart: Double
    public let completedChunks: [Int]
    public let totalChunks: Int
    public let segmentsCount: Int
    public let error: String?
    public let updatedAt: Date

    public init(
        id: String,
        status: JobStatus,
        language: String? = nil,
        preferredStart: Double = 0,
        completedChunks: [Int] = [],
        totalChunks: Int = 0,
        segmentsCount: Int = 0,
        error: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.status = status
        self.language = language
        self.preferredStart = preferredStart
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.segmentsCount = segmentsCount
        self.error = error
        self.updatedAt = updatedAt
    }

    public var shortId: String {
        String(id.prefix(8))
    }

    public var progressPercentage: Double {
        guard totalChunks > 0 else {
            return status == .completed ? 1.0 : 0.0
        }
        return min(1.0, max(0.0, Double(completedChunks.count) / Double(totalChunks)))
    }

    public var progressPercentageText: String {
        "\(Int(progressPercentage * 100))%"
    }

    public var segmentProgressDescription: String {
        if totalChunks <= 0 {
            switch status {
            case .completed:
                return "已完成"
            case .failed:
                return "未开始即失败"
            default:
                return "计算总切片中..."
            }
        }
        return "\(completedChunks.count) / \(totalChunks) 片段"
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    public var formattedUpdatedAt: String {
        Self.dateFormatter.string(from: updatedAt)
    }
}

extension TranscriptionJob: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case language
        case preferred_start
        case completed_chunks
        case total_chunks
        case segments
        case error
        case updated_at
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)

        let statusString = try container.decode(String.self, forKey: .status)
        self.status = JobStatus(rawValue: statusString) ?? .failed

        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.preferredStart = try container.decodeIfPresent(Double.self, forKey: .preferred_start) ?? 0.0
        self.completedChunks = try container.decodeIfPresent([Int].self, forKey: .completed_chunks) ?? []
        self.totalChunks = try container.decodeIfPresent(Int.self, forKey: .total_chunks) ?? 0

        // Parse segments count efficiently without retaining all heavy segment text if not needed
        if let segs = try? container.decodeIfPresent([JobSegment].self, forKey: .segments) {
            self.segmentsCount = segs.count
        } else {
            self.segmentsCount = 0
        }

        self.error = try container.decodeIfPresent(String.self, forKey: .error)

        if let timestamp = try container.decodeIfPresent(Double.self, forKey: .updated_at) {
            self.updatedAt = Date(timeIntervalSince1970: timestamp)
        } else {
            self.updatedAt = Date()
        }
    }
}
