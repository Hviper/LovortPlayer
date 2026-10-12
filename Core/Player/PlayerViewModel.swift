import Foundation
import AVFoundation
import Combine
#if os(iOS)
import UIKit
import MediaPlayer
#endif

@MainActor
public final class PlayerViewModel: ObservableObject {
    @Published public var player: AVPlayer?
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: TimeInterval = 0
    @Published public var duration: TimeInterval = 0
    @Published public var isBuffering: Bool = false
    @Published public var playbackRate: Float = 1.0

    // 手势与 HUD 控制
    @Published public var showControls: Bool = true
    @Published public var volume: Float = 1.0
    @Published public var brightness: CGFloat = 0.5
    @Published public var isScrubbing: Bool = false
    @Published public var scrubPreviewTime: TimeInterval = 0

    // AI 字幕控制
    @Published public var isAISubtitleEnabled: Bool = false
    @Published public var showAISubtitlePanel: Bool = false
    @Published public var currentSubtitle: SubtitleLine?
    @Published public var isGeneratingSubtitles: Bool = false
    public var subtitles: [SubtitleLine] = []

    // 无损剪辑模式
    @Published public var isClipMode: Bool = false
    @Published public var clipStartTime: TimeInterval = 0
    @Published public var clipEndTime: TimeInterval = 0
    @Published public var isExportingClip: Bool = false
    @Published public var exportMessage: String? = nil

    private var currentVideoURL: URL?
    private var timeObserverToken: Any?
    private var controlsHideTimer: Task<Void, Never>?

    public init() {}

    public func loadVideo(url: URL) {
        self.currentVideoURL = url
        let playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: playerItem)
        setupTimeObserver()
        resetControlsTimeout()

        // 尝试自动载入字幕
        if let srt = AISubtitleCoordinator.shared.loadLocalSRTIfAvailable(for: url) {
            self.subtitles = srt
            self.isAISubtitleEnabled = true
        }

        // 读取历史播放进度
        let savedPosition = PlaybackHistoryManager.shared.getPlaybackPosition(for: url)

        Task {
            if let durationCM = try? await playerItem.asset.load(.duration) {
                let seconds = CMTimeGetSeconds(durationCM)
                if seconds.isFinite && !seconds.isNaN {
                    self.duration = seconds
                    self.clipEndTime = min(seconds, 30.0)

                    // 如果有历史播放记录，自动跳转并提示
                    if savedPosition > 3.0 && savedPosition < seconds - 5.0 {
                        self.seek(to: savedPosition)
                    }
                }
            }
        }
    }

    public func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            player.rate = playbackRate
            isPlaying = true
            resetControlsTimeout()
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateActiveSubtitle(at: time)
        saveCurrentProgress()
    }

    public func fastForward(by seconds: TimeInterval = 10) {
        seek(to: currentTime + seconds)
        triggerControlsDisplay()
    }

    public func rewind(by seconds: TimeInterval = 10) {
        seek(to: currentTime - seconds)
        triggerControlsDisplay()
    }

    public func setPlaybackRate(_ rate: Float) {
        self.playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    public func triggerControlsDisplay() {
        showControls = true
        resetControlsTimeout()
    }

    public func toggleControls() {
        showControls.toggle()
        if showControls {
            resetControlsTimeout()
        }
    }

    public func generateAISubtitles() {
        guard let url = currentVideoURL else { return }
        Task {
            self.isGeneratingSubtitles = true
            do {
                let lines = try await AISubtitleCoordinator.shared.processVideo(videoURL: url)
                self.subtitles = lines
                self.isAISubtitleEnabled = true
                self.updateActiveSubtitle(at: self.currentTime)
            } catch {
                print("Generate subtitles failed: \(error)")
            }
            self.isGeneratingSubtitles = false
        }
    }

    public func exportClip() {
        guard let url = currentVideoURL else { return }
        let startTime = CMTime(seconds: clipStartTime, preferredTimescale: 600)
        let endTime = CMTime(seconds: clipEndTime, preferredTimescale: 600)

        let clipsDir = MediaLibraryManager.shared.clipsDirectory
        let clipName = "Clip_\(Int(Date().timeIntervalSince1970)).mp4"
        let outputURL = clipsDir.appendingPathComponent(clipName)

        isExportingClip = true
        exportMessage = "正在无损导出..."

        Task {
            do {
                try await LosslessClipManager.shared.exportLosslessClip(
                    assetURL: url,
                    outputURL: outputURL,
                    startTime: startTime,
                    endTime: endTime
                )
                self.exportMessage = "导出成功！已存入剪辑库及相册"
                MediaLibraryManager.shared.reloadLibrary()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.isClipMode = false
                self.isExportingClip = false
                self.exportMessage = nil
            } catch {
                self.exportMessage = "导出失败: \(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.isExportingClip = false
                self.exportMessage = nil
            }
        }
    }

    private func saveCurrentProgress() {
        guard let url = currentVideoURL else { return }
        PlaybackHistoryManager.shared.savePlaybackPosition(
            for: url,
            position: currentTime,
            duration: duration
        )
    }

    private func resetControlsTimeout() {
        controlsHideTimer?.cancel()
        guard isPlaying else { return }
        controlsHideTimer = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                self.showControls = false
            }
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.3, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isScrubbing else { return }
                let current = CMTimeGetSeconds(time)
                self.currentTime = current
                self.updateActiveSubtitle(at: current)
                // 定期记录进度
                self.saveCurrentProgress()
            }
        }
    }

    private func updateActiveSubtitle(at time: TimeInterval) {
        guard isAISubtitleEnabled else {
            currentSubtitle = nil
            return
        }
        currentSubtitle = subtitles.first { time >= $0.startTime && time <= $0.endTime }
    }

    public func cleanup() {
        // 彻底暂停并置空 player，防止后台发声
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false

        saveCurrentProgress()
        MediaLibraryManager.shared.reloadLibrary()
        if let token = timeObserverToken {
            timeObserverToken = nil
        }
        controlsHideTimer?.cancel()
    }
}
