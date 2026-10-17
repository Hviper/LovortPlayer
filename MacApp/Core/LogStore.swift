import Foundation
import Combine

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let message: String
    public let isError: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public init(id: UUID = UUID(), timestamp: Date = Date(), message: String, isError: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.isError = isError
    }

    public var timestampText: String {
        Self.timeFormatter.string(from: timestamp)
    }

    public var formattedLine: String {
        "[\(timestampText)] \(message)"
    }
}

@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    @Published public private(set) var entries: [LogEntry] = []
    public let maxCapacity: Int
    private var redactor: SecretRedactor

    public init(maxCapacity: Int = 1500, redactor: SecretRedactor = SecretRedactor()) {
        self.maxCapacity = maxCapacity
        self.redactor = redactor
    }

    public func updateKnownSecrets(_ secrets: [String]) {
        self.redactor = SecretRedactor(knownSecrets: secrets)
    }

    public func append(rawLine: String, isError: Bool = false) {
        let trimmed = rawLine.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }

        // Multiple lines in rawLine
        let lines = trimmed.components(separatedBy: .newlines)
        for line in lines {
            let sanitized = redactor.redact(line)
            let entry = LogEntry(message: sanitized, isError: isError)
            entries.append(entry)
        }

        if entries.count > maxCapacity {
            let dropCount = entries.count - maxCapacity
            entries.removeFirst(dropCount)
        }
    }

    public func clear() {
        entries.removeAll()
    }

    public func exportPlainText() -> String {
        entries.map(\.formattedLine).joined(separator: "\n")
    }
}
