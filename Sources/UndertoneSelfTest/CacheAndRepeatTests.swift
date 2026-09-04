import Foundation
import Testing
@testable import UndertoneCore

@Suite struct StreamCacheTests {
    let now = Date(timeIntervalSince1970: 1_788_500_000)

    func track(_ id: String, expiresIn seconds: TimeInterval?) -> Track {
        Track(id: id, title: "T \(id)", streamURL: URL(string: "https://example.com/\(id)")!,
              expiresAt: seconds.map { now.addingTimeInterval($0) }, extractor: seconds == nil ? "soundcloud" : "youtube")
    }

    @Test func hitMissAndExpiry() {
        var cache = StreamCache()
        cache.store(track("a", expiresIn: 6 * 3600), forKey: "a", now: now)
        #expect(cache.track(forKey: "a", now: now)?.id == "a")
        #expect(cache.track(forKey: "missing", now: now) == nil)
        // Inside the safety margin counts as expired.
        #expect(cache.track(forKey: "a", now: now.addingTimeInterval(6 * 3600 - 5 * 60)) == nil)
        #expect(cache.contains("a", now: now.addingTimeInterval(3600)))
        // No explicit expiry: default lifetime applies.
        cache.store(track("s", expiresIn: nil), forKey: "s", now: now)
        #expect(cache.contains("s", now: now.addingTimeInterval(30 * 60)))
        #expect(!cache.contains("s", now: now.addingTimeInterval(61 * 60)))
    }

    @Test func pruneRemoveAndLimit() {
        var cache = StreamCache()
        cache.store(track("old", expiresIn: 60), forKey: "old", now: now)
        cache.store(track("new", expiresIn: 6 * 3600), forKey: "new", now: now.addingTimeInterval(1))
        cache.prune(now: now.addingTimeInterval(120))
        #expect(cache.count == 1)
        #expect(cache.entries["new"] != nil)
        cache.remove(forKey: "new")
        #expect(cache.count == 0)

        for i in 0..<(StreamCache.limit + 10) {
            cache.store(track("v\(i)", expiresIn: 6 * 3600), forKey: "v\(i)", now: now.addingTimeInterval(Double(i)))
        }
        #expect(cache.count == StreamCache.limit)
        #expect(cache.entries["v0"] == nil, "oldest evicted first")
        #expect(cache.entries["v\(StreamCache.limit + 9)"] != nil)
    }

    @Test func roundTripsThroughJSON() throws {
        var cache = StreamCache()
        var t = track("rt", expiresIn: 3600)
        t.httpHeaders = ["User-Agent": "ua"]
        t.channel = "Chan"
        t.duration = 123
        cache.store(t, forKey: "rt", now: now)
        let decoded = StreamCache(decoding: try cache.encoded())
        #expect(decoded == cache)
        #expect(decoded.track(forKey: "rt", now: now)?.channel == "Chan")
        #expect(StreamCache(decoding: Data("nope".utf8)).count == 0)
    }

    @Test func cacheKeys() {
        #expect(LinkParser.parse("https://youtu.be/dQw4w9WgXcQ?t=5")?.cacheKey == "dQw4w9WgXcQ")
        #expect(LinkParser.parse("https://soundcloud.com/a/b")?.cacheKey == "https://soundcloud.com/a/b")
        #expect(LinkParser.parse("https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=RDaqz-KE-bpKQ")?.cacheKey == "aqz-KE-bpKQ")
    }
}

@Suite struct RepeatModeTests {
    @Test func cyclesWithAndWithoutQueue() {
        #expect(RepeatMode.off.next(hasQueue: true) == .all)
        #expect(RepeatMode.all.next(hasQueue: true) == .one)
        #expect(RepeatMode.one.next(hasQueue: true) == .off)
        #expect(RepeatMode.off.next(hasQueue: false) == .one)
        #expect(RepeatMode.one.next(hasQueue: false) == .off)
        #expect(RepeatMode.one.symbolName == "repeat.1")
        #expect(RepeatMode.all.symbolName == "repeat")
        #expect(!RepeatMode.off.isOn && RepeatMode.all.isOn)
    }
}
