import Foundation
import AVFoundation
import Combine

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
    public var subtitles: [SubtitleLine] = []
    
    // 无损剪辑模式
    @Published public var isClipMode: Bool = false
    @Published public var clipStartTime: TimeInterval = 0
    @Published public var clipEndTime: TimeInterval = 0

    private var timeObserverToken: Any?
    private var controlsHideTimer: Task<Void, Never>?

    public init() {}

    public func loadVideo(url: URL) {
        let playerItem = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: playerItem)
        setupTimeObserver()
        resetControlsTimeout()
        
        Task {
            if let durationCM = try? await playerItem.asset.load(.duration) {
                let seconds = CMTimeGetSeconds(durationCM)
                if seconds.isFinite {
                    self.duration = seconds
                    self.clipEndTime = min(seconds, 30.0)
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

    public func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateActiveSubtitle(at: time)
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
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isScrubbing else { return }
                let current = CMTimeGetSeconds(time)
                self.currentTime = current
                self.updateActiveSubtitle(at: current)
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
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        controlsHideTimer?.cancel()
    }
}

