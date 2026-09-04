import Foundation

public struct RecentLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public let url: URL
    public var title: String
    public var lastPlayed: Date

    public init(url: URL, title: String, lastPlayed: Date) {
        self.url = url
        self.title = title
        self.lastPlayed = lastPlayed
    }
}

/// Most-recent-first list of played links, capped at `limit`.
public struct RecentLinksStore: Equatable, Sendable {
    public static let limit = 10
    public private(set) var items: [RecentLink]

    public init(items: [RecentLink] = []) {
        self.items = Array(items.prefix(Self.limit))
    }

    public init(decoding data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.init(items: (try? decoder.decode([RecentLink].self, from: data)) ?? [])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(items)
    }

    public mutating func record(url: URL, title: String, date: Date = Date()) {
        items.removeAll { $0.url == url }
        items.insert(RecentLink(url: url, title: title, lastPlayed: date), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(_ url: URL) {
        items.removeAll { $0.url == url }
    }

    public mutating func clear() {
        items.removeAll()
    }
}
