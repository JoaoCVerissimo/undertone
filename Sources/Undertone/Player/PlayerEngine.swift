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
            persistVolumeTask?.cancel()
            persistVolumeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.settings.volume = Double(self.volume)
            }
        }
    }

    /// The player's real position right now. `currentTime` is only kept fresh while the panel is visible.
    var livePosition: Double {
        guard player.currentItem != nil else { return currentTime }
        let t = player.currentTime()
        return t.isNumeric ? t.seconds : currentTime
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
    /// Speculative resolves (clipboard warm-up, next playlist entry) keyed by cache key. A user resolve
    /// for the same link joins the in-flight task instead of spawning a second yt-dlp.
    @ObservationIgnored private var backgroundResolves: [String: Task<Track?, Never>] = [:]
    @ObservationIgnored private var backgroundOwners: [String: Int] = [:]
    @ObservationIgnored private var backgroundGeneration = 0
    /// Queue index a navigation is heading for while its resolve is in flight (committed in `load`).
    @ObservationIgnored private var pendingQueueTarget: Int?
    @ObservationIgnored private var consecutiveQueueSkips = 0
    @ObservationIgnored private var currentLink: MediaLink?
    @ObservationIgnored private var pastedLink: MediaLink?
    @ObservationIgnored private var recoveryAttempts = 0
    @ObservationIgnored private var lastLoadedKey: String?
    @ObservationIgnored private var progressTracking = false
    @ObservationIgnored private var idleUnloadTask: Task<Void, Never>?
    @ObservationIgnored private var isIdleUnloaded = false
    @ObservationIgnored private var persistVolumeTask: Task<Void, Never>?
    @ObservationIgnored private var stateSyncTask: Task<Void, Never>?
    @ObservationIgnored private var failedWarmKeys: [String: Date] = [:]
    /// Unavailable playlist entries skipped in a row before giving up (avoids marching through a dead playlist).
    static let maxConsecutiveSkips = 5
    /// Automatic re-resolves (expired URL, failed item) allowed per loaded track before giving up.
    static let maxRecoveries = 2
    // After `settings.idleUnloadSeconds` paused (default 10 min), the media pipeline is released so a
    // forgotten Undertone costs nothing.

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

        playerStateTask = Task { [weak self] in
            guard let player = self?.player else { return }
            for await _ in player.publisher(for: \.timeControlStatus).values {
                guard let self else { return }
                self.syncPlaybackState()
            }
        }
    }

    // MARK: - Saved links

    /// The playing track as a plain video link, so a song heard in a Mix or playlist can be kept on its own.
    var savableTrack: (url: URL, title: String)? {
        guard let track else { return nil }
        let url = track.webpageURL ?? URL(string: "https://www.youtube.com/watch?v=\(track.id)")!
        return (url, track.title)
    }

    /// The pasted playlist or Mix, while one is loaded.
    var savableQueue: (url: URL, title: String)? {
        guard let queue, let pastedLink else { return nil }
        return (pastedLink.resolvedURL, queue.title ?? "Playlist")
    }

    var isMixLoaded: Bool {
        if queue != nil, case .mix = pastedLink?.kind { return true }
        return false
    }

    var isTrackSaved: Bool { savableTrack.map { settings.saved.contains($0.url) } ?? false }
    var isQueueSaved: Bool { savableQueue.map { settings.saved.contains($0.url) } ?? false }

    func toggleSavedTrack() {
        guard let item = savableTrack else { return }
        settings.saved.toggle(url: item.url, title: item.title)
    }

    func toggleSavedQueue() {
        guard let item = savableQueue else { return }
        settings.saved.toggle(url: item.url, title: item.title)
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
        cancelBackgroundResolves(except: link.cacheKey)   // a warm-up/prefetch for anything else is wasted work now
        clearError()
        notice = nil
        pastedLink = link
        settings.lastLink = link.original.absoluteString
        log.notice("open \(link.original.absoluteString, privacy: .public)")

        if case .mix = link.kind {
            openPlaylist(link, limit: Self.mixLimit)
        } else if link.isPlaylist {
            openPlaylist(link)
        } else {
            queue = nil
            resolveAndPlay(link, startAt: link.startTime)
        }
    }

    /// A Mix is endless; this many entries become the queue (about three hours, listed in a few seconds).
    static let mixLimit = 50

    private func openPlaylist(_ link: MediaLink, limit: Int = 500) {
        var isMix = false
        if case .mix = link.kind { isMix = true }
        isResolving = true
        resolvingTitle = isMix ? "Loading mix…" : "Loading playlist…"
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = await self.service.readyClient() else { self.handle(YTDLPFailure.notInstalled); return }
                let entries: [PlaylistEntry]
                do {
                    entries = try await client.playlistEntries(link, limit: limit)
                } catch where isMix && !Task.isCancelled {
                    // Listing a Mix can fail where the video itself plays fine; keep the music going.
                    self.notice = "Couldn't load the Mix, so just this video plays."
                    self.resolveAndPlay(MediaLink(original: link.original, kind: .video(id: link.videoID ?? "")), startAt: link.startTime)
                    return
                }
                guard !Task.isCancelled else { return }
                // YouTube has Mixes only for some videos (mostly music). Without one, yt-dlp hands back the video itself.
                if isMix, entries.count <= 1, let seed = link.videoID {
                    self.notice = "YouTube has no Mix for this video, so just this video plays."
                    self.resolveAndPlay(MediaLink(original: link.original, kind: .video(id: seed)), startAt: link.startTime)
                    return
                }
                var startVideo = link.videoID   // a Mix starts from the video it was built on
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
                self.settings.recent.record(url: link.resolvedURL, title: queue.title ?? "Playlist")
                self.resolveAndPlay(first.link, startAt: link.startTime)
            } catch {
                self.handle(error)
            }
        }
    }

    /// - Parameter queueTarget: the queue index this link belongs to. It is committed only once the track
    ///   loads, so a failed or cancelled Next/Previous leaves the queue and the playing track untouched.
    private func resolveAndPlay(_ link: MediaLink, startAt: Double? = nil, queueTarget: Int? = nil) {
        resolveTask?.cancel()
        let key = link.cacheKey

        if let cached = settings.streamCache.track(forKey: key) {
            log.notice("cache hit \(key, privacy: .public)")
            load(cached, link: link, startAt: startAt, queueTarget: queueTarget)
            return
        }

        isResolving = true
        pendingQueueTarget = queueTarget
        if let queueTarget, let q = queue, q.entries.indices.contains(queueTarget) {
            resolvingTitle = q.entries[queueTarget].title
        } else {
            resolvingTitle = queue?.current?.title ?? "Resolving…"
        }
        let inFlight = backgroundResolves[key]
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                var track: Track?
                if let inFlight {
                    track = await inFlight.value   // a warm-up or prefetch is already fetching this one
                }
                if track == nil {
                    guard let client = await self.service.readyClient() else { self.handle(YTDLPFailure.notInstalled); return }
                    track = try await client.resolve(link)
                }
                guard let track, !Task.isCancelled else { return }
                self.settings.streamCache.store(track, forKey: key)
                self.load(track, link: link, startAt: startAt, queueTarget: queueTarget)
            } catch {
                self.handle(error)
            }
        }
    }

    /// Resolves a pasted/clipboard link in the background so pressing Play afterwards is instant.
    /// Debounced, deduplicated by cache key, and invisible to the UI.
    func warm(_ text: String) {
        // Only complete YouTube video links: a partially typed URL must not spawn yt-dlp on every pause.
        guard let link = LinkParser.parse(text), link.videoID != nil, !link.isPlaylist else { return }
        let key = link.cacheKey
        guard key != track?.id else { return }
        // A link that just failed (a private video on the clipboard) is not retried on every panel open.
        if let failedAt = failedWarmKeys[key], Date().timeIntervalSince(failedAt) < 10 * 60 { return }
        backgroundResolve(link, delay: .milliseconds(700), isWarmUp: true)
    }

    /// One speculative yt-dlp at a time, never started beside a user resolve, cached on success.
    private func backgroundResolve(_ link: MediaLink, delay: Duration, isWarmUp: Bool) {
        let key = link.cacheKey
        guard backgroundResolves[key] == nil, backgroundResolves.isEmpty, !isResolving,
              !settings.streamCache.contains(key), let client = service.client else { return }
        backgroundGeneration += 1
        let generation = backgroundGeneration
        backgroundOwners[key] = generation
        backgroundResolves[key] = Task { [weak self] in
            defer {
                if self?.backgroundOwners[key] == generation {
                    self?.backgroundResolves[key] = nil
                    self?.backgroundOwners[key] = nil
                }
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self?.isResolving == false else { return nil }
            guard let track = try? await client.resolve(link), !Task.isCancelled else {
                if !Task.isCancelled, isWarmUp { self?.failedWarmKeys[key] = Date() }
                return nil
            }
            self?.settings.streamCache.store(track, forKey: key)
            self?.log.notice("\(isWarmUp ? "warmed" : "prefetched", privacy: .public) \(key, privacy: .public)")
            return track
        }
    }

    private func cancelBackgroundResolves(except keep: String? = nil) {
        for (key, task) in backgroundResolves where key != keep {
            task.cancel()
            backgroundResolves[key] = nil
            backgroundOwners[key] = nil
        }
    }

    private func load(_ track: Track, link: MediaLink, startAt: Double?, queueTarget: Int?) {
        teardownItem()
        idleUnloadTask?.cancel()
        isIdleUnloaded = false
        if lastLoadedKey != link.cacheKey {
            recoveryAttempts = 0            // a genuinely new track gets a fresh recovery budget
            lastLoadedKey = link.cacheKey
        }
        currentLink = link
        pendingQueueTarget = nil
        consecutiveQueueSkips = 0
        if let queueTarget, var q = queue {
            q.jump(to: queueTarget)
            queue = q
        }
        self.track = track
        hasEnded = false
        isResolving = false
        resolvingTitle = nil
        currentTime = startAt ?? 0
        log.notice("loaded \(track.title, privacy: .public) [\(track.streamExtension ?? "?", privacy: .public) \(track.audioCodec ?? "?", privacy: .public)] duration \(track.duration ?? -1)")

        var options: [String: Any] = [:]
        if let userAgent = track.userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        let asset = AVURLAsset(url: track.streamURL, options: options)
        let item = AVPlayerItem(asset: asset)
        // Measured on an M1: the pitch algorithm makes no CPU difference at 2× (spectral 4.5% vs timeDomain
        // 4.4% of one core; decoding twice the samples dominates), so keep the higher-quality one.
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

        if queue == nil, let pastedLink {
            settings.recent.record(url: pastedLink.resolvedURL, title: track.title)
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
            if playing {
                idleUnloadTask?.cancel()
                idleUnloadTask = nil
            } else if track != nil, !isIdleUnloaded {
                scheduleIdleUnload()
            }
        }
        if buffering != isBuffering { isBuffering = buffering }
    }

    /// KVO on `timeControlStatus` is the primary signal; this catches up shortly after our own transport
    /// calls in case a change is coalesced, without any periodic timer.
    private func scheduleStateSync() {
        stateSyncTask?.cancel()
        stateSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.syncPlaybackState()
        }
    }

    /// The scrubber needs a 2 Hz clock only while the panel is visible. Hidden (the usual state for a
    /// background player) nothing ticks and nothing re-renders.
    func setProgressTracking(_ enabled: Bool) {
        guard enabled != progressTracking else { return }
        progressTracking = enabled
        if enabled {
            currentTime = livePosition
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, time.isNumeric else { return }
                    self.currentTime = time.seconds
                    self.syncPlaybackState()
                }
            }
        } else if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = max(30, settings.idleUnloadSeconds)
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isPlaying, self.track != nil, !self.isIdleUnloaded else { return }
            self.unloadForIdle()
        }
    }

    /// Releases the AVPlayerItem after a long pause: no buffering, no media pipeline, back to idle memory.
    /// Track, queue and position stay; Play rebuilds it (instant on a cache hit).
    private func unloadForIdle() {
        let position = livePosition
        teardownItem()
        player.replaceCurrentItem(with: nil)
        currentTime = position
        isIdleUnloaded = true
        log.notice("idle: released the player item after a long pause at \(Int(position))s")
    }

    // MARK: - Transport

    func play() {
        guard let track else {
            // Nothing loaded: replay the last link, unless a resolve is already in flight (a media-key
            // Play during the first resolve must not kill and re-spawn yt-dlp).
            if !isResolving, let last = settings.lastLink { open(last) }
            return
        }
        if isIdleUnloaded, let link = currentLink {
            isIdleUnloaded = false
            if hasEnded { hasEnded = false; currentTime = 0 }
            resolveAndPlay(link, startAt: currentTime)   // cache hit → instant; expired → re-resolve
            return
        }
        if track.isExpired(), let link = currentLink {
            guard recoveryAttempts < Self.maxRecoveries else {
                fail("The stream expired and could not be refreshed.", suggestion: "Paste the link again.")
                return
            }
            recoveryAttempts += 1
            log.notice("stream expired; re-resolving")
            settings.streamCache.remove(forKey: link.cacheKey)
            resolveAndPlay(link, startAt: livePosition)
            return
        }
        if hasEnded {
            hasEnded = false
            currentTime = 0
            player.seek(to: .zero)
        }
        player.defaultRate = Float(speed.rawValue)
        player.play()
        scheduleStateSync()
    }

    func pause() {
        player.pause()
        scheduleStateSync()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func setSpeed(_ newSpeed: PlaybackSpeed) {
        speed = newSpeed
        settings.speed = newSpeed
        player.defaultRate = Float(newSpeed.rawValue)
        if isPlaying { player.rate = Float(newSpeed.rawValue) }
        scheduleStateSync()
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
        if !isIdleUnloaded {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        seekGeneration += 1
    }

    func skip(by delta: Double) {
        seek(to: livePosition + delta)
    }

    func next() {
        guard let q = queue else { return }
        // Step from the entry we are heading for, so Next after a failed or still-resolving entry moves on.
        let target = (pendingQueueTarget ?? q.index) + 1
        guard q.entries.indices.contains(target) else { return }
        resolveAndPlay(q.entries[target].link, queueTarget: target)
    }

    func previous() {
        guard let q = queue else {
            seek(to: 0)
            return
        }
        if pendingQueueTarget == nil, livePosition > 3 {
            seek(to: 0)
            return
        }
        let target = (pendingQueueTarget ?? q.index) - 1
        guard q.entries.indices.contains(target) else {
            seek(to: 0)
            return
        }
        resolveAndPlay(q.entries[target].link, queueTarget: target)
    }

    func cancelResolving() {
        resolveTask?.cancel()
        resolveTask = nil
        pendingQueueTarget = nil
        isResolving = false
        resolvingTitle = nil
    }

    func stop() {
        resolveTask?.cancel()
        cancelBackgroundResolves()
        pendingQueueTarget = nil
        idleUnloadTask?.cancel()
        isIdleUnloaded = false
        failedWarmKeys.removeAll()
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
            if let q = queue, !q.isEmpty {
                let target = q.hasNext ? q.index + 1 : 0
                resolveAndPlay(q.entries[target].link, queueTarget: target)
            } else {
                restartCurrentTrack()
            }
        case .off:
            if let q = queue, q.hasNext {
                let target = q.index + 1
                resolveAndPlay(q.entries[target].link, queueTarget: target)
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
        scheduleStateSync()
    }

    private func itemFailed(_ error: Error?) {
        let description = error?.localizedDescription ?? "unknown error"
        log.error("item failed: \(description, privacy: .public)")
        if recoveryAttempts < Self.maxRecoveries, let link = currentLink {
            recoveryAttempts += 1
            settings.streamCache.remove(forKey: link.cacheKey)
            let position = livePosition
            resolveAndPlay(link, startAt: position > 1 ? position : nil)
        } else {
            fail("Playback failed: \(description)", suggestion: "Try again. If it keeps failing: brew upgrade yt-dlp")
        }
    }

    private func prefetchNext() {
        guard let nextEntry = queue?.next else { return }
        backgroundResolve(nextEntry.link, delay: .seconds(2), isWarmUp: false)
    }

    private func handle(_ error: Error) {
        // A resolve cancelled by a newer one (Next pressed twice, a new link pasted) must not touch the
        // state the newer one just set. cancelResolving() resets the flags itself for the explicit case.
        if error is CancellationError || (error as? YTDLPFailure) == .cancelled { return }
        isResolving = false
        resolvingTitle = nil
        // A removed/private video mid-playlist must not stop the playlist: skip forward (bounded).
        if let failedTarget = pendingQueueTarget, let q = queue, failedTarget >= q.index,
           case .unavailable? = error as? YTDLPFailure,
           consecutiveQueueSkips < Self.maxConsecutiveSkips, q.entries.indices.contains(failedTarget + 1) {
            consecutiveQueueSkips += 1
            notice = "Skipped an unavailable video in the playlist."
            log.notice("skipping unavailable playlist entry \(failedTarget + 1)")
            resolveAndPlay(q.entries[failedTarget + 1].link, queueTarget: failedTarget + 1)
            return
        }
        if let failure = error as? YTDLPFailure {
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
