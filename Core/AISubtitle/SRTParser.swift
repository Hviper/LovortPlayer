import Foundation

public struct SRTParser {
    public static func parse(srtString: String) -> [SubtitleLine] {
        var lines: [SubtitleLine] = []
        let normalized = srtString
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        for block in blocks {
            let components = block.components(separatedBy: "\n")
            guard let timeIndex = components.firstIndex(where: { $0.contains("-->") }),
                  timeIndex + 1 < components.count else { continue }
            let timeString = components[timeIndex]
            let timeParts = timeString.components(separatedBy: "-->")
            guard timeParts.count == 2 else { continue }

            guard let start = parseTimestamp(timeParts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseTimestamp(timeParts[1].trimmingCharacters(in: .whitespaces)),
                  end > start else { continue }
            let textLines = components[(timeIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !textLines.isEmpty else { continue }

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

    private static func parseTimestamp(_ timestamp: String) -> TimeInterval? {
        // 00:01:23,456
        let value = timestamp.components(separatedBy: .whitespaces).first ?? timestamp
        let parts = value.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// 将字幕数组序列化为标准 SRT 字符串（支持双语显示）
    public static func generateSRT(from lines: [SubtitleLine]) -> String {
        var srt = ""
        for (index, line) in lines.enumerated() {
            let start = formatTimestamp(line.startTime)
            let end = formatTimestamp(line.endTime)
            srt += "\(index + 1)\n"
            srt += "\(start) --> \(end)\n"
            if let trans = line.translatedText, !trans.isEmpty {
                srt += "\(line.originalText)\n\(trans)\n\n"
            } else {
                srt += "\(line.originalText)\n\n"
            }
        }
        return srt
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let totalMs = Int(max(0, seconds) * 1000)
        let hrs = totalMs / 3600000
        let mins = (totalMs % 3600000) / 60000
        let secs = (totalMs % 60000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", hrs, mins, secs, ms)
    }
}
