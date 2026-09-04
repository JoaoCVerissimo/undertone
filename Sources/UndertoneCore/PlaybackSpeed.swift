public enum PlaybackSpeed: Double, CaseIterable, Sendable, Identifiable {
    case normal = 1.0
    case faster = 1.5
    case double = 2.0

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .normal: return "1×"
        case .faster: return "1.5×"
        case .double: return "2×"
        }
    }

    /// 1× → 1.5× → 2× → 1×
    public var next: PlaybackSpeed {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}
