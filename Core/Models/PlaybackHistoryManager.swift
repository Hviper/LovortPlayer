import Foundation
import AVFoundation
import Combine

@MainActor
public final class PlaybackHistoryManager: ObservableObject {
    public static let shared = PlaybackHistoryManager()

    private let userDefaultsKey = "LovortPlaybackHistoryRecords"

    private var playedDates: [String: Double] = UserDefaults.standard.dictionary(forKey: "LovortPlayedDates") as? [String: Double] ?? [:]
    private var lastFlush = Date.distantPast
    private var flushTask: Task<Void, Never>?

    // Stable media identity -> position
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
        let key = MediaIdentityStore.shared.id(for: url).uuidString
        if let position = historyMap[key] { return position }
        // Consume a legacy filename record once, so duplicates no longer share it.
        if let legacy = historyMap.removeValue(forKey: url.lastPathComponent) { historyMap[key] = legacy; flush(); return legacy }
        return 0
    }

    /// 保存播放进度
    public func savePlaybackPosition(for url: URL, position: TimeInterval, duration: TimeInterval) {
        let key = MediaIdentityStore.shared.id(for: url).uuidString
        playedDates[key] = Date().timeIntervalSince1970
        // 如果播放快结束（剩余少于 5 秒），重置进度为 0，视为已播完
        if duration > 0 && (duration - position) < 5.0 {
            historyMap.removeValue(forKey: key)
        } else if position > 2.0 {
            historyMap[key] = position
        }
        if Date().timeIntervalSince(lastFlush) >= 5 { flush() }
        else if flushTask == nil {
            flushTask = Task { try? await Task.sleep(for: .seconds(5)); guard !Task.isCancelled else { return }; flushTask = nil; flush() }
        }
    }

    public func lastPlayedDate(for url: URL) -> Date { Date(timeIntervalSince1970: playedDates[MediaIdentityStore.shared.id(for: url).uuidString] ?? 0) }

    public func flush() {
        lastFlush = Date()
        UserDefaults.standard.set(historyMap, forKey: userDefaultsKey)
        UserDefaults.standard.set(playedDates, forKey: "LovortPlayedDates")
    }

    /// 清空播放记录
    public func clearAllHistory() {
        flushTask?.cancel(); flushTask = nil
        playedDates.removeAll()
        UserDefaults.standard.removeObject(forKey: "LovortPlayedDates")
        historyMap.removeAll()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
