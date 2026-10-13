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
