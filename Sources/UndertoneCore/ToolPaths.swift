import Foundation

/// GUI apps launch with a bare PATH (`/usr/bin:/bin:…`), so yt-dlp and deno have to be found explicitly.
public enum ToolPaths {
    public static func candidateDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",      // native Homebrew
            "/usr/local/bin",         // Intel Homebrew (Rosetta) and pip installs
            "\(home)/.deno/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    /// Candidate dirs first, then whatever the login shell and the current process add, without duplicates.
    public static func mergedPATH(home: String, loginPATH: String? = nil, currentPATH: String? = nil) -> String {
        var seen = Set<String>()
        var result: [String] = []
        let sources = candidateDirectories(home: home)
            + (loginPATH ?? "").split(separator: ":").map(String.init)
            + (currentPATH ?? "").split(separator: ":").map(String.init)
        for dir in sources where !dir.isEmpty && seen.insert(dir).inserted {
            result.append(dir)
        }
        return result.joined(separator: ":")
    }

    /// Environment for the yt-dlp process. Starts from the current environment so TMPDIR etc. survive.
    public static func environment(home: String, path: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["HOME"] = home
        env["PATH"] = path
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        env["NO_COLOR"] = "1"
        return env
    }

    /// First executable named `name` along `path`.
    public static func locate(_ name: String, in path: String, fileManager: FileManager = .default) -> URL? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
