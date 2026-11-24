import Foundation

/// Short durations and ages in the design's wording: `23m`, `1h 5m`, `2m ago`.
public enum Formatting {
    /// `45s`, `23m`, `1h`, `1h 5m`, `2d`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        return "\(hours / 24)d"
    }

    /// `now`, `2m ago`, `3h ago`, `2d ago`.
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        return "\(duration(seconds)) ago"
    }

    /// `e2e-chrome, lint` or `e2e-chrome, lint +3 more` for longer lists. The design names
    /// up to two checks, then counts the rest.
    public static func names(_ names: [String], limit: Int = 2, moreSuffix: String = " more") -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        let rest = names.count - min(names.count, limit)
        return rest > 0 ? "\(shown) +\(rest)\(moreSuffix)" : shown
    }

    /// `MERGE_CONFLICT` → `merge conflict`.
    public static func humanize(_ constant: String) -> String {
        constant.replacingOccurrences(of: "_", with: " ").lowercased()
    }
}
