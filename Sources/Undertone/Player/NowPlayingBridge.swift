import AppKit
import MediaPlayer
import UndertoneCore

/// Publishes the current track to macOS (Control Center, Now Playing, AirPods) and routes media keys back to the engine.
final class NowPlayingBridge {
    private let engine: PlayerEngine
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var artwork: MPMediaItemArtwork?
    private var artworkTrackID: String?

    init(engine: PlayerEngine) {
        self.engine = engine
        registerCommands()
        observe()
    }

    private func registerCommands() {
        commands.playCommand.addTarget { [weak self] _ in self?.engine.play(); return .success }
        commands.pauseCommand.addTarget { [weak self] _ in self?.engine.pause(); return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.engine.togglePlayPause(); return .success }
        commands.stopCommand.addTarget { [weak self] _ in self?.engine.pause(); return .success }

        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.engine.skip(by: interval)
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            self?.engine.skip(by: -interval)
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.engine.seek(to: event.positionTime)
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.engine.queue?.hasNext == true else { return .noSuchContent }
            self.engine.next()
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.engine.queue?.hasPrevious == true else { return .noSuchContent }
            self.engine.previous()
            return .success
        }
        commands.changePlaybackRateCommand.supportedPlaybackRates = PlaybackSpeed.allCases.map { NSNumber(value: $0.rawValue) }
        commands.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent,
                  let speed = PlaybackSpeed(rawValue: Double(event.playbackRate)) else { return .commandFailed }
            self?.engine.setSpeed(speed)
            return .success
        }
    }

    /// Re-arms itself after each change; only the properties read here trigger refreshes.
    private func observe() {
        withObservationTracking {
            _ = engine.track
            _ = engine.isPlaying
            _ = engine.isBuffering
            _ = engine.speed
            _ = engine.seekGeneration
            _ = engine.queue?.index
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    func refresh() {
        guard let track = engine.track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.livePosition,
            MPNowPlayingInfoPropertyPlaybackRate: (engine.isPlaying && !engine.isBuffering) ? engine.speed.rawValue : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: engine.speed.rawValue,
        ]
        if let channel = track.channel { info[MPMediaItemPropertyArtist] = channel }
        if let duration = engine.duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let queue = engine.queue {
            if let title = queue.title { info[MPMediaItemPropertyAlbumTitle] = title }
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queue.index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        if let artwork, artworkTrackID == track.id {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(for: track)
        }
        center.nowPlayingInfo = info
        center.playbackState = engine.isPlaying ? .playing : .paused
        commands.nextTrackCommand.isEnabled = engine.queue?.hasNext ?? false
        commands.previousTrackCommand.isEnabled = engine.queue?.hasPrevious ?? false
    }

    private func loadArtwork(for track: Track) {
        guard let url = track.artworkURL, artworkTrackID != track.id else { return }
        artworkTrackID = track.id
        artwork = nil
        Task { [weak self] in
            guard let image = await ArtworkLoader.shared.image(for: url) else { return }
            guard let self, self.engine.track?.id == track.id else { return }
            // MediaPlayer calls this on its own queue: it must not inherit main-actor isolation.
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            self.refresh()
        }
    }
}
