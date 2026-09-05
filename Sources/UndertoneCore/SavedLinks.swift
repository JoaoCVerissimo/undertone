import Foundation

public struct SavedLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public let url: URL
    public var title: String
    public var savedAt: Date

    public init(url: URL, title: String, savedAt: Date) {
        self.url = url
        self.title = title
        self.savedAt = savedAt
    }
}

/// Links the user chose to keep, newest first. Unlike recents these never expire; only the user removes them.
public struct SavedLinksStore: Equatable, Sendable {
    public static let limit = 500
    public private(set) var items: [SavedLink]

    public init(items: [SavedLink] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    public init(decoding data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.init(items: (try? decoder.decode([SavedLink].self, from: data)) ?? [])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(items)
    }

    public func contains(_ url: URL) -> Bool {
        items.contains { $0.url == url }
    }

    /// Saves (or re-saves, moving it to the front with a fresh title) a link.
    public mutating func save(url: URL, title: String, date: Date = Date()) {
        items.removeAll { $0.url == url }
        items.insert(SavedLink(url: url, title: title, savedAt: date), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(_ url: URL) {
        items.removeAll { $0.url == url }
    }

    /// Saves the link when it is not saved yet, removes it otherwise. Returns whether it is saved afterwards.
    @discardableResult
    public mutating func toggle(url: URL, title: String, date: Date = Date()) -> Bool {
        if contains(url) {
            remove(url)
            return false
        }
        save(url: url, title: title, date: date)
        return true
    }
}
