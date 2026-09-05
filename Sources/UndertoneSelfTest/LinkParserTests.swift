import Foundation
import Testing
@testable import UndertoneCore

@Suite struct LinkParserTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc",
        "https://youtu.be/dQw4w9WgXcQ?si=xyz",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "youtube.com/watch?v=dQw4w9WgXcQ",
        "youtu.be/dQw4w9WgXcQ",
        "  check this out https://youtu.be/dQw4w9WgXcQ !! ",
        "<https://www.youtube.com/watch?v=dQw4w9WgXcQ>",
    ])
    func parsesVideoLinks(_ text: String) {
        let link = LinkParser.parse(text)
        #expect(link?.videoID == "dQw4w9WgXcQ")
        #expect(link?.isYouTube == true)
        #expect(link?.resolvedURL.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        if case .video = link?.kind {} else { Issue.record("expected .video, got \(String(describing: link?.kind))") }
    }

    @Test func parsesStartTime() {
        #expect(LinkParser.parse("https://youtu.be/dQw4w9WgXcQ?t=90")?.startTime == 90)
        #expect(LinkParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s")?.startTime == 90)
        #expect(LinkParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s")?.startTime == 3723)
        #expect(LinkParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&start=15")?.startTime == 15)
        #expect(LinkParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.startTime == nil)
    }

    @Test func parsesPlaylists() throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd"))
        #expect(link.playlistID == "PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd")
        #expect(link.videoID == nil)
        #expect(link.resolvedURL.absoluteString == "https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd")

        let withVideo = try #require(LinkParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd&index=3"))
        guard case .playlist(let id, let startVideo, let startIndex) = withVideo.kind else {
            Issue.record("expected .playlist"); return
        }
        #expect(id == "PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd")
        #expect(startVideo == "dQw4w9WgXcQ")
        #expect(startIndex == 3)
    }

    @Test func personalMixesStayMixes() throws {
        for list in ["RDaqz-KE-bpKQ", "RDAMVMaqz-KE-bpKQ", "RDMM", "ULaqz-KE-bpKQ"] {
            let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=\(list)&start_radio=1"))
            #expect(link.kind == .mix(videoID: "aqz-KE-bpKQ", listID: list), "\(list)")
        }
    }

    @Test func youTubeMusicCuratedListsArePlaylists() throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/playlist?list=RDCLAK5uy_kmPRjHDECIcuVwnKsx2Ng7fyNgFKWNJFs"))
        #expect(link.playlistID == "RDCLAK5uy_kmPRjHDECIcuVwnKsx2Ng7fyNgFKWNJFs")
    }

    @Test func playlistRadiosPlayTheUnderlyingPlaylist() throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=RDAMPLPLwclSMR0kf70IL1wXYjBl2LVjmTaYq6CV"))
        guard case .playlist(let id, let start, _) = link.kind else { Issue.record("expected .playlist"); return }
        #expect(id == "PLwclSMR0kf70IL1wXYjBl2LVjmTaYq6CV")
        #expect(start == "aqz-KE-bpKQ")
    }

    @Test func mixesKeepTheirListForYTDLP() throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=RDaqz-KE-bpKQ"))
        #expect(link.kind == .mix(videoID: "aqz-KE-bpKQ", listID: "RDaqz-KE-bpKQ"))
        #expect(link.resolvedURL.absoluteString == "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=RDaqz-KE-bpKQ")
        #expect(link.cacheKey == "aqz-KE-bpKQ")
        #expect(!link.isPlaylist)
        #expect(link.isPlaylist == false)
    }

    @Test func otherSitesPassThrough() throws {
        let link = try #require(LinkParser.parse("https://soundcloud.com/artist/track"))
        #expect(link.kind == .other)
        #expect(link.isYouTube == false)
        #expect(link.resolvedURL.absoluteString == "https://soundcloud.com/artist/track")
    }

    @Test(arguments: ["", "   ", "hello world", "ftp://youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/watch?v=tooshort", "not a url at all"])
    func rejectsGarbage(_ text: String) {
        let link = LinkParser.parse(text)
        #expect(link == nil || link?.videoID == nil)
        if text.hasPrefix("ftp") || text.isEmpty || text == "   " || text == "hello world" || text == "not a url at all" {
            #expect(link == nil)
        }
    }

    @Test func timestampParsing() {
        #expect(LinkParser.parseTimestamp("90") == 90)
        #expect(LinkParser.parseTimestamp("90s") == 90)
        #expect(LinkParser.parseTimestamp("2m") == 120)
        #expect(LinkParser.parseTimestamp("1h") == 3600)
        #expect(LinkParser.parseTimestamp("abc") == nil)
        #expect(LinkParser.parseTimestamp("-5") == nil)
    }
}
