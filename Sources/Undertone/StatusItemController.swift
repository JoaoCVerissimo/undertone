import AppKit
import UndertoneCore

/// The menu bar icon. Left click toggles the panel, right click shows a small menu.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let engine: PlayerEngine
    private let panel: PanelController
    private let settings: AppSettings
    private var scrollMonitor: Any?
    private var flashTask: Task<Void, Never>?
    private var flashText: String?
    private var iconCache: [String: NSImage] = [:]

    init(engine: PlayerEngine, panel: PanelController, settings: AppSettings) {
        self.engine = engine
        self.panel = panel
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Undertone"
            button.font = NSFont.menuBarFont(ofSize: 0)
        }
        panel.statusButton = statusItem.button
        updateIcon()
        observe()
        installScrollVolume()
    }

    /// Scrolling over the menu bar icon adjusts the volume; swipe/roll up = louder, regardless of the
    /// "natural scrolling" setting. Shows the level briefly next to the icon.
    private func installScrollVolume() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window == button.window else { return event }
            // Trackpad momentum would keep changing the volume after the fingers lift.
            guard event.momentumPhase.isEmpty else { return nil }
            let raw = event.scrollingDeltaY
            guard raw != 0 else { return event }
            let up = event.isDirectionInvertedFromDevice ? -raw : raw
            let step = event.hasPreciseScrollingDeltas ? up / 100 : up / 8
            self.engine.setVolume(self.engine.volume + Float(step))
            self.flash("\(Int((self.engine.volume * 100).rounded()))%")
            return nil
        }
    }

    private func flash(_ text: String) {
        flashText = text
        updateIcon()
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.flashText = nil
            self.updateIcon()
        }
    }

    @objc private func clicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    private func showMenu() {
        panel.hide()
        let menu = NSMenu()
        if let track = engine.track {
            let title = NSMenuItem(title: track.title, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let playPause = NSMenuItem(title: engine.isPlaying ? "Pause" : "Play", action: #selector(togglePlayPause), keyEquivalent: "")
        playPause.target = self
        playPause.isEnabled = engine.track != nil || settings.lastLink != nil
        menu.addItem(playPause)
        if engine.queue?.hasNext == true {
            let next = NSMenuItem(title: "Next", action: #selector(nextTrack), keyEquivalent: "")
            next.target = self
            menu.addItem(next)
        }
        let open = NSMenuItem(title: "Open Undertone", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Undertone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePlayPause() { engine.togglePlayPause() }
    @objc private func nextTrack() { engine.next() }
    @objc private func openPanel() { panel.show() }

    private func observe() {
        withObservationTracking {
            _ = engine.isPlaying
            _ = engine.isResolving
            _ = engine.track
            _ = settings.showTitleInMenuBar
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateIcon()
                self.observe()
            }
        }
    }

    private func updateIcon() {
        let name: String
        if engine.isResolving {
            name = "circle.dotted"
        } else if engine.isPlaying {
            name = "waveform"
        } else if engine.track != nil {
            name = "play.circle.fill"
        } else {
            name = "play.circle"
        }
        let image = icon(named: name)
        if statusItem.button?.image !== image { statusItem.button?.image = image }

        var title = ""
        if let flashText {
            title = flashText
        } else if settings.showTitleInMenuBar, let track = engine.track {
            title = Self.truncated(track.title, to: 30)
        }
        // Setting these unconditionally relayouts the whole menu bar; only touch them on a real change.
        let newTitle = title.isEmpty ? "" : " " + title
        let newLength = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        if statusItem.length != newLength { statusItem.length = newLength }
        if statusItem.button?.title != newTitle {
            statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            statusItem.button?.title = newTitle
        }
    }

    /// Symbol images are built once; the scroll-wheel volume readout would otherwise create one per tick.
    private func icon(named name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Undertone")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        iconCache[name] = image
        return image
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
