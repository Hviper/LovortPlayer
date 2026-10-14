import AVFoundation
import Foundation

enum AudioTrackSelection {
    static func orderedIndices(
        languageTags: [String],
        sourceLanguage: SubtitleSourceLanguage
    ) -> [Int] {
        let candidates = sourceLanguage.trackLanguageCandidates
        return languageTags.indices.sorted { lhs, rhs in
            let leftMatches = matches(languageTags[lhs], candidates: candidates)
            let rightMatches = matches(languageTags[rhs], candidates: candidates)
            if leftMatches != rightMatches { return leftMatches }
            return lhs < rhs
        }
    }

    static func orderedTracks(
        _ tracks: [AVAssetTrack],
        sourceLanguage: SubtitleSourceLanguage
    ) -> [AVAssetTrack] {
        let tags = tracks.map(languageTag(for:))
        return orderedIndices(languageTags: tags, sourceLanguage: sourceLanguage).map { tracks[$0] }
    }

    static func languageTag(for track: AVAssetTrack) -> String {
        (track.extendedLanguageTag ?? track.languageCode ?? "").lowercased()
    }

    static func displayName(for track: AVAssetTrack, at index: Int) -> String {
        let tag = languageTag(for: track)
        return tag.isEmpty ? "音轨 \(index + 1) · 未标注语言" : "音轨 \(index + 1) · \(tag)"
    }

    private static func matches(_ tag: String, candidates: [String]) -> Bool {
        candidates.contains { tag == $0 || tag.hasPrefix("\($0)-") }
    }
}
