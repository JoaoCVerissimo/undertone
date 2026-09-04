import Foundation
import Testing
@testable import UndertoneCore

@Suite struct TrackTests {
    @Test func decodesRealOutput() throws {
        let track = try Track.decode(fromYTDLPJSON: Data(Fixtures.videoJSON.utf8))
        #expect(track.id == "aqz-KE-bpKQ")
        #expect(track.title.hasPrefix("Big Buck Bunny"))
        #expect(track.channel == "Blender")
        #expect(track.duration == 635)
        #expect(track.streamExtension == "m4a")
        #expect(track.audioCodec == "mp4a.40.2")
        #expect(track.streamURL.host() == "rr3---sn-h5qzen7s.googlevideo.com")
        #expect(track.userAgent?.hasPrefix("Mozilla/5.0") == true)
        #expect(track.isYouTube)
        #expect(track.artworkURL?.absoluteString == "https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg")
        #expect(track.expiresAt == Date(timeIntervalSince1970: 1788564066))
    }

    @Test func expiryIsCheckedWithMargin() throws {
        let track = try Track.decode(fromYTDLPJSON: Data(Fixtures.videoJSON.utf8))
        let expiry = Date(timeIntervalSince1970: 1788564066)
        #expect(!track.isExpired(at: expiry.addingTimeInterval(-3600)))
        #expect(track.isExpired(at: expiry.addingTimeInterval(-60)))
        #expect(track.isExpired(at: expiry.addingTimeInterval(10)))
        var noExpiry = track
        noExpiry.expiresAt = nil
        #expect(!noExpiry.isExpired())
    }

    @Test func missingURLIsInvalidOutput() {
        #expect(throws: YTDLPFailure.invalidOutput) {
            try Track.decode(fromYTDLPJSON: Data("{\"id\": \"x\", \"title\": \"t\"}".utf8))
        }
        #expect(throws: YTDLPFailure.invalidOutput) {
            try Track.decode(fromYTDLPJSON: Data("nope".utf8))
        }
    }

    @Test func nonYouTubeUsesSiteThumbnail() {
        let track = Track(id: "abc", title: "t", thumbnailURL: URL(string: "https://example.com/t.jpg"), streamURL: URL(string: "https://example.com/a.mp3")!, extractor: "soundcloud")
        #expect(track.artworkURL?.absoluteString == "https://example.com/t.jpg")
        #expect(track.expiresAt == nil)
    }
}
