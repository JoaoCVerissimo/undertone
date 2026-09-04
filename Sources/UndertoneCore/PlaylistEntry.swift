import Foundation

/// One line of `yt-dlp --flat-playlist -j` output.
public struct PlaylistEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let duration: Double?
    public let url: URL
    public let channel: String?
    public let playlistTitle: String?
    public let playlistID: String?

    public init(id: String, title: String, duration: Double? = nil, url: URL, channel: String? = nil,
                playlistTitle: String? = nil, playlistID: String? = nil) {
        self.id = id
        self.title = title
        self.duration = duration
        self.url = url
        self.channel = channel
        self.playlistTitle = playlistTitle
        self.playlistID = playlistID
    }

    /// Private/deleted videos are listed by YouTube with placeholder titles and no duration.
    public var isAvailable: Bool {
        !(title == "[Private video]" || title == "[Deleted video]" || title == "[Unavailable video]")
    }

    public var link: MediaLink { MediaLink(original: url, kind: .video(id: id)) }

    /// Decodes newline-delimited JSON. Skips malformed lines rather than failing the whole playlist.
    public static func decodeLines(_ data: Data) -> [PlaylistEntry] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line -> PlaylistEntry? in
            guard let raw = try? decoder.decode(RawEntry.self, from: Data(line)) else { return nil }
            let url = raw.url.flatMap(URL.init(string:)) ?? URL(string: "https://www.youtube.com/watch?v=\(raw.id)")!
            return PlaylistEntry(
                id: raw.id,
                title: raw.title ?? raw.id,
                duration: raw.duration,
                url: url,
                channel: raw.channel ?? raw.uploader,
                playlistTitle: raw.playlistTitle,
                playlistID: raw.playlistID
            )
        }
    }
}

private struct RawEntry: Decodable {
    let id: String
    let title: String?
    let duration: Double?
    let url: String?
    let channel: String?
    let uploader: String?
    let playlistTitle: String?
    let playlistID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, url, channel, uploader
        case playlistTitle = "playlist_title"
        case playlistID = "playlist_id"
    }
}
