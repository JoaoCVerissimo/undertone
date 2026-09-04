import Foundation
import Testing
@testable import UndertoneCore

@Suite struct YTDLPVersionTests {
    @Test func parsesAndCompares() {
        #expect(YTDLPVersion("2026.08.19") == YTDLPVersion(2026, 8, 19))
        #expect(YTDLPVersion("2026.08.19.123456\n") == YTDLPVersion(2026, 8, 19))
        #expect(YTDLPVersion("2026.03.03")! < YTDLPVersion.minimumRecommended)
        #expect(YTDLPVersion("2026.09.01")! > YTDLPVersion.minimumRecommended)
        #expect(YTDLPVersion("garbage") == nil)
        #expect(YTDLPVersion("2026.13.01") == nil)
        #expect(YTDLPVersion(2026, 8, 19).description == "2026.08.19")
    }
}

@Suite struct YTDLPDiagnosticsTests {
    @Test func extractsLastErrorLine() {
        let stderr = """
        WARNING: [youtube] something
        ERROR: [youtube] aqz-KE-bpKQ: The page needs to be reloaded.
        """
        #expect(YTDLPDiagnostics.lastErrorLine(in: stderr) == "The page needs to be reloaded.")
        #expect(YTDLPDiagnostics.lastErrorLine(in: "ERROR: unable to download video data: HTTP Error 403: Forbidden") == "unable to download video data: HTTP Error 403: Forbidden")
        #expect(YTDLPDiagnostics.lastErrorLine(in: "") == nil)
    }

    @Test func classifiesFailures() {
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: unable to download video data: HTTP Error 403: Forbidden") == .outdated(message: "unable to download video data: HTTP Error 403: Forbidden"))
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: [youtube] x: Requested format is not available. Use --list-formats for a list of available formats") == .outdated(message: "Requested format is not available. Use --list-formats for a list of available formats"))
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: [youtube] x: Video unavailable") == .unavailable(message: "Video unavailable"))
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: [youtube] x: Private video. Sign in if you've been granted access to this video") == .unavailable(message: "Private video. Sign in if you've been granted access to this video"))
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>") == .network(message: "Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>"))
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: [youtube] x: No supported JavaScript runtime could be found") == .missingJSRuntime(message: "No supported JavaScript runtime could be found"))
        // "Requested format is not available" is an outdated-yt-dlp signal, not an unavailable video (regression).
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: [youtube] x: This video is not available").message == "This video is not available")
        if case .unavailable = YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: [youtube] x: This video is not available") {} else { Issue.record("expected .unavailable for a genuinely unavailable video") }
        // A 403/429 wrapped in "Unable to download webpage" is a blocked client, not a connectivity problem:
        // it must be retryable with yt-dlp's default clients, not reported as "check your connection".
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: Unable to download webpage: HTTP Error 403: Forbidden") == .outdated(message: "Unable to download webpage: HTTP Error 403: Forbidden"))
        #expect(YTDLPDiagnostics.classify(exitCode: 1, stderr: "ERROR: Unable to download webpage: HTTP Error 429: Too Many Requests").shouldRetryWithDefaultClients)
        #expect(YTDLPDiagnostics.classify(exitCode: 2, stderr: "something odd") == .failed(exitCode: 2, message: "something odd"))
        #expect(YTDLPFailure.outdated(message: "x").shouldRetryWithDefaultClients)
        #expect(!YTDLPFailure.unavailable(message: "x").shouldRetryWithDefaultClients)
        #expect(YTDLPFailure.outdated(message: "x").suggestion == "Update it: brew upgrade yt-dlp")
    }
}

/// Records invocations and replays canned results.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var results: [ProcessResult]

    init(results: [ProcessResult]) { self.results = results }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws -> ProcessResult {
        lock.withLock {
            calls.append(arguments)
            guard !results.isEmpty else { return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("ERROR: no canned result".utf8)) }
            return results.removeFirst()
        }
    }
}

@Suite struct YTDLPClientTests {
    let executable = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
    let link = LinkParser.parse("https://youtu.be/aqz-KE-bpKQ")!

    @Test func fastClientFirstThenFallback() async throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("ERROR: [youtube] x: Requested format is not available".utf8)),
            ProcessResult(exitCode: 0, stdout: Data(Fixtures.videoJSON.utf8), stderr: Data()),
        ])
        let client = YTDLPClient(executable: executable, jsRuntime: URL(fileURLWithPath: "/usr/local/bin/deno"), environment: [:], runner: runner)
        let track = try await client.resolve(link)
        #expect(track.id == "aqz-KE-bpKQ")
        #expect(runner.calls.count == 2)
        #expect(runner.calls[0].contains("youtube:player_client=visionos"))
        #expect(!runner.calls[1].contains("youtube:player_client=visionos"))
        #expect(runner.calls[0].contains("--js-runtimes"))
        #expect(runner.calls[0].contains("deno:/usr/local/bin/deno"))
        #expect(runner.calls[0].contains("--no-playlist"))
        #expect(runner.calls[0].last == "https://www.youtube.com/watch?v=aqz-KE-bpKQ")
    }

    @Test func unavailableIsNotRetried() async {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("ERROR: [youtube] x: Video unavailable".utf8)),
        ])
        let client = YTDLPClient(executable: executable, environment: [:], runner: runner)
        await #expect(throws: YTDLPFailure.unavailable(message: "Video unavailable")) {
            try await client.resolve(link)
        }
        #expect(runner.calls.count == 1)
    }

    @Test func nonYouTubeSkipsFastClient() async throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: Data(Fixtures.videoJSON.utf8), stderr: Data())])
        let client = YTDLPClient(executable: executable, environment: [:], runner: runner)
        _ = try await client.resolve(LinkParser.parse("https://soundcloud.com/a/b")!)
        #expect(runner.calls.count == 1)
        #expect(!runner.calls[0].contains("--extractor-args"))
    }

    @Test func playlistListing() async throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: Data(Fixtures.playlistLines.utf8), stderr: Data())])
        let client = YTDLPClient(executable: executable, environment: [:], runner: runner)
        let entries = try await client.playlistEntries(LinkParser.parse("https://www.youtube.com/playlist?list=PLa1F2ddGya_8u-HEvmfCVuS_OImW8HaLd")!)
        #expect(entries.count == 4)
        #expect(runner.calls[0].contains("--flat-playlist"))
    }

    @Test func versionParsing() async throws {
        let runner = FakeRunner(results: [ProcessResult(exitCode: 0, stdout: Data("2026.08.19\n".utf8), stderr: Data())])
        let client = YTDLPClient(executable: executable, environment: [:], runner: runner)
        #expect(try await client.version() == YTDLPVersion(2026, 8, 19))
        #expect(runner.calls[0] == ["--version"])
    }
}

@Suite struct ToolPathsTests {
    @Test func mergesWithoutDuplicates() {
        let path = ToolPaths.mergedPATH(home: "/Users/me", loginPATH: "/usr/local/bin:/Users/me/.nvm/bin", currentPATH: "/usr/bin:/bin")
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.first == "/Users/me/.local/bin")
        #expect(parts.contains("/Users/me/.nvm/bin"))
        #expect(Set(parts).count == parts.count)
        #expect(parts.firstIndex(of: "/opt/homebrew/bin")! < parts.firstIndex(of: "/usr/bin")!)
    }

    @Test func environmentOverridesEssentials() {
        let env = ToolPaths.environment(home: "/Users/me", path: "/a:/b", base: ["PATH": "/x", "TMPDIR": "/tmp/t"])
        #expect(env["PATH"] == "/a:/b")
        #expect(env["HOME"] == "/Users/me")
        #expect(env["TMPDIR"] == "/tmp/t")
        #expect(env["NO_COLOR"] == "1")
    }

    @Test func locatesExecutables() {
        #expect(ToolPaths.locate("ls", in: "/nonexistent:/bin")?.path == "/bin/ls")
        #expect(ToolPaths.locate("definitely-not-a-tool", in: "/bin:/usr/bin") == nil)
    }
}

@Suite struct FormattingTests {
    @Test func clock() {
        #expect(TimeFormat.clock(5) == "0:05")
        #expect(TimeFormat.clock(754) == "12:34")
        #expect(TimeFormat.clock(3723) == "1:02:03")
        #expect(TimeFormat.clock(.nan) == "--:--")
        #expect(TimeFormat.clock(-1) == "--:--")
        #expect(TimeFormat.remaining(10, of: 211) == "-3:21")
        #expect(TimeFormat.remaining(10, of: 0) == "--:--")
    }

    @Test func speedCycle() {
        #expect(PlaybackSpeed.normal.next == .faster)
        #expect(PlaybackSpeed.faster.next == .double)
        #expect(PlaybackSpeed.double.next == .normal)
        #expect(PlaybackSpeed.double.label == "2×")
    }
}
