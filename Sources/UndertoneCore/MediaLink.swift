import Foundation

/// A pasted link, classified so the app knows how to hand it to yt-dlp.
public struct MediaLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A single YouTube video.
        case video(id: String)
        /// A real YouTube playlist (`list=PL…`, `OL…`, …) that yt-dlp can enumerate.
        case playlist(id: String, startVideoID: String?, startIndex: Int?)
        /// A YouTube Mix / radio (`list=RD…`): cannot be enumerated, so only the video plays.
        case mix(videoID: String)
        /// Any other http(s) URL. Handed to yt-dlp unchanged (it supports many sites).
        case other
    }

    public let original: URL
    public let kind: Kind
    /// `t=90`, `t=1m30s`, `start=90` on YouTube links.
    public let startTime: Double?

    public init(original: URL, kind: Kind, startTime: Double? = nil) {
        self.original = original
        self.kind = kind
        self.startTime = startTime
    }

    public var isYouTube: Bool {
        if case .other = kind { return false }
        return true
    }

    public var videoID: String? {
        switch kind {
        case .video(let id): return id
        case .playlist(_, let startVideoID, _): return startVideoID
        case .mix(let videoID): return videoID
        case .other: return nil
        }
    }

    public var playlistID: String? {
        if case .playlist(let id, _, _) = kind { return id }
        return nil
    }

    public var isPlaylist: Bool { playlistID != nil }

    /// Canonical URL to give yt-dlp.
    public var resolvedURL: URL {
        switch kind {
        case .video(let id), .mix(videoID: let id):
            return URL(string: "https://www.youtube.com/watch?v=\(id)")!
        case .playlist(let id, _, _):
            return URL(string: "https://www.youtube.com/playlist?list=\(id)")!
        case .other:
            return original
        }
    }
}

public enum LinkParser {
    static let youtubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com", "youtu.be", "www.youtu.be",
    ]

    /// Parses free text (a URL, or text containing one) into a `MediaLink`.
    public static func parse(_ text: String) -> MediaLink? {
        guard let url = extractURL(from: text) else { return nil }
        guard let host = url.host()?.lowercased() else { return nil }
        guard youtubeHosts.contains(host) else {
            return MediaLink(original: url, kind: .other)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        let path = url.path().split(separator: "/").map(String.init)

        var videoID: String?
        if host.hasSuffix("youtu.be") {
            videoID = path.first
        } else if let v = query["v"] {
            videoID = v
        } else if path.count >= 2, ["shorts", "live", "embed", "v", "e"].contains(path[0]) {
            videoID = path[1]
        }
        videoID = videoID.flatMap(validVideoID)
        let startTime = (query["t"] ?? query["start"]).flatMap(parseTimestamp)

        if let list = query["list"].flatMap(validPlaylistID) {
            if list.hasPrefix("RD") || list.hasPrefix("UL") {
                if let videoID {
                    return MediaLink(original: url, kind: .mix(videoID: videoID), startTime: startTime)
                }
                return MediaLink(original: url, kind: .other)
            }
            let index = query["index"].flatMap { Int($0) }
            return MediaLink(
                original: url,
                kind: .playlist(id: list, startVideoID: videoID, startIndex: index),
                startTime: startTime
            )
        }
        if let videoID {
            return MediaLink(original: url, kind: .video(id: videoID), startTime: startTime)
        }
        // Channel pages etc.: let yt-dlp decide.
        return MediaLink(original: url, kind: .other)
    }

    static func validVideoID(_ candidate: String) -> String? {
        guard candidate.count == 11, candidate.allSatisfy(isIDCharacter) else { return nil }
        return candidate
    }

    static func validPlaylistID(_ candidate: String) -> String? {
        guard !candidate.isEmpty, candidate.count <= 64, candidate.allSatisfy(isIDCharacter) else { return nil }
        return candidate
    }

    private static func isIDCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_")
    }

    /// "90", "90s", "1m30s", "1h2m3s" → seconds.
    static func parseTimestamp(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let plain = Double(s) { return plain >= 0 ? plain : nil }
        var total: Double = 0
        var number = ""
        var matched = false
        for ch in s {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else if let unit = ["h": 3600.0, "m": 60.0, "s": 1.0][String(ch)], let value = Double(number) {
                total += value * unit
                number = ""
                matched = true
            } else {
                return nil
            }
        }
        if let trailing = Double(number) { total += trailing; matched = true }
        return matched ? total : nil
    }

    /// Finds the first URL-looking token in free text; bare `youtube.com/…` and `youtu.be/…` get `https://`.
    static func extractURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        for token in tokens {
            var candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[],;"))
            if !candidate.contains("://") {
                let lower = candidate.lowercased()
                guard youtubeHosts.contains(where: { lower == $0 || lower.hasPrefix($0 + "/") }) else { continue }
                candidate = "https://" + candidate
            }
            guard let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host() != nil
            else { continue }
            return url
        }
        return nil
    }
}
