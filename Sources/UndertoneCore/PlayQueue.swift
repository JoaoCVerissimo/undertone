import Foundation

/// An ordered playlist with a cursor. Pure value type; the engine owns the resolving/playing.
public struct PlayQueue: Equatable, Sendable {
    public private(set) var entries: [PlaylistEntry]
    public private(set) var index: Int
    public let title: String?

    /// - Parameters:
    ///   - startVideoID: the `v=` of the pasted link, if any.
    ///   - startIndex: the 1-based `index=` of the pasted link, used when the video id is absent.
    public init(entries: [PlaylistEntry], title: String? = nil, startVideoID: String? = nil, startIndex: Int? = nil) {
        let playable = entries.filter(\.isAvailable)
        self.entries = playable
        self.title = title ?? entries.first?.playlistTitle
        if let startVideoID, let i = playable.firstIndex(where: { $0.id == startVideoID }) {
            index = i
        } else if let startIndex, startIndex >= 1, startIndex <= playable.count {
            index = startIndex - 1
        } else {
            index = 0
        }
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    /// 1-based, for display.
    public var position: Int { entries.isEmpty ? 0 : index + 1 }
    public var current: PlaylistEntry? { entries.indices.contains(index) ? entries[index] : nil }
    public var hasNext: Bool { index + 1 < entries.count }
    public var hasPrevious: Bool { index > 0 }
    public var next: PlaylistEntry? { hasNext ? entries[index + 1] : nil }

    @discardableResult
    public mutating func advance() -> PlaylistEntry? {
        guard hasNext else { return nil }
        index += 1
        return current
    }

    @discardableResult
    public mutating func goBack() -> PlaylistEntry? {
        guard hasPrevious else { return nil }
        index -= 1
        return current
    }

    public mutating func jump(to position: Int) {
        guard entries.indices.contains(position) else { return }
        index = position
    }
}
