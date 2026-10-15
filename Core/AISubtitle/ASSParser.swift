import Foundation

public enum ASSParser {
    public static func parse(_ content: String) -> [SubtitleLine] {
        var inEvents = false
        var columns: [String] = []
        var lines: [SubtitleLine] = []
        for raw in content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                columns = String(line.dropFirst(7)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = columns.firstIndex(of: "start"),
                  let endIndex = columns.firstIndex(of: "end"),
                  let textIndex = columns.firstIndex(of: "text") else { continue }
            let body = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            let values = body.split(separator: ",", maxSplits: max(0, columns.count - 1), omittingEmptySubsequences: false).map(String.init)
            guard values.count == columns.count,
                  let start = timestamp(values[startIndex]), let end = timestamp(values[endIndex]), end > start else { continue }
            let text = values[textIndex]
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\N"#, with: "\n")
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\h"#, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(SubtitleLine(startTime: start, endTime: end, originalText: text)) }
        }
        return lines.sorted { $0.startTime < $1.startTime }
    }

    private static func timestamp(_ value: String) -> TimeInterval? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
