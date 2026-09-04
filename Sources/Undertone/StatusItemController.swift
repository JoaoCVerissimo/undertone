import AppKit
import UndertoneCore

/// The menu bar icon. Left click toggles the panel, right click shows a small menu.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let engine: PlayerEngine
    private let panel: PanelController
    private let settings: AppSettings

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
        }
        panel.statusButton = statusItem.button
        updateIcon()
        observe()
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
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Undertone")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}
