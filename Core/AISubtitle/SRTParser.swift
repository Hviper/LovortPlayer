import Foundation

public struct SRTParser {
    public static func parse(srtString: String) -> [SubtitleLine] {
        var lines: [SubtitleLine] = []
        let blocks = srtString.components(separatedBy: "\n\n")

        for block in blocks {
            let components = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard components.count >= 3 else { continue }
            
            // components[0]: 序号
            // components[1]: 00:00:01,000 --> 00:00:04,000
            let timeString = components[1]
            let textLines = components.dropFirst(2).joined(separator: "\n")
            
            let timeParts = timeString.components(separatedBy: "-->")
            guard timeParts.count == 2 else { continue }
            
            let start = parseTimestamp(timeParts[0].trimmingCharacters(in: .whitespaces))
            let end = parseTimestamp(timeParts[1].trimmingCharacters(in: .whitespaces))
            
            lines.append(
                SubtitleLine(
                    startTime: start,
                    endTime: end,
                    originalText: textLines,
                    translatedText: nil
                )
            )
        }
        return lines
    }

    private static func parseTimestamp(_ timestamp: String) -> TimeInterval {
        // 00:01:23,456
        let parts = timestamp.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return 0 }
        return hours * 3600 + minutes * 60 + seconds
    }
}
