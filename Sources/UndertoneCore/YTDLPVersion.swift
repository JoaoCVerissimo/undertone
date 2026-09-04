import Foundation

/// yt-dlp versions are dates: `2026.08.19`, nightlies `2026.08.19.123456`.
public struct YTDLPVersion: Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Oldest release known to work with YouTube as of this app's last update.
    public static let minimumRecommended = YTDLPVersion(2026, 8, 19)

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 2000, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(parts[0], parts[1], parts[2])
    }

    public var description: String { String(format: "%04d.%02d.%02d", year, month, day) }

    public static func < (lhs: YTDLPVersion, rhs: YTDLPVersion) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
