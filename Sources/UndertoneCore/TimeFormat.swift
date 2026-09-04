import Foundation

public enum TimeFormat {
    /// 5 → "0:05", 754 → "12:34", 3723 → "1:02:03", NaN/negative → "--:--"
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "-3:21" style remaining time.
    public static func remaining(_ current: Double, of duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        return "-" + clock(max(0, duration - current))
    }
}
