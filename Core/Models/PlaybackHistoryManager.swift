import Foundation
import AVFoundation

@MainActor
public final class PlaybackHistoryManager: ObservableObject {
    public static let shared = PlaybackHistoryManager()

    private let userDefaultsKey = "LovortPlaybackHistoryRecords"

    // 保存视频 URL 路径 -> 播放秒数
    @Published private var historyMap: [String: TimeInterval] = [:]

    private init() {
        loadHistory()
    }

    private func loadHistory() {
        if let saved = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Double] {
            self.historyMap = saved
        }
    }

    /// 获取视频上次播放进度
    public func getPlaybackPosition(for url: URL) -> TimeInterval {
        let key = url.lastPathComponent
        return historyMap[key] ?? 0
    }

    /// 保存播放进度
    public func savePlaybackPosition(for url: URL, position: TimeInterval, duration: TimeInterval) {
        let key = url.lastPathComponent
        // 如果播放快结束（剩余少于 5 秒），重置进度为 0，视为已播完
        if duration > 0 && (duration - position) < 5.0 {
            historyMap.removeValue(forKey: key)
        } else if position > 2.0 {
            historyMap[key] = position
        }
        UserDefaults.standard.set(historyMap, forKey: userDefaultsKey)
    }

    /// 清空播放记录
    public func clearAllHistory() {
        historyMap.removeAll()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
