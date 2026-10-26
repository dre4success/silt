import Foundation

/// What a byte on disk is for. Eight buckets, because the colour palette has eight slots
/// and a ninth colour would be a generated one nobody can tell apart.
public enum Kind: Int, CaseIterable, Sendable, Hashable {
    case apps, developer, media, documents, archives, caches, appData, other

    public var title: String {
        switch self {
        case .apps: "Apps"
        case .developer: "Developer"
        case .media: "Photos, video & music"
        case .documents: "Documents"
        case .archives: "Archives & installers"
        case .caches: "Caches & logs"
        case .appData: "App data"
        case .other: "Other"
        }
    }
}

/// Bytes per kind. Stored as eight plain fields rather than an array so a node
/// carries it inline instead of pointing at a separate heap allocation.
public struct KindBytes: Sendable, Equatable {
    var apps: Int64 = 0, developer: Int64 = 0, media: Int64 = 0, documents: Int64 = 0
    var archives: Int64 = 0, caches: Int64 = 0, appData: Int64 = 0, other: Int64 = 0

    public init() {}

    public subscript(kind: Kind) -> Int64 {
        get {
            switch kind {
            case .apps: apps
            case .developer: developer
            case .media: media
            case .documents: documents
            case .archives: archives
            case .caches: caches
            case .appData: appData
            case .other: other
            }
        }
        set {
            switch kind {
            case .apps: apps = newValue
            case .developer: developer = newValue
            case .media: media = newValue
            case .documents: documents = newValue
            case .archives: archives = newValue
            case .caches: caches = newValue
            case .appData: appData = newValue
            case .other: other = newValue
            }
        }
    }

    public var total: Int64 { Kind.allCases.reduce(0) { $0 + self[$1] } }

    public var dominant: Kind {
        Kind.allCases.max { self[$0] < self[$1] } ?? .other
    }

    public static func += (lhs: inout KindBytes, rhs: KindBytes) {
        for k in Kind.allCases { lhs[k] += rhs[k] }
    }

    public static func -= (lhs: inout KindBytes, rhs: KindBytes) {
        for k in Kind.allCases { lhs[k] -= rhs[k] }
    }
}

/// Age bands for the strata view, newest first.
public enum Stratum: Int, CaseIterable, Sendable {
    case week, month, quarter, year, twoYears, fiveYears, older

    public var title: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .quarter: "1–3 months"
        case .year: "3–12 months"
        case .twoYears: "1–2 years"
        case .fiveYears: "2–5 years"
        case .older: "Over 5 years"
        }
    }

    static let upperDays: [Double] = [7, 30, 91, 365, 730, 1826, .infinity]

    public static func of(ageDays: Double) -> Stratum {
        let i = upperDays.firstIndex { ageDays < $0 } ?? upperDays.count - 1
        return Stratum(rawValue: i)!
    }
}
