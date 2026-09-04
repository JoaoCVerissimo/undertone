import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePlayPause = Self("togglePlayPause", initial: .init(.p, modifiers: [.control, .option]))
    static let cycleSpeed = Self("cycleSpeed", initial: .init(.s, modifiers: [.control, .option]))
    static let togglePanel = Self("togglePanel", initial: .init(.y, modifiers: [.control, .option]))
    static let nextTrack = Self("nextTrack", initial: .init(.rightArrow, modifiers: [.control, .option]))
    static let previousTrack = Self("previousTrack", initial: .init(.leftArrow, modifiers: [.control, .option]))
}

enum Hotkeys {
    static func install(engine: PlayerEngine, panel: PanelController) {
        KeyboardShortcuts.onKeyUp(for: .togglePlayPause) { engine.togglePlayPause() }
        KeyboardShortcuts.onKeyUp(for: .cycleSpeed) { engine.cycleSpeed() }
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { panel.toggle() }
        KeyboardShortcuts.onKeyUp(for: .nextTrack) { engine.next() }
        KeyboardShortcuts.onKeyUp(for: .previousTrack) { engine.previous() }
    }
}
