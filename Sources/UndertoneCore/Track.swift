import Foundation

/// A resolved, playable stream plus the metadata the UI shows.
public struct Track: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var channel: String?
    /// Seconds, from yt-dlp metadata. Trust this over AVFoundation: YouTube's m4a headers report double the length.
    public var duration: Double?
    public var webpageURL: URL?
    public var thumbnailURL: URL?
    public var streamURL: URL
    public var streamExtension: String?
    public var audioCodec: String?
    public var httpHeaders: [String: String]
    /// From the `expire=` query parameter of the stream URL (YouTube URLs live ~6 h).
    public var expiresAt: Date?
    public var extractor: String?

    public init(
        id: String, title: String, channel: String? = nil, duration: Double? = nil,
        webpageURL: URL? = nil, thumbnailURL: URL? = nil, streamURL: URL,
        streamExtension: String? = nil, audioCodec: String? = nil,
        httpHeaders: [String: String] = [:], expiresAt: Date? = nil, extractor: String? = nil
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.duration = duration
        self.webpageURL = webpageURL
        self.thumbnailURL = thumbnailURL
        self.streamURL = streamURL
        self.streamExtension = streamExtension
        self.audioCodec = audioCodec
        self.httpHeaders = httpHeaders
        self.expiresAt = expiresAt
        self.extractor = extractor
    }

    public var userAgent: String? { httpHeaders["User-Agent"] }

    public var isYouTube: Bool { extractor?.lowercased().hasPrefix("youtube") ?? false }

    /// Stable JPEG artwork for YouTube (webp maxres thumbnails are flaky); the site thumbnail otherwise.
    public var artworkURL: URL? {
        isYouTube ? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") : thumbnailURL
    }

    public func isExpired(at now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(margin) >= expiresAt
    }

    /// Decodes `yt-dlp -j` output for a single video.
    public static func decode(fromYTDLPJSON data: Data) throws -> Track {
        let info: YTDLPInfo
        do {
            info = try JSONDecoder().decode(YTDLPInfo.self, from: data)
        } catch {
            throw YTDLPFailure.invalidOutput
        }
        guard let urlString = info.url, let streamURL = URL(string: urlString) else {
            throw YTDLPFailure.invalidOutput
        }
        return Track(
            id: info.id,
            title: info.title ?? info.id,
            channel: info.channel ?? info.uploader,
            duration: info.duration,
            webpageURL: info.webpageURL.flatMap(URL.init(string:)),
            thumbnailURL: info.thumbnail.flatMap(URL.init(string:)),
            streamURL: streamURL,
            streamExtension: info.ext,
            audioCodec: info.acodec,
            httpHeaders: (info.httpHeaders ?? [:]).filter { $0.key == "User-Agent" },   // the only one used
            expiresAt: expiry(from: streamURL),
            extractor: info.extractor
        )
    }

    static func expiry(from url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "expire" })?.value,
              let seconds = TimeInterval(raw)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct YTDLPInfo: Decodable {
    let id: String
    let title: String?
    let channel: String?
    let uploader: String?
    let duration: Double?
    let webpageURL: String?
    let thumbnail: String?
    let url: String?
    let ext: String?
    let acodec: String?
    let httpHeaders: [String: String]?
    let extractor: String?

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, duration, thumbnail, url, ext, acodec, extractor
        case webpageURL = "webpage_url"
        case httpHeaders = "http_headers"
    }
}
