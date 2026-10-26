import Foundation

public enum Format {
    /// Decimal units, the way Finder and the disk's label count them (1 GB = 10⁹ bytes).
    public static func bytes(_ b: Int64) -> String {
        let v = Double(max(0, b))
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (scale, unit) in units where v >= scale {
            let x = v / scale
            let digits = x >= 100 ? 0 : 1
            return String(format: "%.\(digits)f %@", x, unit)
        }
        return b == 0 ? "0 KB" : "\(Int(v)) bytes"
    }

    public static func count(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 10_000...: String(format: "%.0fK", Double(n) / 1e3)
        default: n.formatted()
        }
    }

    /// "3 days ago", "8 months ago", "2 years ago".
    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        let days = now.timeIntervalSince(date) / 86_400
        switch days {
        case ..<1: return "today"
        case ..<2: return "yesterday"
        case ..<14: return "\(Int(days)) days ago"
        case ..<60: return "\(Int(days / 7)) weeks ago"
        case ..<365: return "\(Int(days / 30.4)) months ago"
        case ..<730: return "1 year ago"
        default: return "\(Int(days / 365.25)) years ago"
        }
    }

    public static func ageDays(_ days: Double) -> String {
        age(Date().addingTimeInterval(-days * 86_400))
    }
}
