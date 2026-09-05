import Foundation
import Testing
@testable import UndertoneCore

@Suite struct SavedLinksTests {
    @Test func savesNewestFirstDedupedAndToggles() throws {
        var store = SavedLinksStore()
        let a = URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa")!
        let b = URL(string: "https://www.youtube.com/watch?v=bbbbbbbbbbb")!
        store.save(url: a, title: "A", date: Date(timeIntervalSince1970: 1))
        store.save(url: b, title: "B", date: Date(timeIntervalSince1970: 2))
        #expect(store.items.map(\.title) == ["B", "A"])
        #expect(store.contains(a))

        store.save(url: a, title: "A again", date: Date(timeIntervalSince1970: 3))
        #expect(store.items.map(\.title) == ["A again", "B"])

        #expect(store.toggle(url: b, title: "B", date: Date(timeIntervalSince1970: 4)) == false)
        #expect(!store.contains(b))
        #expect(store.toggle(url: b, title: "B back", date: Date(timeIntervalSince1970: 5)) == true)
        #expect(store.items.first?.title == "B back")

        let decoded = SavedLinksStore(decoding: try store.encoded())
        #expect(decoded == store)
        #expect(SavedLinksStore(decoding: Data("nope".utf8)).items.isEmpty)
    }

    @Test func capsAtTheLimit() {
        var store = SavedLinksStore()
        for i in 0..<(SavedLinksStore.limit + 5) {
            store.save(url: URL(string: "https://youtu.be/v\(i)")!, title: "\(i)", date: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(store.items.count == SavedLinksStore.limit)
        #expect(store.items.first?.title == "\(SavedLinksStore.limit + 4)")
        #expect(!store.contains(URL(string: "https://youtu.be/v0")!))
    }
}
