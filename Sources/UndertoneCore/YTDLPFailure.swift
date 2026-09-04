import Foundation

public enum YTDLPFailure: Error, Equatable, Sendable {
    case notInstalled
    case launchFailed(String)
    case timedOut
    case cancelled
    /// yt-dlp is talking to a YouTube that changed under it. The fix is `brew upgrade yt-dlp`.
    case outdated(message: String)
    case missingJSRuntime(message: String)
    /// Private, removed, age-gated, geo-blocked, members-only, or an unsupported page.
    case unavailable(message: String)
    case network(message: String)
    case failed(exitCode: Int32, message: String)
    case invalidOutput

    public var message: String {
        switch self {
        case .notInstalled: return "yt-dlp is not installed."
        case .launchFailed(let why): return "Could not start yt-dlp: \(why)"
        case .timedOut: return "yt-dlp took too long and was stopped."
        case .cancelled: return "Cancelled."
        case .outdated(let m), .missingJSRuntime(let m), .unavailable(let m), .network(let m): return m
        case .failed(let code, let m): return m.isEmpty ? "yt-dlp failed (exit \(code))." : m
        case .invalidOutput: return "yt-dlp returned something unexpected."
        }
    }

    public var suggestion: String? {
        switch self {
        case .notInstalled: return "brew install yt-dlp"
        case .outdated: return "Update it: brew upgrade yt-dlp"
        case .missingJSRuntime: return "brew install deno"
        case .invalidOutput, .failed: return "Try again; if it keeps failing: brew upgrade yt-dlp"
        case .network: return "Check your connection and try again."
        case .launchFailed, .timedOut, .cancelled, .unavailable: return nil
        }
    }

    /// Whether trying again with yt-dlp's default client set is worthwhile.
    public var shouldRetryWithDefaultClients: Bool {
        switch self {
        case .outdated, .failed, .invalidOutput: return true
        default: return false
        }
    }
}

public enum YTDLPDiagnostics {
    /// Maps a non-zero exit + stderr to a typed failure with a human-readable message.
    public static func classify(exitCode: Int32, stderr: String) -> YTDLPFailure {
        let message = lastErrorLine(in: stderr) ?? ""
        let haystack = stderr.lowercased()

        func mentions(_ needles: String...) -> Bool { needles.contains { haystack.contains($0) } }

        if mentions("javascript runtime", "js runtime", "no supported javascript", "--js-runtimes") {
            return .missingJSRuntime(message: message.isEmpty ? "yt-dlp needs a JavaScript runtime (deno) for YouTube." : message)
        }
        // Note: order matters. "Requested format is not available" is a yt-dlp-is-behind signal (handled below),
        // not a video-availability problem, so keep the availability needles specific enough to not catch it.
        if mentions("video unavailable", "private video", "this video is unavailable", "has been removed",
                    "sign in to confirm your age", "age-restricted", "members-only", "not available in your country",
                    "this live event", "premieres in", "unsupported url", "is not a valid url",
                    "video does not exist", "this channel does not exist", "video is not available",
                    "account has been terminated", "who has blocked it in your country") {
            return .unavailable(message: message.isEmpty ? "This link can't be played." : message)
        }
        if mentions("unable to download webpage", "nodename nor servname", "network is unreachable",
                    "temporary failure in name resolution", "urlopen error", "connection reset",
                    "read timed out", "timed out", "ssl:", "no route to host", "connection refused") {
            return .network(message: message.isEmpty ? "Network error while contacting YouTube." : message)
        }
        if mentions("http error 403", "requested format is not available", "the page needs to be reloaded",
                    "unable to extract", "missing a url", "sabr", "confirm you're not a bot", "confirm you’re not a bot",
                    "please report this issue", "failed to parse json", "po token", "no video formats found",
                    "nsig extraction failed", "unable to download api page") {
            return .outdated(message: message.isEmpty ? "YouTube changed something yt-dlp doesn't handle yet." : message)
        }
        return .failed(exitCode: exitCode, message: message)
    }

    /// The last `ERROR: …` line, minus the `[youtube] id:` noise. Nil when stderr has none.
    public static func lastErrorLine(in stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard var line = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last(where: { !$0.isEmpty }) else { return nil }
        if line.hasPrefix("ERROR:") { line = String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces) }
        // "[youtube] aqz-KE-bpKQ: The page needs to be reloaded" → "The page needs to be reloaded"
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            var rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if let colon = rest.firstIndex(of: ":"), rest[..<colon].allSatisfy({ !$0.isWhitespace }) {
                rest = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            line = rest
        }
        return line.isEmpty ? nil : line
    }
}
