import Foundation
import AbstractCore

/// Short relative times and durations for dense UI ("3m", "in 2h", "4m 12s").
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String { RelativeAge.short(date, now: now) }

    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60, r = s % 60
        if m < 60 { return r > 0 ? "\(m)m \(r)s" : "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func tokens(_ n: Int) -> String {
        n < 1000 ? "\(n)" : n < 1_000_000 ? String(format: n < 10_000 ? "%.1fk" : "%.0fk", Double(n) / 1000) : String(format: "%.1fM", Double(n) / 1_000_000)
    }
}
