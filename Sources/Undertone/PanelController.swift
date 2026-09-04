import AppKit
import KeyboardShortcuts
import SwiftUI
import UndertoneCore

/// Borderless, non-activating panel that can still take keyboard focus (needed for the URL field).
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// UI state shared between the AppKit panel and its SwiftUI content.
@Observable
final class PanelState {
    var showingSettings = false
    var urlText = ""
    /// Incremented on each show so views can react (focus the field, refresh clipboard).
    var showCount = 0
    @ObservationIgnored weak var controller: PanelController?

    func hide() { controller?.hide() }

    /// Offers whatever link is on the clipboard, unless it is what is already playing.
    func prefillFromClipboard(currentLink: String?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Offer the clipboard only when it *is* a link, not when it merely contains one — otherwise a
        // shell command or paragraph with a URL inside it would land in the field. A bare URL has no
        // spaces and no line breaks; anything else is left for the explicit Paste & Play button.
        guard !text.isEmpty, text.count <= 400,
              !text.contains(where: { $0 == " " || $0.isNewline || $0 == "\t" }),
              let link = LinkParser.parse(text), link.isYouTube,
              link.original.absoluteString != currentLink
        else { return }
        urlText = text
    }
}

final class PanelController {
    static let width: CGFloat = 340
    static let cornerRadius: CGFloat = 22

    let state = PanelState()
    private(set) var isVisible = false
    weak var statusButton: NSStatusBarButton?

    private let panel: GlassPanel
    private let hosting: NSHostingView<PanelRoot>
    private let settings: AppSettings
    private let engine: PlayerEngine
    private var glassView: NSGlassEffectView?
    private var contentSize = CGSize(width: PanelController.width, height: 220)
    private var globalMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var spaceObserver: NSObjectProtocol?

    init(settings: AppSettings, engine: PlayerEngine, service: YTDLPService) {
        self.settings = settings
        self.engine = engine
        panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden

        hosting = NSHostingView(rootView: PanelRoot(engine: engine, settings: settings, service: service, state: state))
        hosting.sizingOptions = []
        state.controller = self
        rebuildBackdrop()
        observeSettings()
    }

    // MARK: - Show / hide

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard let button = statusButton else { return }
        if settings.backdrop == .glass { rebuildBackdrop() } // fresh backdrop each time (works around a stale-glass bug seen on 26.2)
        applyAppearance()
        state.showingSettings = false
        state.prefillFromClipboard(currentLink: settings.lastLink)
        if !state.urlText.isEmpty { engine.warm(state.urlText) }
        state.showCount += 1
        position(relativeTo: button)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installMonitors()
        isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() during the fade-out must win; otherwise this would hide the freshly shown panel.
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Called by the SwiftUI root whenever its natural size changes; keeps the top edge anchored under the icon.
    func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        if let button = statusButton, isVisible { position(relativeTo: button) }
        panel.invalidateShadow()
    }

    private func position(relativeTo button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? buttonRect
        var x = buttonRect.midX - contentSize.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - contentSize.width - 8))
        let y = buttonRect.minY - contentSize.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height), display: true)
    }

    // MARK: - Backdrop

    private func rebuildBackdrop() {
        hosting.removeFromSuperview()
        let bounds = NSRect(origin: .zero, size: contentSize)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        switch settings.backdrop {
        case .glass:
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = Self.cornerRadius
            glass.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            panel.contentView = glass
            glassView = glass
        case .blur:
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.cornerRadius
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.addSubview(hosting)
            panel.contentView = blur
            glassView = nil
        }
        applyAppearance()
    }

    private func applyAppearance() {
        if let glass = glassView {
            glass.tintColor = tintColor
            glass.style = settings.glassStyle == .clear ? .clear : .regular
        }
        panel.invalidateShadow()
    }

    private var tintColor: NSColor? {
        guard let hex = settings.tintHex, let color = NSColor(hex: hex) else { return nil }
        return color.withAlphaComponent(settings.tintOpacity)
    }

    private func observeSettings() {
        let backdropBefore = settings.backdrop
        withObservationTracking {
            _ = settings.tintHex
            _ = settings.tintOpacity
            _ = settings.glassStyle
            _ = settings.backdrop
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.settings.backdrop != backdropBefore { self.rebuildBackdrop() } else { self.applyAppearance() }
                self.observeSettings()
            }
        }
    }

    // MARK: - Dismissal and keys

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.hide()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return event }
            if let window = event.window {
                if window == self.panel || window == self.statusButton?.window || window is NSColorPanel { return event }
            }
            self.hide()
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        globalMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
        spaceObserver = nil
    }

    /// Esc closes; ⌘Q quits; ⌘V/⌘C/⌘X/⌘A/⌘Z reach the focused text field even though the app is not active.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window == panel else { return event }
        if event.keyCode == 53 {
            hide()
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        if key == "q" && flags == .command {
            NSApp.terminate(nil)
            return nil
        }
        if isRecorderFocused { return event }
        let selector: Selector? = switch (key, flags) {
        case ("v", .command): #selector(NSText.paste(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        guard let selector else { return event }
        if panel.firstResponder?.tryToPerform(selector, with: nil) == true { return nil }
        return event
    }

    private var isRecorderFocused: Bool {
        if let textView = panel.firstResponder as? NSTextView, let delegate = textView.delegate as AnyObject?, delegate is KeyboardShortcuts.RecorderCocoa { return true }
        return panel.firstResponder is KeyboardShortcuts.RecorderCocoa
    }
}
