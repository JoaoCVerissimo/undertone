import AppKit
import KeyboardShortcuts
import os
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
    /// The tallest the content may be on the current screen; taller pages scroll inside the panel.
    var maxContentHeight: CGFloat = .infinity
    @ObservationIgnored weak var controller: PanelController?

    func hide() { controller?.hide() }

    /// Switches pages with the slide, telling the controller when the exiting page is really gone.
    func showSettings(_ flag: Bool) {
        guard flag != showingSettings else { return }
        controller?.pageTransitionWillStart()
        withAnimation(.snappy(duration: PanelController.pageTransition), completionCriteria: .removed) {
            showingSettings = flag
        } completion: { [weak controller] in
            controller?.pageTransitionEnded()
        }
    }

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
    /// Transparent margin around the glass that holds the soft shadow; the window is that much larger than the content.
    static let shadowInsets = NSEdgeInsets(top: 20, left: 30, bottom: 40, right: 30)

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
    private let log = Logger(subsystem: "com.jverissimo.undertone", category: "panel")
    private var resizeObserver: NSObjectProtocol?
    private var lastSetFrame = NSRect.zero
    private var reapplyingFrame = false
    /// Holds the shadow, surface and SwiftUI views (laid out with constraints). Sized by hand, never by Auto Layout.
    private weak var container: NSView?
    private var frameAnimation: Timer?
    private var pageTransitionActive = false
    private var shrinkAfterTransition = false
    private var transitionFallback: DispatchWorkItem?
    /// Duration of the page slide.
    static let pageTransition: TimeInterval = 0.25

    init(settings: AppSettings, engine: PlayerEngine, service: YTDLPService) {
        self.settings = settings
        self.engine = engine
        panel = GlassPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize(for: contentSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true          // must precede `level`: it resets the level to .floating
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window-server shadow hugs the window's rectangle, not the rounded glass, which showed as a thin box
        // around the corners. PanelShadowView draws one that follows the glass instead.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden

        hosting = NSHostingView(rootView: PanelRoot(engine: engine, settings: settings, service: service, state: state))
        hosting.sizingOptions = []
        state.controller = self
        rebuildBackdrop()
        observeSettings()
        // AppKit may resize the window itself from Auto Layout (`_changeWindowFrameFromConstraintsIfNecessary`) when
        // some required constraint in the content view disagrees with the frame. Nothing here should, but if it ever
        // happens, put the frame back once instead of leaving the panel misplaced.
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lastSetFrame != .zero, !self.reapplyingFrame else { return }
                let frame = self.panel.frame
                guard abs(frame.width - self.lastSetFrame.width) > 1 || abs(frame.height - self.lastSetFrame.height) > 1 else { return }
                self.log.debug("window resized by Auto Layout to \(NSStringFromRect(frame), privacy: .public); restoring \(NSStringFromRect(self.lastSetFrame), privacy: .public)")
                self.reapplyingFrame = true
                DispatchQueue.main.async {
                    self.panel.setFrame(self.lastSetFrame, display: true)
                    self.reapplyingFrame = false
                }
            }
        }
    }

    private func setPanelFrame(_ frame: NSRect) {
        lastSetFrame = frame
        container?.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)
    }

    // MARK: - Show / hide

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show(settings showSettings: Bool = false) {
        guard let button = statusButton else { return }
        let wasVisible = isVisible
        isVisible = true
        if settings.backdrop == .glass { rebuildBackdrop() } else { applyAppearance() }   // rebuild works around a stale-glass bug seen on 26.2
        if wasVisible {
            state.showSettings(showSettings)   // slides, like tapping the gear or Back
        } else {
            // The panel is fading in anyway: switch pages without the slide so the size is right from the first frame.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.showingSettings = showSettings }
        }
        state.prefillFromClipboard(currentLink: settings.lastLink)
        if !state.urlText.isEmpty { engine.warm(state.urlText) }
        state.showCount += 1
        cancelFrameAnimation()
        position(relativeTo: button)
        if wasVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installMonitors()
        engine.setProgressTracking(true)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        engine.setProgressTracking(false)
        removeMonitors()
        cancelFrameAnimation()
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

    /// Called by the SwiftUI root whenever a page's size changes; keeps the top edge anchored under the icon.
    func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        let shrinking = size.height < contentSize.height
        contentSize = size
        cancelFrameAnimation()
        // Growing happens at once so an entering page has room to slide in. Shrinking waits until the exiting page is
        // gone: while it lingers for its slide, its AppKit-backed controls still hold constraints sized for the old
        // height, and Auto Layout resizes the window around them. The glass then contracts with a short animation.
        if shrinking, isVisible, pageTransitionActive {
            shrinkAfterTransition = true
            return
        }
        shrinkAfterTransition = false
        applyContentSize(animated: false)
    }

    func pageTransitionWillStart() {
        pageTransitionActive = true
        transitionFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pageTransitionEnded() }
        }
        transitionFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageTransition + 0.5, execute: fallback)
    }

    func pageTransitionEnded() {
        guard pageTransitionActive else { return }
        pageTransitionActive = false
        transitionFallback?.cancel()
        transitionFallback = nil
        if shrinkAfterTransition {
            shrinkAfterTransition = false
            applyContentSize(animated: isVisible)
        }
    }

    private func cancelFrameAnimation() {
        frameAnimation?.invalidate()
        frameAnimation = nil
    }

    private func applyContentSize(animated: Bool) {
        let target: NSRect
        if let button = statusButton, isVisible, let frame = targetFrame(relativeTo: button) {
            target = frame
        } else {
            let frame = panel.frame
            let windowSize = Self.windowSize(for: contentSize)
            target = NSRect(x: frame.minX, y: frame.maxY - windowSize.height, width: windowSize.width, height: windowSize.height)
        }
        if animated { animateFrame(to: target) } else { setPanelFrame(target) }
    }

    private func animateFrame(to target: NSRect) {
        frameAnimation?.invalidate()
        let start = panel.frame
        guard start != target else { return }
        let duration: TimeInterval = 0.16
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = min(1, (CACurrentMediaTime() - began) / duration)
                let eased = 1 - pow(1 - progress, 3)
                func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * eased).rounded() }
                let frame = NSRect(x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                                   width: mix(start.width, target.width), height: mix(start.height, target.height))
                self.setPanelFrame(progress >= 1 ? target : frame)
                if progress >= 1 { self.cancelFrameAnimation() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameAnimation = timer
    }

    /// Places the glass under the status item, entirely on that screen. Pages taller than the space scroll.
    private func position(relativeTo button: NSStatusBarButton) {
        if let frame = targetFrame(relativeTo: button) { setPanelFrame(frame) }
    }

    private func targetFrame(relativeTo button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = Self.screen(nearest: buttonRect) ?? window.screen ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        // With "Automatically hide and show the menu bar" the status item sits above the screen while the bar is
        // hidden, and visibleFrame then spans the whole screen; keep the glass below where the bar lives either way.
        let barHeight = max(NSApp.mainMenu?.menuBarHeight ?? 0, NSStatusBar.system.thickness)
        let ceiling = min(visible.maxY, screen.frame.maxY - barHeight) - gap
        let top = min(buttonRect.minY - gap, ceiling).rounded(.down)
        let floor = visible.minY + margin
        let maxHeight = max(160, top - floor)
        if state.maxContentHeight != maxHeight { state.maxContentHeight = maxHeight }
        let height = min(contentSize.height, maxHeight).rounded(.up)
        var x = (buttonRect.midX - contentSize.width / 2).rounded()
        x = max(visible.minX + margin, min(x, visible.maxX - contentSize.width - margin))
        let glass = NSRect(x: x, y: top - height, width: contentSize.width, height: height)
        return Self.windowFrame(around: glass)
    }

    private static func screen(nearest rect: NSRect) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        func distance(to frame: NSRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return dx * dx + dy * dy
        }
        return NSScreen.screens.min { distance(to: $0.frame) < distance(to: $1.frame) }
    }

    // MARK: - Geometry

    static func windowSize(for content: CGSize) -> CGSize {
        CGSize(width: content.width.rounded(.up) + shadowInsets.left + shadowInsets.right,
               height: content.height.rounded(.up) + shadowInsets.top + shadowInsets.bottom)
    }

    static func windowFrame(around glass: NSRect) -> NSRect {
        NSRect(x: glass.minX - shadowInsets.left, y: glass.minY - shadowInsets.bottom,
               width: glass.width + shadowInsets.left + shadowInsets.right,
               height: glass.height + shadowInsets.top + shadowInsets.bottom)
    }

    /// The glass rectangle inside a window-sized bounds rect.
    static func glassRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX + shadowInsets.left, y: bounds.minY + shadowInsets.bottom,
               width: bounds.width - shadowInsets.left - shadowInsets.right,
               height: bounds.height - shadowInsets.top - shadowInsets.bottom)
    }

    // MARK: - Backdrop

    private func rebuildBackdrop() {
        hosting.removeFromSuperview()
        // Both NSGlassEffectView and SwiftUI bring Auto Layout into the window, and with it two problems: autoresizing
        // masks get applied twice on every resize, and the glass view's internal content demands (priority 750)
        // outrank the window's size-keeping priority (500), so AppKit resizes the window on its own. So: the window's
        // content view is a plain view with no constraints at all, and the constrained hierarchy lives in a container
        // whose frame we set by hand. Nothing required ever reaches the content view, and the window stays where put.
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.autoresizesSubviews = false
        let container = NSView(frame: root.bounds)
        container.autoresizingMask = []
        root.addSubview(container)
        self.container = container
        let shadow = PanelShadowView(frame: container.bounds, cornerRadius: Self.cornerRadius)
        // The SwiftUI view sits beside the surface, not inside it: `NSGlassEffectView.contentView` takes over its
        // content's layout.
        let surface: NSView
        switch settings.backdrop {
        case .glass:
            let glass = NSGlassEffectView(frame: Self.glassRect(in: container.bounds))
            glass.cornerRadius = Self.cornerRadius
            glassView = glass
            surface = glass
        case .blur:
            let blur = NSVisualEffectView(frame: Self.glassRect(in: container.bounds))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.cornerRadius
            blur.layer?.masksToBounds = true
            glassView = nil
            surface = blur
        }
        for view in [shadow, surface, hosting] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let insets = Self.shadowInsets
        NSLayoutConstraint.activate([
            shadow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shadow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shadow.topAnchor.constraint(equalTo: container.topAnchor),
            shadow.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            surface.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
            hosting.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: surface.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        panel.contentView = root
        applyAppearance()
    }

    private func applyAppearance() {
        if let glass = glassView {
            glass.tintColor = tintColor
            glass.style = settings.glassStyle == .clear ? .clear : .regular
        }
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
                if window == self.panel {
                    // The transparent shadow margin belongs to the window but not to the panel.
                    let bounds = self.panel.contentView?.bounds ?? .zero
                    if !Self.glassRect(in: bounds).contains(event.locationInWindow) { self.hide() }
                    return event
                }
                if window == self.statusButton?.window || window is NSColorPanel { return event }
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
        // Space toggles playback, but never while typing in a text field.
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           !(panel.firstResponder is NSTextView) {
            engine.togglePlayPause()
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

/// A soft shadow that follows the rounded glass. It is cut out under the glass so the backdrop does not sample it,
/// and it never takes clicks.
final class PanelShadowView: NSView {
    private let cornerRadius: CGFloat
    private let maskLayer = CAShapeLayer()
    private var shapedRect = NSRect.null

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        if let layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.42
            layer.shadowRadius = 18
            layer.shadowOffset = CGSize(width: 0, height: -8)
            maskLayer.fillRule = .evenOdd
            layer.mask = maskLayer
        }
        updatePaths()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    override func layout() {
        super.layout()
        updatePaths()
    }

    private func updatePaths() {
        let glass = PanelController.glassRect(in: bounds)
        guard glass != shapedRect, glass.width > 0, glass.height > 0, let layer else { return }
        shapedRect = glass
        let rounded = CGPath(roundedRect: glass, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(rounded)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = rounded
        maskLayer.frame = bounds
        maskLayer.path = outside
        CATransaction.commit()
    }
}
