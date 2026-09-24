import Foundation
import AbstractCore

/// The agents' accounts on this Mac: every Claude Code profile (each its
/// own `CLAUDE_CONFIG_DIR`) and the Codex sign-in, with how much of each
/// plan's limits is used. Limits are what the agent last reported: Claude
/// in its chats' `rate_limit_event`s, Codex in its session logs.
@Observable
final class AccountsStore {
    struct ClaudeAccount: Identifiable, Hashable {
        var profile: ClaudeAccounts.Profile
        var status: Status
        var quota: AccountQuota?
        var id: String { profile.path }
    }

    enum Status: Hashable {
        case checking, signedIn
        /// Signed in once (the profile knows its account) but not any more.
        case expired
        case signedOut
    }

    private(set) var claude: [ClaudeAccount] = []
    private(set) var codex: CodexAccount.Info?
    private(set) var codexQuota: AccountQuota?
    private(set) var refreshedAt: Date?

    /// Limits Claude chats reported, by profile path; kept across launches.
    private var claudeQuotas: [String: AccountQuota] {
        didSet { save() }
    }

    private let home = NSHomeDirectory()
    private static let quotasKey = "accounts.claudeQuotas"

    init() {
        claudeQuotas = UserDefaults.standard.data(forKey: Self.quotasKey)
            .flatMap { try? JSONDecoder().decode([String: AccountQuota].self, from: $0) } ?? [:]
    }

    var standardProfilePath: String { home + "/.claude" }

    /// Re-reads profiles, sign-in state and limits.
    func refresh(executor: any Executor) async {
        let profiles = await Task.detached { [home] in ClaudeAccounts.profiles(home: home) }.value
        claude = profiles.map { profile in
            ClaudeAccount(profile: profile, status: claude.first { $0.id == profile.path }?.status ?? .checking,
                          quota: claudeQuotas[profile.path])
        }
        let (info, quota) = await Task.detached { [home] in (CodexAccount.info(home: home), CodexAccount.quota(home: home)) }.value
        codex = info
        codexQuota = quota
        for profile in profiles {
            let status = await Self.status(of: profile, executor: executor)
            if let i = claude.firstIndex(where: { $0.id == profile.path }) { claude[i].status = status }
        }
        refreshedAt = Date()
    }

    /// `claude auth status` for the profile: whether its sign-in still works.
    private static func status(of profile: ClaudeAccounts.Profile, executor: any Executor) async -> Status {
        // Variables a parent Claude session exports (a proxy URL, its token) would answer for it instead.
        let inherited = ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix("CLAUDE_CODE_") || $0.hasPrefix("ANTHROPIC_") || $0 == "CLAUDE_CONFIG_DIR" }
            .flatMap { ["-u", $0] }
        let args = inherited + (profile.isStandard ? [] : ["CLAUDE_CONFIG_DIR=\(profile.path)"]) + ["claude", "auth", "status", "--json"]
        guard let out = try? await executor.run("/usr/bin/env", args, cwd: nil), out.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any] else {
            return profile.email == nil ? .signedOut : .expired
        }
        if json["loggedIn"] as? Bool == true { return .signedIn }
        return profile.email == nil ? .signedOut : .expired
    }

    /// A chat's report of its account's limits.
    func record(_ quota: AccountQuota, profile: String) {
        claudeQuotas[profile] = quota
        if let i = claude.firstIndex(where: { $0.id == profile }) { claude[i].quota = quota }
    }

    /// Makes an empty profile folder, shown signed out until its login runs.
    func addProfile(named name: String) -> ClaudeAccounts.Profile? {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }
        let path = home + "/.claude-" + slug
        try? FileManager.default.createDirectory(atPath: path + "/projects", withIntermediateDirectories: true)
        let profile = ClaudeAccounts.Profile(path: path, isStandard: false, email: nil, organization: nil, plan: nil)
        if !claude.contains(where: { $0.id == path }) {
            claude.append(ClaudeAccount(profile: profile, status: .signedOut, quota: nil))
        }
        return profile
    }

    private func save() {
        if let data = try? JSONEncoder().encode(claudeQuotas) { UserDefaults.standard.set(data, forKey: Self.quotasKey) }
    }

    /// Before any chat has reported limits this session: the newest report in Abstract's own logs.
    func seedFromLogs(_ directory: URL) async {
        guard claudeQuotas[standardProfilePath] == nil else { return }
        let found = await Task.detached { () -> AccountQuota? in
            let fm = FileManager.default
            let logs = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for log in logs.prefix(8) {
                guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
                let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                for row in text.split(separator: "\n").reversed() where row.contains("rate_limit_event") {
                    guard let wrapped = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
                          let line = wrapped["line"] as? String, let quota = ClaudeAccounts.quota(fromLine: line, at: modified) else { continue }
                    return quota
                }
            }
            return nil
        }.value
        if let found { record(found, profile: standardProfilePath) }
    }
}
