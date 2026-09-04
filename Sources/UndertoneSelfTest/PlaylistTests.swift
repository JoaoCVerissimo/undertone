import Foundation
import Testing
@testable import UndertoneCore

@Suite struct PlaylistTests {
    @Test func decodesLinesAndSkipsGarbage() {
        let entries = PlaylistEntry.decodeLines(Data(Fixtures.playlistLines.utf8))
        #expect(entries.count == 4)
        #expect(entries[0].title == "Keynote — Blender Conference 2025")
        #expect(entries[0].duration == 1508)
        #expect(entries[0].playlistTitle == "Blender Conference 2025")
        #expect(entries[2].isAvailable == false)
        #expect(entries[3].url.absoluteString == "https://www.youtube.com/watch?v=thirdVideo1")
    }

    @Test func queueSkipsUnavailableAndStartsAtVideo() {
        let entries = PlaylistEntry.decodeLines(Data(Fixtures.playlistLines.utf8))
        var queue = PlayQueue(entries: entries, startVideoID: "hFzg41j68hg")
        #expect(queue.count == 3)
        #expect(queue.title == "Blender Conference 2025")
        #expect(queue.position == 2)
        #expect(queue.current?.id == "hFzg41j68hg")
        #expect(queue.hasNext && queue.hasPrevious)
        #expect(queue.next?.id == "thirdVideo1")
        #expect(queue.advance()?.id == "thirdVideo1")
        #expect(queue.hasNext == false)
        #expect(queue.advance() == nil)
        #expect(queue.goBack()?.id == "hFzg41j68hg")
        queue.jump(to: 0)
        #expect(queue.position == 1)
        queue.jump(to: 99)
        #expect(queue.position == 1)
    }

    @Test func queueStartsAtIndexWhenNoVideo() {
        let entries = PlaylistEntry.decodeLines(Data(Fixtures.playlistLines.utf8))
        #expect(PlayQueue(entries: entries, startIndex: 3).position == 3)
        #expect(PlayQueue(entries: entries, startIndex: 42).position == 1)
        #expect(PlayQueue(entries: entries, startVideoID: "missing", startIndex: 2).position == 2)
        #expect(PlayQueue(entries: []).current == nil)
        #expect(PlayQueue(entries: []).position == 0)
    }
}
