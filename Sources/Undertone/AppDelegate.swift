import AppKit
import UndertoneCore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var service: YTDLPService!
    private var engine: PlayerEngine!
    private var nowPlaying: NowPlayingBridge!
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private let log = Logger(subsystem: "com.jverissimo.undertone", category: "app")

    private var pendingURLs: [URL] = []
    private var isReady = false

    // Set up in *will*FinishLaunching: Launch Services can deliver `application(_:open:)` before didFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        settings = AppSettings()
        service = YTDLPService(settings: settings)
        engine = PlayerEngine(settings: settings, service: service)
        nowPlaying = NowPlayingBridge(engine: engine)
        panel = PanelController(settings: settings, engine: engine, service: service)
        statusItem = StatusItemController(engine: engine, panel: panel, settings: settings)
        Hotkeys.install(engine: engine, panel: panel)
        service.start()
        isReady = true
        log.notice("launched from \(Bundle.main.bundleURL.path, privacy: .public)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued { handle(url) }
    }

    /// `undertone://play?url=…` `play` `pause` `toggle` `next` `previous` `seek?to=90` `speed?value=2`
    /// `volume?value=0.5` `mute` `repeat?mode=one` `save` `open` `settings` `close` `quit`
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReady else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "undertone", let engine, let panel else { return }
        log.notice("url \(url.absoluteString, privacy: .public)")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host() {
        case "play":
            if let target = query.first(where: { $0.name == "url" })?.value, !target.isEmpty {
                engine.open(target)
            } else {
                engine.play()
            }
        case "pause": engine.pause()
        case "toggle": engine.togglePlayPause()
        case "next": engine.next()
        case "previous": engine.previous()
        case "speed":
            if let raw = query.first(where: { $0.name == "value" })?.value, let value = Double(raw), let speed = PlaybackSpeed(rawValue: value) {
                engine.setSpeed(speed)
            } else {
                engine.cycleSpeed()
            }
        case "seek":
            if let raw = query.first(where: { $0.name == "to" })?.value, let seconds = Double(raw) { engine.seek(to: seconds) }
        case "volume":
            if let raw = query.first(where: { $0.name == "value" })?.value, let value = Float(raw) { engine.setVolume(value) }
        case "mute": engine.toggleMute()
        case "repeat":
            if let raw = query.first(where: { $0.name == "mode" })?.value, let mode = RepeatMode(rawValue: raw) {
                engine.setRepeatMode(mode)
            } else {
                engine.cycleRepeatMode()
            }
        case "save": engine.toggleSavedTrack()
        case "open": panel.show()
        case "settings": panel.show(settings: true)
        case "close": panel.hide()
        case "quit": NSApp.terminate(nil)
        default: log.notice("unknown URL \(url.absoluteString, privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
        settings.flushStreamCache()
    }
}
