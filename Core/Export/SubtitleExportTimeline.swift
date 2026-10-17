import Foundation

public enum SubtitleVideoExportMode: String, CaseIterable, Identifiable, Sendable {
    case embedded, burnedIn
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .burnedIn: return "烧录字幕（强烈推荐：固定在画面）"
        case .embedded: return "内嵌字幕（软字幕：可开关）"
        }
    }
    public var detail: String {
        switch self {
        case .burnedIn:
            return "【强烈推荐】将字幕直接压制在画面中。100% 兼容微信、相册、抖音及所有播放器，字幕永不丢失。"
        case .embedded:
            return "生成带字幕轨道的 MP4，适合电脑端专业播放器（VLC/IINA/Infuse）。注意：系统相册或微信转码时可能会忽略软字幕。"
        }
    }
}

public enum SubtitleExportTextMode: String, CaseIterable, Identifiable, Sendable {
    case bilingual, original, translated
    public var id: String { rawValue }
    public var title: String {
        switch self { case .bilingual: return "双语字幕"; case .original: return "原文"; case .translated: return "译文" }
    }
    public func text(for line: SubtitleLine) -> String {
        let original = line.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = (line.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .original: return original
        case .translated: return translated.isEmpty ? original : translated
        case .bilingual: return translated.isEmpty || translated == original ? original : [original, translated].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

public enum SubtitleVideoExportError: LocalizedError {
    case noSubtitles, invalidDuration, unsupportedVideo, textTooLong, failed(String)
    public var errorDescription: String? {
        switch self {
        case .noSubtitles: return "没有可导出的字幕，请先生成或导入字幕。"
        case .invalidDuration: return "无法读取有效视频时长。"
        case .unsupportedVideo: return "系统无法导出此视频格式，请使用系统可解码的视频（如 H.264 / HEVC）。"
        case .textTooLong: return "单段字幕过长，超过 MP4 字幕轨道限制，请先拆分字幕。"
        case .failed(let message): return "字幕视频导出失败：\(message)"
        }
    }
}

public struct SubtitleExportCue: Sendable, Equatable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let text: String
}

/// A non-overlapping timeline, including explicit empty samples to clear captions in gaps.
public enum SubtitleExportTimeline {
    public static func make(lines: [SubtitleLine], duration: TimeInterval, textMode: SubtitleExportTextMode) throws -> [SubtitleExportCue] {
        guard duration.isFinite, duration > 0, duration < Double(Int64.max / 1000) else { throw SubtitleVideoExportError.invalidDuration }
        let end = Int64(ceil(duration * 1000))
        guard end > 0 else { throw SubtitleVideoExportError.invalidDuration }
        struct Event { let time: Int64; let index: Int; let text: String? }
        var events: [Event] = []
        for (index, line) in lines.enumerated() {
            guard line.startTime.isFinite, line.endTime.isFinite, line.endTime > line.startTime else { continue }
            let start = Int64((max(0, min(duration, line.startTime)) * 1000).rounded())
            let stop = Int64((max(0, min(duration, line.endTime)) * 1000).rounded())
            let text = textMode.text(for: line)
            guard stop > start, !text.isEmpty else { continue }
            events.append(Event(time: start, index: index, text: text))
            events.append(Event(time: stop, index: index, text: nil))
        }
        guard !events.isEmpty else { throw SubtitleVideoExportError.noSubtitles }
        events.sort { $0.time < $1.time }
        var active: [Int: String] = [:]
        var output: [SubtitleExportCue] = []
        var position: Int64 = 0
        var cursor = 0
        func append(until stop: Int64) {
            guard stop > position else { return }
            let text = active.keys.sorted().compactMap { active[$0] }.joined(separator: "\n")
            if let last = output.last, last.text == text {
                output[output.count - 1] = SubtitleExportCue(startMilliseconds: last.startMilliseconds, endMilliseconds: stop, text: text)
            } else {
                output.append(SubtitleExportCue(startMilliseconds: position, endMilliseconds: stop, text: text))
            }
            position = stop
        }
        while cursor < events.count {
            let time = events[cursor].time
            append(until: time)
            while cursor < events.count, events[cursor].time == time {
                let event = events[cursor]
                active[event.index] = event.text
                cursor += 1
            }
        }
        append(until: end)
        return output
    }

    static func timedTextPayload(_ text: String) throws -> Data {
        let bytes = Data(text.utf8)
        guard bytes.count <= Int(UInt16.max) else { throw SubtitleVideoExportError.textTooLong }
        var length = UInt16(bytes.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + bytes
    }
}
