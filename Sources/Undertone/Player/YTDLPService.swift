import Foundation
import Observation
import UndertoneCore
import os

enum ToolStatus: Equatable {
    case checking
    case ready(YTDLPVersion)
    case outdated(YTDLPVersion)
    case missing
    case broken(String)

    /// Outdated still gets to try: YouTube may work for a while after a breaking change.
    var isUsable: Bool {
        switch self {
        case .ready, .outdated: return true
        default: return false
        }
    }
}

/// Finds yt-dlp and deno, probes the version, and hands out configured clients.
@Observable
final class YTDLPService {
    private(set) var status: ToolStatus = .checking
    private(set) var executable: URL?
    private(set) var jsRuntime: URL?
    private(set) var searchPath = ""

    @ObservationIgnored private var environment: [String: String] = [:]
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let log = Logger(subsystem: "com.jverissimo.undertone", category: "ytdlp")
    @ObservationIgnored private var cachedLoginPATH: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var client: YTDLPClient? {
        executable.map(makeClient)
    }

    /// Kick off the initial locate+probe. Call once at launch.
    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { await refresh() }
    }

    /// The client, waiting for the first probe to finish if it is still running. This is what callers
    /// should use so a link opened right after launch waits for yt-dlp instead of failing "not installed".
    func readyClient() async -> YTDLPClient? {
        if refreshTask == nil { start() }
        await refreshTask?.value
        return client
    }

    var installCommand: String {
        switch status {
        case .outdated: return "brew upgrade yt-dlp"
        default: return "brew install yt-dlp"
        }
    }

    /// Locates the tools and probes the version. Safe to call again (Recheck button, path change).
    func refresh(rereadLoginPath: Bool = false) async {
        status = .checking
        let home = NSHomeDirectory()
        if cachedLoginPATH == nil || rereadLoginPath { cachedLoginPATH = await Self.loginShellPATH() }
        searchPath = ToolPaths.mergedPATH(home: home, loginPATH: cachedLoginPATH, currentPATH: ProcessInfo.processInfo.environment["PATH"])
        environment = ToolPaths.environment(home: home, path: searchPath)
        jsRuntime = ToolPaths.locate("deno", in: searchPath)

        if let override = settings.ytdlpPathOverride, !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                executable = nil
                status = .broken("Not an executable: \(override)")
                return
            }
            executable = URL(fileURLWithPath: override)
        } else {
            executable = ToolPaths.locate("yt-dlp", in: searchPath)
        }

        guard let executable else {
            status = .missing
            log.notice("yt-dlp not found on \(self.searchPath, privacy: .public)")
            return
        }
        do {
            let version = try await makeClient(executable).version()
            status = version < YTDLPVersion.minimumRecommended ? .outdated(version) : .ready(version)
            log.notice("yt-dlp \(version.description, privacy: .public) at \(executable.path, privacy: .public); deno: \(self.jsRuntime?.path ?? "none", privacy: .public)")
        } catch {
            let message = (error as? YTDLPFailure)?.message ?? error.localizedDescription
            status = .broken(message)
            log.error("yt-dlp probe failed: \(message, privacy: .public)")
        }
    }

    func setOverride(_ path: String?) {
        settings.ytdlpPathOverride = path
        Task { await refresh() }
    }

    private func makeClient(_ executable: URL) -> YTDLPClient {
        YTDLPClient(executable: executable, jsRuntime: jsRuntime, environment: environment)
    }

    /// PATH as the user's login shell sees it (Homebrew, nvm, pyenv…), capped at 5 s in case a dotfile misbehaves.
    private static func loginShellPATH() async -> String? {
        let runner = SystemProcessRunner()
        guard let result = try? await runner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lic", "print -r -- $PATH"],
            environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(5)
        ), result.exitCode == 0 else { return nil }
        let lines = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.last(where: { $0.contains("/") }).map(String.init)
    }
}
