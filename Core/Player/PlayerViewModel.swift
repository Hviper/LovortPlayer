import Foundation
import AVFoundation
import CoreGraphics
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

    // AV1 (libdav1d) 软解渲染状态
    @Published public var isAV1SoftwareMode: Bool = false
    @Published public var currentSoftwareFrame: CGImage? = nil
    private var av1Engine: AV1SoftwareDecoderEngine? = nil
    private var av1RenderTask: Task<Void, Never>? = nil

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
        resetControlsTimeout()

        // 尝试自动载入字幕
        if let srt = AISubtitleCoordinator.shared.loadLocalSRTIfAvailable(for: url) {
            self.subtitles = srt
            self.isAISubtitleEnabled = true
        }

        // 读取历史播放进度
        let savedPosition = PlaybackHistoryManager.shared.getPlaybackPosition(for: url)

        // 1. 检测是否为 AV1 (av01) 编码视频：若为 AV1，启动 libdav1d 实时软解引擎 + 纯音频轨合成器（绕过 iOS VideoToolbox 对非 A17 Pro 机型的硬解封锁）
        if let engine = AV1SoftwareDecoderEngine(url: url) {
            self.av1Engine = engine
            self.isAV1SoftwareMode = true
            let totalDuration = engine.trackInfo.duration
            self.duration = totalDuration
            self.clipEndTime = min(totalDuration, 30.0)

            let startPos = (savedPosition > 3.0 && savedPosition < totalDuration - 5.0) ? savedPosition : 0.0
            self.currentTime = startPos

            // 立即解码首帧画面
            Task.detached(priority: .userInteractive) {
                if let firstFrame = engine.decodeFrame(at: startPos) {
                    await MainActor.run {
                        self.currentSoftwareFrame = firstFrame
                    }
                }
            }

            // 异步构建仅包含 AAC 音轨的 AVMutableComposition 交给 AVPlayer 播放声音
            Task {
                let asset = AVURLAsset(url: url)
                if let audioTracks = try? await asset.loadTracks(withMediaType: .audio), !audioTracks.isEmpty {
                    let composition = AVMutableComposition()
                    for track in audioTracks {
                        if let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                           let timeRange = try? await track.load(.timeRange) {
                            try? compTrack.insertTimeRange(timeRange, of: track, at: .zero)
                        }
                    }
                    let audioItem = AVPlayerItem(asset: composition)
                    self.player = AVPlayer(playerItem: audioItem)
                    if startPos > 0 {
                        let cmTime = CMTime(seconds: startPos, preferredTimescale: 600)
                        await self.player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    if self.isPlaying {
                        self.player?.play()
                        self.player?.rate = self.playbackRate
                    }
                }
            }

            startAV1RenderLoop()
            return
        }

        // 2. 标准 H.264 / HEVC 原生硬解流程
        self.isAV1SoftwareMode = false
        let playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: playerItem)
        setupTimeObserver()

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

    private func startAV1RenderLoop() {
        av1RenderTask?.cancel()
        av1RenderTask = Task { [weak self] in
            var lastSaveTime: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 FPS
                guard let self = self, let engine = self.av1Engine else { break }
                guard self.isPlaying && !self.isScrubbing else { continue }

                var targetTime = self.currentTime
                if let p = self.player, p.currentItem?.status == .readyToPlay {
                    if p.rate == 0 {
                        p.play()
                        p.rate = self.playbackRate
                    }
                    let audioSec = CMTimeGetSeconds(p.currentTime())
                    if audioSec.isFinite && !audioSec.isNaN && audioSec > 0 {
                        targetTime = audioSec
                    } else {
                        targetTime = min(self.duration, self.currentTime + 0.033 * Double(self.playbackRate))
                    }
                } else {
                    targetTime = min(self.duration, self.currentTime + 0.033 * Double(self.playbackRate))
                }

                self.currentTime = targetTime
                self.updateActiveSubtitle(at: targetTime)

                if abs(targetTime - lastSaveTime) >= 2.0 {
                    lastSaveTime = targetTime
                    self.saveCurrentProgress()
                }

                let decoded = await Task.detached(priority: .userInteractive) {
                    engine.decodeFrame(at: targetTime)
                }.value

                if let decoded = decoded, !Task.isCancelled {
                    self.currentSoftwareFrame = decoded
                }

                if targetTime >= self.duration && self.duration > 0 {
                    self.pause()
                }
            }
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            player?.rate = playbackRate
            isPlaying = true
            resetControlsTimeout()
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        updateActiveSubtitle(at: clamped)
        saveCurrentProgress()

        if isAV1SoftwareMode, let engine = av1Engine {
            Task.detached(priority: .userInteractive) {
                if let frame = engine.decodeFrame(at: clamped) {
                    await MainActor.run {
                        self.currentSoftwareFrame = frame
                    }
                }
            }
        }
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
        // 停止 AV1 软解线程并释放解码器上下文
        av1RenderTask?.cancel()
        av1RenderTask = nil
        av1Engine?.close()
        av1Engine = nil
        currentSoftwareFrame = nil

        // 彻底暂停并置空 player，防止后台发声
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false

        saveCurrentProgress()
        MediaLibraryManager.shared.reloadLibrary()
        if timeObserverToken != nil {
            timeObserverToken = nil
        }
        controlsHideTimer?.cancel()
    }
}
