public enum RepeatMode: String, CaseIterable, Sendable, Codable {
    case off, all, one

    /// Off → All (only when there is a queue to repeat) → One → Off.
    public func next(hasQueue: Bool) -> RepeatMode {
        switch self {
        case .off: return hasQueue ? .all : .one
        case .all: return .one
        case .one: return .off
        }
    }

    public var isOn: Bool { self != .off }

    public var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }

    public var symbolName: String { self == .one ? "repeat.1" : "repeat" }
}
