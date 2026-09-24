import Foundation

/// Short relative times and durations for dense UI ("3m", "in 2h", "4m 12s").
enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if abs(s) < 45 { return "now" }
        let future = s < 0
        let a = abs(s)
        let text: String = a < 3600 ? "\(Int(a / 60))m" : a < 86_400 ? "\(Int(a / 3600))h" : a < 604_800 ? "\(Int(a / 86_400))d" : "\(Int(a / 604_800))w"
        return future ? "in \(text)" : text
    }

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
