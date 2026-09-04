import Foundation

/// Thin wrapper over the yt-dlp CLI: resolve a link to a playable stream, list a playlist, read the version.
public struct YTDLPClient: Sendable {
    public var executable: URL
    /// Path to `deno`, passed explicitly so yt-dlp does not depend on PATH for its JavaScript challenges.
    public var jsRuntime: URL?
    public var environment: [String: String]
    public var runner: any ProcessRunning
    public var timeout: Duration

    /// Audio-only AAC first (AVPlayer can't play Opus/WebM), then a progressive MP4, then anything.
    public static let formatSelector = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]/best"
    /// The fastest client measured (≈5 s vs ≈8.5 s for the default set). Falls back to the default set on failure.
    public static let fastClient = "visionos"

    public init(executable: URL, jsRuntime: URL? = nil, environment: [String: String],
                runner: any ProcessRunning = SystemProcessRunner(), timeout: Duration = .seconds(45)) {
        self.executable = executable
        self.jsRuntime = jsRuntime
        self.environment = environment
        self.runner = runner
        self.timeout = timeout
    }

    public var baseArguments: [String] {
        var args = ["--ignore-config", "--no-update", "--no-warnings", "--quiet"]
        if let jsRuntime {
            args += ["--js-runtimes", "deno:\(jsRuntime.path)"]
        }
        return args
    }

    public func version() async throws -> YTDLPVersion {
        let result = try await runner.run(executable: executable, arguments: ["--version"], environment: environment, timeout: .seconds(20))
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard result.exitCode == 0,
              let last = text.split(whereSeparator: \.isNewline).last,
              let version = YTDLPVersion(String(last))
        else {
            throw YTDLPFailure.failed(exitCode: result.exitCode, message: "Could not read the yt-dlp version.")
        }
        return version
    }

    /// Resolves a single video (or the video part of a mix) to a stream.
    public func resolve(_ link: MediaLink) async throws -> Track {
        let target = link.resolvedURL.absoluteString
        let common = baseArguments + ["--no-playlist", "-f", Self.formatSelector, "-j"]
        if link.isYouTube {
            do {
                return try await resolveOnce(common + ["--extractor-args", "youtube:player_client=\(Self.fastClient)", target])
            } catch let failure as YTDLPFailure where failure.shouldRetryWithDefaultClients {
                // Fall through to yt-dlp's own client rotation.
            }
        }
        return try await resolveOnce(common + [target])
    }

    private func resolveOnce(_ arguments: [String]) async throws -> Track {
        let result = try await runner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw YTDLPDiagnostics.classify(exitCode: result.exitCode, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return try Track.decode(fromYTDLPJSON: result.stdout)
    }

    /// Lists a playlist without resolving streams (fast: ~4 s for 80 entries).
    public func playlistEntries(_ link: MediaLink, limit: Int = 500) async throws -> [PlaylistEntry] {
        let arguments = baseArguments + ["--flat-playlist", "--playlist-end", String(limit), "-j", link.resolvedURL.absoluteString]
        let result = try await runner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw YTDLPDiagnostics.classify(exitCode: result.exitCode, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        let entries = PlaylistEntry.decodeLines(result.stdout)
        guard !entries.isEmpty else { throw YTDLPFailure.unavailable(message: "That playlist is empty or can't be read.") }
        return entries
    }
}
