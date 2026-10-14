import AVFoundation
import KSPlayer

@MainActor
protocol PlaybackDriving: AnyObject {
    func play(rate: Float, volume: Float)
    func pause()
    func seek(to seconds: Double)
}

@MainActor
final class NativePlaybackDriver: PlaybackDriving {
    private let player: AVPlayer
    init(_ player: AVPlayer) { self.player = player }
    func play(rate: Float, volume: Float) { player.volume = volume; player.isMuted = false; player.play(); player.rate = rate }
    func pause() { player.pause() }
    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
}

@MainActor
final class CompatiblePlaybackDriver: PlaybackDriving {
    private let coordinator: KSVideoPlayer.Coordinator
    init(_ coordinator: KSVideoPlayer.Coordinator) { self.coordinator = coordinator }
    func play(rate: Float, volume: Float) { coordinator.playerLayer?.player.playbackVolume = volume; coordinator.playbackRate = rate; coordinator.playerLayer?.play() }
    func pause() { coordinator.playerLayer?.pause() }
    func seek(to seconds: Double) { coordinator.seek(time: seconds) }
}
