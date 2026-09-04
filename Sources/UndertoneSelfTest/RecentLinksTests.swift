import Foundation
import Testing
@testable import UndertoneCore

@Suite struct RecentLinksTests {
    @Test func recordsMostRecentFirstDedupedAndCapped() throws {
        var store = RecentLinksStore()
        for i in 0..<12 {
            store.record(url: URL(string: "https://youtu.be/v\(i)")!, title: "Video \(i)", date: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(store.items.count == RecentLinksStore.limit)
        #expect(store.items.first?.title == "Video 11")
        #expect(store.items.last?.title == "Video 2")

        store.record(url: URL(string: "https://youtu.be/v5")!, title: "Video 5 again", date: Date(timeIntervalSince1970: 100))
        #expect(store.items.count == RecentLinksStore.limit)
        #expect(store.items.first?.title == "Video 5 again")
        #expect(store.items.filter { $0.url.absoluteString == "https://youtu.be/v5" }.count == 1)

        let data = try store.encoded()
        let decoded = RecentLinksStore(decoding: data)
        #expect(decoded == store)

        store.remove(URL(string: "https://youtu.be/v5")!)
        #expect(store.items.first?.title == "Video 11")
        store.clear()
        #expect(store.items.isEmpty)
        #expect(RecentLinksStore(decoding: Data("garbage".utf8)).items.isEmpty)
    }
}
