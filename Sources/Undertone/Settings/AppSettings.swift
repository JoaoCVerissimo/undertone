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
        static let saved = "savedLinks"
        static let ytdlpPath = "ytdlpPath"
        static let lastLink = "lastLink"
        static let repeatMode = "repeatMode"
        static let showTitle = "showTitleInMenuBar"
        static let streamCache = "streamCache"
        static let ytdlpCachedPath = "ytdlpCachedPath"
        static let ytdlpCachedDeno = "ytdlpCachedDeno"
        static let ytdlpCachedVersion = "ytdlpCachedVersion"
        static let ytdlpProbedAt = "ytdlpProbedAt"
        static let idleUnloadSeconds = "idleUnloadSeconds"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var persistCacheTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTint = defaults.string(forKey: Keys.tintHex)
        tintHex = storedTint == nil ? DefaultAppearance.tintHex : (storedTint!.isEmpty ? nil : storedTint)
        tintOpacity = defaults.object(forKey: Keys.tintOpacity) as? Double ?? DefaultAppearance.tintOpacity
        glassStyle = GlassStyleChoice(rawValue: defaults.string(forKey: Keys.glassStyle) ?? "") ?? DefaultAppearance.glassStyle
        backdrop = BackdropChoice(rawValue: defaults.string(forKey: Keys.backdrop) ?? "") ?? DefaultAppearance.backdrop
        speed = PlaybackSpeed(rawValue: defaults.double(forKey: Keys.speed)) ?? .normal
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 1.0
        recent = RecentLinksStore(decoding: defaults.data(forKey: Keys.recent) ?? Data())
        saved = SavedLinksStore(decoding: defaults.data(forKey: Keys.saved) ?? Data())
        ytdlpPathOverride = defaults.string(forKey: Keys.ytdlpPath)
        lastLink = defaults.string(forKey: Keys.lastLink)
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        showTitleInMenuBar = defaults.bool(forKey: Keys.showTitle)
        streamCache = StreamCache(decoding: defaults.data(forKey: Keys.streamCache) ?? Data())
        ytdlpCachedPath = defaults.string(forKey: Keys.ytdlpCachedPath)
        ytdlpCachedDeno = defaults.string(forKey: Keys.ytdlpCachedDeno)
        ytdlpCachedVersion = defaults.string(forKey: Keys.ytdlpCachedVersion)
        ytdlpProbedAt = defaults.object(forKey: Keys.ytdlpProbedAt) as? Date
        idleUnloadSeconds = defaults.object(forKey: Keys.idleUnloadSeconds) as? Double ?? 10 * 60
    }

    /// The look Undertone ships with: the Blue preset at medium intensity on regular Liquid Glass.
    enum DefaultAppearance {
        static let tintHex: String? = "#3F86E8"
        static let tintOpacity = 0.45
        static let glassStyle = GlassStyleChoice.regular
        static let backdrop = BackdropChoice.glass
    }

    var isDefaultAppearance: Bool {
        tintHex == DefaultAppearance.tintHex && abs(tintOpacity - DefaultAppearance.tintOpacity) < 0.001
            && glassStyle == DefaultAppearance.glassStyle && backdrop == DefaultAppearance.backdrop
    }

    func resetAppearance() {
        tintHex = DefaultAppearance.tintHex
        tintOpacity = DefaultAppearance.tintOpacity
        glassStyle = DefaultAppearance.glassStyle
        backdrop = DefaultAppearance.backdrop
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
    var saved: SavedLinksStore {
        didSet { defaults.set((try? saved.encoded()) ?? Data(), forKey: Keys.saved) }
    }
    var ytdlpPathOverride: String? {
        didSet { defaults.set(ytdlpPathOverride, forKey: Keys.ytdlpPath) }
    }
    var lastLink: String? {
        didSet { defaults.set(lastLink, forKey: Keys.lastLink) }
    }
    var repeatMode: RepeatMode {
        didSet { defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode) }
    }
    var showTitleInMenuBar: Bool {
        didSet { defaults.set(showTitleInMenuBar, forKey: Keys.showTitle) }
    }
    /// Resolved streams survive relaunches (they stay valid for ~6 h), so recent replays are instant.
    /// The blob is re-encoded on a short debounce, not on every mutation (stores come in bursts).
    var streamCache: StreamCache {
        didSet {
            persistCacheTask?.cancel()
            persistCacheTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.flushStreamCache()
            }
        }
    }

    /// Writes any pending stream-cache change immediately (called on quit).
    func flushStreamCache() {
        persistCacheTask?.cancel()
        defaults.set((try? streamCache.encoded()) ?? Data(), forKey: Keys.streamCache)
    }
    /// Last successful yt-dlp probe, so a normal launch spawns no processes at all.
    var ytdlpCachedPath: String? {
        didSet { defaults.set(ytdlpCachedPath, forKey: Keys.ytdlpCachedPath) }
    }
    var ytdlpCachedDeno: String? {
        didSet { defaults.set(ytdlpCachedDeno, forKey: Keys.ytdlpCachedDeno) }
    }
    var ytdlpCachedVersion: String? {
        didSet { defaults.set(ytdlpCachedVersion, forKey: Keys.ytdlpCachedVersion) }
    }
    var ytdlpProbedAt: Date? {
        didSet { defaults.set(ytdlpProbedAt, forKey: Keys.ytdlpProbedAt) }
    }
    /// How long a paused track sits before the media pipeline is released (`defaults write … idleUnloadSeconds`).
    var idleUnloadSeconds: Double {
        didSet { defaults.set(idleUnloadSeconds, forKey: Keys.idleUnloadSeconds) }
    }
}
