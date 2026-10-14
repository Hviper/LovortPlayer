import Foundation
import AVFoundation
import CoreGraphics
import Combine
import KSPlayer
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
    @Published public var playbackErrorMessage: String? = nil
    @Published public var playbackRate: Float = 1.0

    // AVPlayer 不支持的容器由 KSPlayer 自动从 AVFoundation 回退到 FFmpeg。
    @Published public private(set) var isCompatibilityMode: Bool = false
    public private(set) var compatibilityCoordinator: KSVideoPlayer.Coordinator?
    public private(set) var compatibilityOptions: KSOptions?
    private var pendingCompatibilityStart: TimeInterval = 0

    // AV1 (libdav1d) 软解渲染状态
    @Published public var isAV1SoftwareMode: Bool = false
    @Published public var currentSoftwareFrame: CGImage? = nil
    private var av1Engine: AV1SoftwareDecoderEngine? = nil
    private var av1RenderTask: Task<Void, Never>? = nil

    // 手势与 HUD 控制
    @Published public var showControls: Bool = true
    @Published public var volume: Float = 1.0 {
        didSet {
            player?.volume = volume
            if volume > 0 && player?.isMuted == true {
                player?.isMuted = false
            }
        }
    }
    @Published public var brightness: CGFloat = 0.5
    @Published public var isScrubbing: Bool = false
    @Published public var scrubPreviewTime: TimeInterval = 0

    // AI 字幕控制
    @Published public var isAISubtitleEnabled: Bool = false
    @Published public var showAISubtitlePanel: Bool = false
    @Published public var currentSubtitle: SubtitleLine?
    @Published public var isGeneratingSubtitles: Bool = false
    @Published public var generatingSubtitleStatusText: String = ""
    @Published public var subtitleErrorMessage: String? = nil
    @Published public var subtitles: [SubtitleLine] = []

    // 无损剪辑模式
    @Published public var isClipMode: Bool = false
    @Published public var clipStartTime: TimeInterval = 0
    @Published public var clipEndTime: TimeInterval = 0
    @Published public var isExportingClip: Bool = false
    @Published public var exportMessage: String? = nil

    @Published public private(set) var currentVideoURL: URL?
    public private(set) var currentVideoIsPrivate: Bool = false
    private var timeObserverToken: Any?
    private var controlsHideTimer: Task<Void, Never>?
    private var subtitleTaskObservation: AnyCancellable?

    public init() {
        subtitleTaskObservation = SubtitleTaskManager.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.syncGlobalSubtitleTask()
            }
        }
    }

    public func loadVideo(url: URL, isPrivate: Bool = false) {
        cleanupPlaybackEngines(saveProgress: false)
        isGeneratingSubtitles = false
        generatingSubtitleStatusText = ""
        subtitleErrorMessage = nil
        playbackErrorMessage = nil
        subtitles = []
        currentSubtitle = nil
        isAISubtitleEnabled = false
        self.currentVideoURL = url
        self.currentVideoIsPrivate = isPrivate
        resetControlsTimeout()

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            print("Failed to activate AVAudioSession in loadVideo: \(error)")
        }
        #endif

        // 应用设置中的默认音量
        if AppSettings.shared.useDefaultVolume {
            self.volume = AppSettings.shared.defaultVolume
            SystemVolumeController.shared.setVolume(AppSettings.shared.defaultVolume)
        } else {
            #if os(iOS)
            let sysVol = SystemVolumeController.shared.getCurrentVolume()
            self.volume = sysVol > 0 ? sysVol : 1.0
            #endif
        }

        // 尝试自动载入字幕
        if let srt = AISubtitleCoordinator.shared.loadLocalSRTIfAvailable(for: url) {
            self.subtitles = srt
            self.isAISubtitleEnabled = true
        }
        syncGlobalSubtitleTask()

        // 读取历史播放进度
        let savedPosition = PlaybackHistoryManager.shared.getPlaybackPosition(for: url)

        if Self.requiresCompatibilityPlayer(url) {
            configureCompatibilityPlayer(url: url, savedPosition: savedPosition)
            return
        }

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
                    let p = AVPlayer(playerItem: audioItem)
                    p.volume = self.volume
                    p.isMuted = false
                    self.player = p
                    if startPos > 0 {
                        let cmTime = CMTime(seconds: startPos, preferredTimescale: 600)
                        await p.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    if self.isPlaying {
                        p.play()
                        p.rate = self.playbackRate
                    }
                }
            }

            startAV1RenderLoop()
            return
        }

        // 2. 标准 H.264 / HEVC 原生硬解流程
        self.isAV1SoftwareMode = false
        let playerItem = AVPlayerItem(url: url)
        let nativePlayer = AVPlayer(playerItem: playerItem)
        nativePlayer.volume = self.volume
        nativePlayer.isMuted = false
        self.player = nativePlayer
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

    private static func requiresCompatibilityPlayer(_ url: URL) -> Bool {
        ["mkv", "avi", "webm", "flv", "wmv", "ts", "m2ts", "vob", "ogv"]
            .contains(url.pathExtension.lowercased())
    }

    private func configureCompatibilityPlayer(url: URL, savedPosition: TimeInterval) {
        let options = KSOptions()
        options.hardwareDecode = true
        let coordinator = KSVideoPlayer.Coordinator()
        pendingCompatibilityStart = savedPosition
        compatibilityOptions = options
        compatibilityCoordinator = coordinator
        isCompatibilityMode = true

        coordinator.onStateChanged = { [weak self, weak coordinator] layer, state in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self, let coordinator else { return }
                self.isBuffering = state == .preparing || state == .buffering
                self.isPlaying = state.isPlaying
                if state == .readyToPlay {
                    let total = layer.player.duration
                    if total.isFinite, total > 0 {
                        self.duration = total
                        self.clipEndTime = min(total, 30)
                    }
                    if self.pendingCompatibilityStart > 3,
                       self.pendingCompatibilityStart < total - 5 {
                        coordinator.seek(time: self.pendingCompatibilityStart)
                    }
                    coordinator.playbackRate = self.playbackRate
                }
            }
        }
        coordinator.onPlay = { [weak self] current, total in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing else { return }
                if current.isFinite { self.currentTime = current }
                if total.isFinite, total > 0 { self.duration = total }
                self.updateActiveSubtitle(at: current)
                self.saveCurrentProgress()
            }
        }
        coordinator.onFinish = { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.isBuffering = false
                if let error { self.playbackErrorMessage = "视频解码失败：\(error.localizedDescription)" }
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
        if isCompatibilityMode {
            if isPlaying {
                compatibilityCoordinator?.playerLayer?.pause()
                isPlaying = false
            } else {
                compatibilityCoordinator?.playerLayer?.play()
                compatibilityCoordinator?.playbackRate = playbackRate
                isPlaying = true
                resetControlsTimeout()
            }
            return
        }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            player?.volume = volume
            player?.isMuted = false
            player?.play()
            player?.rate = playbackRate
            isPlaying = true
            resetControlsTimeout()
        }
    }

    public func pause() {
        compatibilityCoordinator?.playerLayer?.pause()
        player?.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        if isCompatibilityMode {
            compatibilityCoordinator?.seek(time: clamped)
            currentTime = clamped
            updateActiveSubtitle(at: clamped)
            saveCurrentProgress()
            return
        }
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
        compatibilityCoordinator?.playbackRate = rate
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

    public func generateAISubtitles(
        sourceLanguage: SubtitleSourceLanguage = .automatic,
        targetLanguage: String = "中文 (简体)",
        engine: AISubtitleEngineType = .localWhisperKit,
        offlineModel: OfflineWhisperModel = .highAccuracy,
        translationProvider: SubtitleTranslationProviderType = .apple,
        enhanceWithGPT: Bool = false
    ) {
        guard let url = currentVideoURL else { return }
        _ = SubtitleTaskManager.shared.enqueue(
            videoURL: url,
            videoTitle: url.lastPathComponent,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            engine: engine,
            model: offlineModel,
            translationProvider: translationProvider,
            enhanceWithGPT: enhanceWithGPT,
            isPrivate: currentVideoIsPrivate,
            preferredStartTime: currentTime
        )
        syncGlobalSubtitleTask()
    }

    private func syncGlobalSubtitleTask() {
        guard let url = currentVideoURL else { return }
        if let task = SubtitleTaskManager.shared.task(for: url) {
            isGeneratingSubtitles = task.phase.isActive
            generatingSubtitleStatusText = task.statusText
            subtitleErrorMessage = task.errorMessage
        } else {
            isGeneratingSubtitles = false
        }
        if let lines = SubtitleTaskManager.shared.subtitles(for: url), !lines.isEmpty {
            subtitles = lines
            isAISubtitleEnabled = true
            updateActiveSubtitle(at: currentTime)
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
        cleanupPlaybackEngines(saveProgress: true)
        MediaLibraryManager.shared.reloadLibrary()
        controlsHideTimer?.cancel()
    }

    private func cleanupPlaybackEngines(saveProgress: Bool) {
        if saveProgress { saveCurrentProgress() }
        // 停止 AV1 软解线程并释放解码器上下文
        av1RenderTask?.cancel()
        av1RenderTask = nil
        av1Engine?.close()
        av1Engine = nil
        currentSoftwareFrame = nil

        // 彻底暂停并置空 player，防止后台发声
        let oldPlayer = player
        oldPlayer?.pause()
        if let token = timeObserverToken {
            oldPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        oldPlayer?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        compatibilityCoordinator?.playerLayer?.stop()
        compatibilityCoordinator?.resetPlayer()
        compatibilityCoordinator = nil
        compatibilityOptions = nil
        isCompatibilityMode = false
        pendingCompatibilityStart = 0
        currentTime = 0
        duration = 0
        isBuffering = false
    }
}
