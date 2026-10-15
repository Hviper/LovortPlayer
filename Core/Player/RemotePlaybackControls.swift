#if os(iOS)
import Foundation
import MediaPlayer

@MainActor
final class RemotePlaybackControls {
    private weak var player: PlayerViewModel?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var title = ""
    private var lastUpdate = Date.distantPast

    func attach(to player: PlayerViewModel, title: String) {
        clear()
        self.player = player
        self.title = title
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { [weak player] in player?.togglePlayPauseIfPaused() }
        register(center.pauseCommand) { [weak player] in player?.pause() }
        register(center.togglePlayPauseCommand) { [weak player] in player?.togglePlayPause() }
        register(center.skipForwardCommand) { [weak player] in player?.fastForward(by: 10) }
        register(center.skipBackwardCommand) { [weak player] in player?.rewind(by: 10) }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in player?.seek(to: event.positionTime) }
            return .success
        }
        commandTargets.append((center.changePlaybackPositionCommand, seekTarget))
        update(force: true)
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let token = command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
        commandTargets.append((command, token))
    }

    func update(force: Bool = false) {
        guard let player else { return }
        if !force && Date().timeIntervalSince(lastUpdate) < 1 { return }
        lastUpdate = Date()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: max(0, player.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? player.playbackRate : 0
        ]
    }

    func clear() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player = nil
        title = ""
    }
}
#endif
