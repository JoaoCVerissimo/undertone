import AVFoundation
import Combine
import Foundation
import Observation
import UndertoneCore
import os

/// Owns the AVPlayer and the current track/queue. Audio only: no AVPlayerLayer is ever attached.
@Observable
final class PlayerEngine {
    private(set) var track: Track?
    private(set) var queue: PlayQueue?
    private(set) var isResolving = false
    private(set) var resolvingTitle: String?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var hasEnded = false
    private(set) var currentTime: Double = 0
    /// Bumped on every seek so observers (Now Playing) resync their elapsed time.
    private(set) var seekGeneration = 0
    private(set) var speed: PlaybackSpeed
    private(set) var repeatMode: RepeatMode
    private(set) var isMuted = false
    private(set) var errorMessage: String?
    private(set) var errorSuggestion: String?
    private(set) var notice: String?

    var volume: Float {
        didSet {
            player.volume = isMuted ? 0 : volume
            settings.volume = Double(volume)
        }
    }

    /// What the slider shows: 0 while muted.
    var effectiveVolume: Float { isMuted ? 0 : volume }

    var volumeSymbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// yt-dlp's duration wins: AVFoundation reports double the real length for YouTube's m4a streams.
    var duration: Double? {
        if let d = track?.duration, d > 0 { return d }
        guard let t = player.currentItem?.duration, t.isNumeric, t.seconds.isFinite, t.seconds > 0 else { return nil }
        return t.seconds
    }

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let service: YTDLPService
    @ObservationIgnored private let log = Logger(subsystem: "com.jverissimo.undertone", category: "player")
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var playerStateTask: Task<Void, Never>?
    @ObservationIgnored private var itemStatusTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var warmTask: Task<Track?, Never>?
    @ObservationIgnored private var warmKey: String?
    @ObservationIgnored private var currentLink: MediaLink?
    @ObservationIgnored private var pastedURL: URL?
    @ObservationIgnored private var recoveredOnce = false

    init(settings: AppSettings, service: YTDLPService) {
        self.settings = settings
        self.service = service
        speed = settings.speed
        repeatMode = settings.repeatMode
        volume = Float(settings.volume)
        player.volume = volume
        player.defaultRate = Float(speed.rawValue)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.currentTime = time.seconds
                self.syncPlaybackState()
            }
        }
        playerStateTask = Task { [weak self] in
            guard let player = self?.player else { return }
            for await _ in player.publisher(for: \.timeControlStatus).values {
                guard let self else { return }
                self.syncPlaybackState()
            }
        }
    }

    // MARK: - Opening links

    func open(_ text: String) {
        guard let link = LinkParser.parse(text) else {
            fail("That doesn't look like a link.", suggestion: "Paste a YouTube video or playlist URL.")
            return
        }
        open(link)
    }

    func open(_ link: MediaLink) {
        resolveTask?.cancel()
        prefetchTask?.cancel()
        clearError()
        notice = nil
        pastedURL = link.original
        settings.lastLink = link.original.absoluteString
        settings.recent.record(url: link.original, title: link.original.host() ?? link.original.absoluteString)
        log.notice("open \(link.original.absoluteString, privacy: .public)")

        if case .mix = link.kind {
            notice = "YouTube mixes can't be listed, so just this video will play."
        }
        if link.isPlaylist {
            openPlaylist(link)
        } else {
            queue = nil
            resolveAndPlay(link, startAt: link.startTime)
        }
    }

    private func openPlaylist(_ link: MediaLink) {
        isResolving = true
        resolvingTitle = "Loading playlist…"
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = await self.service.readyClient() else { self.handle(YTDLPFailure.notInstalled); return }
                let entries = try await client.playlistEntries(link)
                guard !Task.isCancelled else { return }
                var startVideo: String?
                var startIndex: Int?
                if case .playlist(_, let v, let i) = link.kind {
                    startVideo = v
                    startIndex = i
                }
                let queue = PlayQueue(entries: entries, startVideoID: startVideo, startIndex: startIndex)
                guard let first = queue.current else {
                    throw YTDLPFailure.unavailable(message: "No playable videos in that playlist.")
                }
                self.queue = queue
                if let pastedURL = self.pastedURL {
                    self.settings.recent.record(url: pastedURL, title: queue.title ?? "Playlist")
                }
                self.resolveAndPlay(first.link, startAt: link.startTime)
            } catch {
                self.handle(error)
            }
        }
    }

    private func resolveAndPlay(_ link: MediaLink, startAt: Double? = nil) {
        resolveTask?.cancel()
        currentLink = link
        let key = link.cacheKey

        if let cached = settings.streamCache.track(forKey: key) {
            log.notice("cache hit \(key, privacy: .public)")
            load(cached, startAt: startAt)
            return
        }

        isResolving = true
        resolvingTitle = queue?.current?.title ?? "Resolving…"
        let pendingWarmUp: Task<Track?, Never>? = (warmKey == key) ? warmTask : nil
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                var track: Track?
                if let pendingWarmUp {
                    track = await pendingWarmUp.value   // the clipboard warm-up is already fetching this one
                }
                if track == nil {
                    guard let client = await self.service.readyClient() else { self.handle(YTDLPFailure.notInstalled); return }
                    track = try await client.resolve(link)
                }
                guard let track, !Task.isCancelled else { return }
                self.settings.streamCache.store(track, forKey: key)
                self.load(track, startAt: startAt)
            } catch {
                self.handle(error)
            }
        }
    }

    /// Resolves a pasted/clipboard link in the background so pressing Play afterwards is instant.
    /// Debounced, deduplicated by cache key, and invisible to the UI.
    func warm(_ text: String) {
        guard let link = LinkParser.parse(text), !link.isPlaylist, let client = service.client else { return }
        let key = link.cacheKey
        guard key != track?.id, !settings.streamCache.contains(key), warmKey != key else { return }
        warmTask?.cancel()
        warmKey = key
        warmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let track = try? await client.resolve(link), !Task.isCancelled else {
                if self?.warmKey == key { self?.warmKey = nil }
                return nil
            }
            self?.settings.streamCache.store(track, forKey: key)
            if self?.warmKey == key { self?.warmKey = nil }
            self?.log.notice("warmed \(key, privacy: .public)")
            return track
        }
    }

    private func load(_ track: Track, startAt: Double?) {
        teardownItem()
        self.track = track
        recoveredOnce = false
        hasEnded = false
        isResolving = false
        resolvingTitle = nil
        currentTime = startAt ?? 0
        log.notice("loaded \(track.title, privacy: .public) [\(track.streamExtension ?? "?", privacy: .public) \(track.audioCodec ?? "?", privacy: .public)] duration \(track.duration ?? -1)")

        var options: [String: Any] = [:]
        if let userAgent = track.userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        let asset = AVURLAsset(url: track.streamURL, options: options)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        if let d = track.duration, d > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: d, preferredTimescale: 600)
        }
        observe(item)
        player.replaceCurrentItem(with: item)
        if let startAt, startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        play()

        if queue == nil, let pastedURL {
            settings.recent.record(url: pastedURL, title: track.title)
        }
        prefetchNext()
    }

    private func observe(_ item: AVPlayerItem) {
        itemStatusTask = Task { [weak self] in
            for await status in item.publisher(for: \.status).values {
                guard let self else { return }
                if status == .failed { self.itemFailed(item.error) }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
    }

    private func teardownItem() {
        itemStatusTask?.cancel()
        itemStatusTask = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// Derives the published flags from the player. Called from KVO and from the periodic timer as a safety net.
    private func syncPlaybackState() {
        let status = player.timeControlStatus
        let playing = status != .paused
        let buffering = status == .waitingToPlayAtSpecifiedRate
        if playing != isPlaying {
            isPlaying = playing
            log.notice("playback \(playing ? "playing" : "paused", privacy: .public) rate \(self.player.rate)")
        }
        if buffering != isBuffering { isBuffering = buffering }
    }

    // MARK: - Transport

    func play() {
        guard let track else {
            if let last = settings.lastLink { open(last) }
            return
        }
        if track.isExpired(), let link = currentLink {
            log.notice("stream expired; re-resolving")
            settings.streamCache.remove(forKey: link.cacheKey)
            resolveAndPlay(link, startAt: currentTime)
            return
        }
        if hasEnded {
            hasEnded = false
            currentTime = 0
            player.seek(to: .zero)
        }
        player.defaultRate = Float(speed.rawValue)
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func setSpeed(_ newSpeed: PlaybackSpeed) {
        speed = newSpeed
        settings.speed = newSpeed
        player.defaultRate = Float(newSpeed.rawValue)
        if isPlaying { player.rate = Float(newSpeed.rawValue) }
    }

    func cycleSpeed() {
        setSpeed(speed.next)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        settings.repeatMode = mode
    }

    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next(hasQueue: queue != nil))
    }

    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        if isMuted, clamped > 0 { isMuted = false }
        volume = clamped
    }

    func toggleMute() {
        isMuted.toggle()
        player.volume = isMuted ? 0 : volume
    }

    func seek(to seconds: Double) {
        guard track != nil else { return }
        let upper = (duration ?? .infinity) - 0.25
        let target = max(0, min(seconds, upper))
        currentTime = target
        hasEnded = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        seekGeneration += 1
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func next() {
        guard var q = queue, q.hasNext else { return }
        q.advance()
        queue = q
        if let entry = q.current { resolveAndPlay(entry.link) }
    }

    func previous() {
        if currentTime > 3 || queue?.hasPrevious != true {
            seek(to: 0)
            return
        }
        guard var q = queue else { return }
        q.goBack()
        queue = q
        if let entry = q.current { resolveAndPlay(entry.link) }
    }

    func cancelResolving() {
        resolveTask?.cancel()
        resolveTask = nil
        isResolving = false
        resolvingTitle = nil
    }

    func stop() {
        resolveTask?.cancel()
        prefetchTask?.cancel()
        warmTask?.cancel()
        warmKey = nil
        teardownItem()
        player.pause()
        player.replaceCurrentItem(with: nil)
        track = nil
        queue = nil
        currentLink = nil
        isResolving = false
        resolvingTitle = nil
        hasEnded = false
        currentTime = 0
    }

    func shutdown() {
        stop()
        playerStateTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    func clearError() {
        errorMessage = nil
        errorSuggestion = nil
    }

    func clearNotice() {
        notice = nil
    }

    // MARK: - Events

    private func trackEnded() {
        log.notice("ended \(self.track?.title ?? "", privacy: .public) repeat=\(self.repeatMode.rawValue, privacy: .public)")
        switch repeatMode {
        case .one:
            restartCurrentTrack()
        case .all:
            if var q = queue {
                if q.hasNext { q.advance() } else { q.jump(to: 0) }
                queue = q
                if let entry = q.current { resolveAndPlay(entry.link) }
            } else {
                restartCurrentTrack()
            }
        case .off:
            if var q = queue, q.hasNext {
                q.advance()
                queue = q
                if let entry = q.current { resolveAndPlay(entry.link) }
            } else {
                hasEnded = true
                if let d = duration { currentTime = d }
            }
        }
    }

    private func restartCurrentTrack() {
        hasEnded = false
        currentTime = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.defaultRate = Float(speed.rawValue)
        player.play()
        seekGeneration += 1
    }

    private func itemFailed(_ error: Error?) {
        let description = error?.localizedDescription ?? "unknown error"
        log.error("item failed: \(description, privacy: .public)")
        if !recoveredOnce, let link = currentLink {
            recoveredOnce = true
            settings.streamCache.remove(forKey: link.cacheKey)
            let position = currentTime
            resolveAndPlay(link, startAt: position > 1 ? position : nil)
        } else {
            fail("Playback failed: \(description)", suggestion: "Try again. If it keeps failing: brew upgrade yt-dlp")
        }
    }

    private func prefetchNext() {
        prefetchTask?.cancel()
        guard let nextEntry = queue?.next, let client = service.client else { return }
        let key = nextEntry.link.cacheKey
        guard !settings.streamCache.contains(key) else { return }
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let track = try? await client.resolve(nextEntry.link), !Task.isCancelled else { return }
            self?.settings.streamCache.store(track, forKey: key)
        }
    }

    private func handle(_ error: Error) {
        isResolving = false
        resolvingTitle = nil
        if error is CancellationError { return }
        if let failure = error as? YTDLPFailure {
            if failure == .cancelled { return }
            fail(failure.message, suggestion: failure.suggestion)
        } else {
            fail(error.localizedDescription, suggestion: nil)
        }
    }

    private func fail(_ message: String, suggestion: String?) {
        errorMessage = message
        errorSuggestion = suggestion
        log.error("\(message, privacy: .public)")
    }
}
