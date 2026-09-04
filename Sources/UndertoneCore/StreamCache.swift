import Foundation

/// Resolved streams keyed by video id (or URL for other sites), kept until YouTube's `expire=` deadline.
/// A cache hit skips yt-dlp entirely, which is the difference between ~5 s and instant when replaying.
public struct StreamCache: Equatable, Sendable {
    public static let limit = 60
    /// Streams without an explicit expiry (non-YouTube sites) are trusted for this long.
    public static let defaultLifetime: TimeInterval = 60 * 60
    /// Entries this close to expiry count as expired, so playback never starts on a URL about to die.
    public static let safetyMargin: TimeInterval = 10 * 60

    public struct Entry: Codable, Equatable, Sendable {
        public let track: Track
        public let storedAt: Date
    }

    public private(set) var entries: [String: Entry]

    public init() {
        entries = [:]
    }

    public init(decoding data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entries)
    }

    public var count: Int { entries.count }

    public func track(forKey key: String, now: Date = Date()) -> Track? {
        guard let entry = entries[key], Self.isFresh(entry, now: now) else { return nil }
        return entry.track
    }

    public func contains(_ key: String, now: Date = Date()) -> Bool {
        track(forKey: key, now: now) != nil
    }

    public mutating func store(_ track: Track, forKey key: String, now: Date = Date()) {
        prune(now: now)
        entries[key] = Entry(track: track, storedAt: now)
        if entries.count > Self.limit {
            let excess = entries.count - Self.limit
            for (key, _) in entries.sorted(by: { $0.value.storedAt < $1.value.storedAt }).prefix(excess) {
                entries.removeValue(forKey: key)
            }
        }
    }

    public mutating func remove(forKey key: String) {
        entries.removeValue(forKey: key)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { Self.isFresh($0.value, now: now) }
    }

    static func isFresh(_ entry: Entry, now: Date) -> Bool {
        if let expiresAt = entry.track.expiresAt {
            return now.addingTimeInterval(Self.safetyMargin) < expiresAt
        }
        return now.timeIntervalSince(entry.storedAt) < Self.defaultLifetime
    }
}
