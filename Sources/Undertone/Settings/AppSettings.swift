import Foundation
import Observation
import UndertoneCore

enum GlassStyleChoice: String, CaseIterable, Identifiable {
    case regular, clear
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// The panel's background: real Liquid Glass, or a blurred material as a fallback if glass misbehaves.
enum BackdropChoice: String, CaseIterable, Identifiable {
    case glass, blur
    var id: String { rawValue }
    var label: String { self == .glass ? "Liquid Glass" : "Blur" }
}

struct TintPreset: Identifiable, Hashable {
    let name: String
    let hex: String?
    var id: String { name }

    static let all: [TintPreset] = [
        TintPreset(name: "None", hex: nil),
        TintPreset(name: "Blue", hex: "#3F86E8"),
        TintPreset(name: "Purple", hex: "#8B5CF6"),
        TintPreset(name: "Pink", hex: "#EC5B9B"),
        TintPreset(name: "Red", hex: "#E24C4C"),
        TintPreset(name: "Orange", hex: "#F58A2A"),
        TintPreset(name: "Yellow", hex: "#E8C23A"),
        TintPreset(name: "Green", hex: "#3DAF6B"),
        TintPreset(name: "Teal", hex: "#2FB3B8"),
        TintPreset(name: "Graphite", hex: "#7C7C82"),
    ]
}

/// All persisted preferences. Every write lands in UserDefaults immediately.
@Observable
final class AppSettings {
    private enum Keys {
        static let tintHex = "tintHex"
        static let tintOpacity = "tintOpacity"
        static let glassStyle = "glassStyle"
        static let backdrop = "backdrop"
        static let speed = "speed"
        static let volume = "volume"
        static let recent = "recentLinks"
        static let ytdlpPath = "ytdlpPath"
        static let lastLink = "lastLink"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTint = defaults.string(forKey: Keys.tintHex)
        tintHex = storedTint == nil ? "#3F86E8" : (storedTint!.isEmpty ? nil : storedTint)
        tintOpacity = defaults.object(forKey: Keys.tintOpacity) as? Double ?? 0.45
        glassStyle = GlassStyleChoice(rawValue: defaults.string(forKey: Keys.glassStyle) ?? "") ?? .regular
        backdrop = BackdropChoice(rawValue: defaults.string(forKey: Keys.backdrop) ?? "") ?? .glass
        speed = PlaybackSpeed(rawValue: defaults.double(forKey: Keys.speed)) ?? .normal
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 1.0
        recent = RecentLinksStore(decoding: defaults.data(forKey: Keys.recent) ?? Data())
        ytdlpPathOverride = defaults.string(forKey: Keys.ytdlpPath)
        lastLink = defaults.string(forKey: Keys.lastLink)
    }

    /// `nil` means plain, untinted glass. Stored as "" so the default tint is not re-applied on next launch.
    var tintHex: String? {
        didSet { defaults.set(tintHex ?? "", forKey: Keys.tintHex) }
    }
    var tintOpacity: Double {
        didSet { defaults.set(tintOpacity, forKey: Keys.tintOpacity) }
    }
    var glassStyle: GlassStyleChoice {
        didSet { defaults.set(glassStyle.rawValue, forKey: Keys.glassStyle) }
    }
    var backdrop: BackdropChoice {
        didSet { defaults.set(backdrop.rawValue, forKey: Keys.backdrop) }
    }
    var speed: PlaybackSpeed {
        didSet { defaults.set(speed.rawValue, forKey: Keys.speed) }
    }
    var volume: Double {
        didSet { defaults.set(volume, forKey: Keys.volume) }
    }
    var recent: RecentLinksStore {
        didSet { defaults.set((try? recent.encoded()) ?? Data(), forKey: Keys.recent) }
    }
    var ytdlpPathOverride: String? {
        didSet { defaults.set(ytdlpPathOverride, forKey: Keys.ytdlpPath) }
    }
    var lastLink: String? {
        didSet { defaults.set(lastLink, forKey: Keys.lastLink) }
    }
}
