import Foundation
import AbstractCore

/// Every agent response on this Mac, read from the agents' logs in the
/// background and cached, so opening Usage again is quick.
@Observable
final class UsageLedger {
    private(set) var records: [LocalUsage.Record] = []
    private(set) var loading = false
    private(set) var loadedAt: Date?

    /// Next to Abstract's database (the demo's own folder in demo mode).
    private var cache: URL {
        let data = ProcessInfo.processInfo.environment["ABSTRACT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Abstract")
        return data.appendingPathComponent("usage-cache.json")
    }

    func load() async {
        guard !loading else { return }
        loading = true
        let (home, cache) = (NSHomeDirectory(), cache)
        records = await Task.detached(priority: .utility) { LocalUsage.load(home: home, cache: cache) }.value
        loadedAt = Date()
        loading = false
    }
}

/// The ledger cut to a period: totals, the daily series, and the tables.
struct UsageReport {
    enum Metric: String, CaseIterable, Identifiable { case cost, tokens; var id: String { rawValue } }

    struct Row: Identifiable {
        let id: String
        let name: String
        let provider: LocalUsage.Provider?
        let tokens: LocalUsage.Tokens
        let cost: Double
        /// A price was assumed rather than known (newer OpenAI models).
        let estimated: Bool
    }

    struct Point: Identifiable {
        let day: Date
        let provider: LocalUsage.Provider
        let cost: Double
        let tokens: Int
        var id: String { "\(provider.rawValue)-\(day.timeIntervalSince1970)" }
    }

    let start: Date
    let end: Date
    let tokens: LocalUsage.Tokens
    let cost: Double
    let savings: Double
    let providers: [Row]
    let models: [Row]
    let workspaces: [Row]
    let series: [Point]

    init(records: [LocalUsage.Record], days: Int, workspaceName: (String) -> String, now: Date = Date()) {
        let calendar = Calendar.current
        let from = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        start = from
        end = now
        let shown = records.filter { $0.date >= from }

        func costed(_ r: LocalUsage.Record) -> (Double, Bool) {
            let known = ModelPricing.rates(provider: r.provider, model: r.model)?.known ?? false
            return (ModelPricing.cost(provider: r.provider, model: r.model, tokens: r.tokens) ?? 0, !known)
        }

        func rows(_ key: (LocalUsage.Record) -> String, name: (String) -> String, provider: (LocalUsage.Record) -> LocalUsage.Provider?) -> [Row] {
            var totals: [String: (LocalUsage.Tokens, Double, Bool, LocalUsage.Provider?)] = [:]
            for r in shown {
                let (c, estimated) = costed(r)
                let k = key(r)
                let old = totals[k] ?? (LocalUsage.Tokens(), 0, false, provider(r))
                totals[k] = (old.0 + r.tokens, old.1 + c, old.2 || estimated, old.3)
            }
            return totals.map { Row(id: $0.key, name: name($0.key), provider: $0.value.3, tokens: $0.value.0, cost: $0.value.1, estimated: $0.value.2) }
                .sorted { $0.cost > $1.cost }
        }

        providers = rows({ $0.provider.rawValue }, name: { $0 == "claude" ? "Claude Code" : "Codex" }, provider: { $0.provider })
        models = rows({ $0.model }, name: { $0 }, provider: { $0.provider })
        // Named once per folder: a chat's worktree reads as the chat, a project root as the project.
        let names = Dictionary(uniqueKeysWithValues: Set(shown.map(\.cwd)).map { ($0, workspaceName($0)) })
        workspaces = rows({ names[$0.cwd] ?? $0.cwd }, name: { $0 }, provider: { _ in nil })
        tokens = shown.reduce(LocalUsage.Tokens()) { $0 + $1.tokens }
        cost = providers.reduce(0) { $0 + $1.cost }
        savings = shown.reduce(0) { $0 + ModelPricing.cacheSavings(provider: $1.provider, model: $1.model, tokens: $1.tokens) }

        var byDay: [String: (Date, LocalUsage.Provider, Double, Int)] = [:]
        for r in shown {
            let day = calendar.startOfDay(for: r.date)
            let k = "\(r.provider.rawValue)-\(day.timeIntervalSince1970)"
            let old = byDay[k] ?? (day, r.provider, 0, 0)
            byDay[k] = (day, r.provider, old.2 + costed(r).0, old.3 + r.tokens.total)
        }
        // Every day on the axis, so a quiet day reads as zero rather than a gap.
        var points: [Point] = []
        var day = from
        let providersSeen = Set(shown.map(\.provider))
        while day <= now {
            for provider in LocalUsage.Provider.allCases where providersSeen.contains(provider) {
                let v = byDay["\(provider.rawValue)-\(day.timeIntervalSince1970)"]
                points.append(Point(day: day, provider: provider, cost: v?.2 ?? 0, tokens: v?.3 ?? 0))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        series = points
    }
}

/// Figures as the dashboard writes them: `1.8B`, `569.0M`, `$1,418`, `$59.17`.
enum UsageFormat {
    private static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .currency
        f.currencySymbol = "$"
        return f
    }()

    static func cost(_ value: Double) -> String {
        money.maximumFractionDigits = value >= 100 ? 0 : 2
        money.minimumFractionDigits = value >= 100 ? 0 : 2
        return money.string(from: NSNumber(value: value)) ?? "$0"
    }

    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return String(value)
        }
    }

    static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
}

extension AppModel {
    /// What to call the folder a response ran in: the chat whose worktree it
    /// is, else the project, else the folder's own name.
    func workspaceName(_ cwd: String) -> String {
        let path = cwd.hasPrefix("/private/") ? String(cwd.dropFirst("/private".count)) : cwd
        guard !path.isEmpty else { return "Unknown folder" }
        func within(_ root: String?) -> Bool {
            guard let root, !root.isEmpty else { return false }
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        if let chat = sessions.first(where: { within($0.worktreePath) }) { return chat.name }
        if let project = projects.first(where: { within($0.rootPath) }) { return project.name }
        if path == NSHomeDirectory() { return "Home folder" }
        return (path as NSString).lastPathComponent
    }
}
