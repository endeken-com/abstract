import Foundation

/// How much of a plan's rolling limits an account has used, as the agent
/// last reported it.
public struct AccountQuota: Codable, Sendable, Hashable {
    public struct Window: Codable, Sendable, Hashable {
        /// 0...1.
        public var used: Double
        public var resetsAt: Date?

        public init(used: Double, resetsAt: Date?) { self.used = used; self.resetsAt = resetsAt }
    }

    /// The five-hour window.
    public var session: Window?
    public var weekly: Window?
    /// Prepaid credits left, when the plan has them (Codex), as the agent wrote it.
    public var credits: String?
    public var observedAt: Date

    public init(session: Window?, weekly: Window?, credits: String? = nil, observedAt: Date) {
        self.session = session; self.weekly = weekly; self.credits = credits; self.observedAt = observedAt
    }
}

/// Claude Code's sign-in profiles: `~/.claude`, and each folder a
/// `CLAUDE_CONFIG_DIR` points at (`~/.claude-work`, …), each its own account.
public enum ClaudeAccounts {
    public struct Profile: Sendable, Hashable, Identifiable {
        public var path: String
        /// `~/.claude`, the profile `claude` uses without `CLAUDE_CONFIG_DIR`.
        public var isStandard: Bool
        public var email: String?
        public var organization: String?
        /// "Team", "Max", "Pro", "Enterprise".
        public var plan: String?
        public var id: String { path }

        public init(path: String, isStandard: Bool, email: String? = nil, organization: String? = nil, plan: String? = nil) {
            self.path = path; self.isStandard = isStandard; self.email = email; self.organization = organization; self.plan = plan
        }
    }

    public static func profiles(home: String, fileManager fm: FileManager = .default) -> [Profile] {
        LocalUsage.claudeHomes(home: home, fileManager: fm).map { path in
            let standard = path == home + "/.claude"
            let config = standard ? home + "/.claude.json" : path + "/.claude.json"
            let account = (try? Data(contentsOf: URL(fileURLWithPath: config)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["oauthAccount"] as? [String: Any]
            return Profile(path: path, isStandard: standard, email: account?["emailAddress"] as? String,
                           organization: account?["organizationName"] as? String,
                           plan: (account?["organizationType"] as? String).flatMap(planName))
        }
    }

    static func planName(_ type: String) -> String? {
        switch type {
        case "claude_team": "Team"
        case "claude_enterprise": "Enterprise"
        case "claude_max": "Max"
        case "claude_pro": "Pro"
        default: nil
        }
    }

    /// Makes a conversation resumable under `target`: Claude keeps each one
    /// in its profile (`<profile>/projects/<folder for the cwd>/<id>.jsonl`),
    /// so one started under another account is copied across, with its
    /// sidecar folder. False when no profile has it.
    public static func carryConversation(_ id: String, into target: String, from profiles: [String],
                                         fileManager fm: FileManager = .default) -> Bool {
        let name = id + ".jsonl"
        func find(_ profile: String) -> URL? {
            let projects = URL(fileURLWithPath: profile).appendingPathComponent("projects")
            let folders = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            return folders.lazy.map { $0.appendingPathComponent(name) }.first { fm.fileExists(atPath: $0.path) }
        }
        if find(target) != nil { return true }
        for source in profiles where source != target {
            guard let file = find(source) else { continue }
            let folder = URL(fileURLWithPath: target).appendingPathComponent("projects")
                .appendingPathComponent(file.deletingLastPathComponent().lastPathComponent)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.copyItem(at: file, to: folder.appendingPathComponent(name))
            let sidecar = file.deletingPathExtension()
            if fm.fileExists(atPath: sidecar.path) { try? fm.copyItem(at: sidecar, to: folder.appendingPathComponent(id)) }
            return fm.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        return false
    }

    /// Claude couldn't sign in: an expired or revoked session, or none.
    public static func isSignInFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("failed to authenticate") || m.contains("oauth") || m.contains("please run /login")
            || m.contains("not logged in") || m.contains("invalid api key") || m.contains("authentication_error")
    }

    /// The command that signs a profile in, for a terminal.
    public static func loginCommand(_ profile: Profile) -> String {
        profile.isStandard ? "claude auth login" : "CLAUDE_CONFIG_DIR=\(profile.path) claude auth login"
    }

    /// The limits in a `rate_limit_event` line from `claude -p --output-format stream-json`.
    public static func quota(fromLine line: String, at now: Date = Date()) -> AccountQuota? {
        guard line.contains("rate_limit_event"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "rate_limit_event",
              let info = object["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any] else { return nil }
        func window(_ name: String) -> AccountQuota.Window? {
            guard let w = windows[name] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return .init(used: used, resetsAt: (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        return AccountQuota(session: window("five_hour"), weekly: window("seven_day"), observedAt: now)
    }
}

/// The Codex account signed in at `~/.codex`.
public enum CodexAccount {
    public struct Info: Sendable, Hashable {
        public var email: String?
        /// "Plus", "Pro", "Team", …
        public var plan: String?
    }

    /// Email and plan from the sign-in's identity claims; nothing else in the file is read.
    public static func info(home: String) -> Info? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.codex/auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (auth["tokens"] as? [String: Any])?["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let claims = Data(base64Encoded: payload).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return nil }
        let plan = ((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String)?.capitalized
        return Info(email: claims["email"] as? String, plan: plan)
    }

    /// The limits Codex last wrote to a session log, newest session first.
    public static func quota(home: String, fileManager fm: FileManager = .default) -> AccountQuota? {
        let sessions = LocalUsage.transcripts(under: home + "/.codex/sessions", fileManager: fm)
            .compactMap { url -> (URL, Date)? in
                (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date).map { (url, $0) }
            }
            .sorted { $0.1 > $1.1 }
        for (url, modified) in sessions.prefix(5) {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            for line in LocalUsage.lines(data, containing: #""rate_limits""#).reversed() {
                if let quota = quota(fromLine: line, fallbackDate: modified) { return quota }
            }
        }
        return nil
    }

    static func quota(fromLine line: Data, fallbackDate: Date) -> AccountQuota? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        func window(_ name: String) -> AccountQuota.Window? {
            guard let w = limits[name] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            return .init(used: used / 100, resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let credits = (limits["credits"] as? [String: Any])?["balance"].map { "\($0)" }
        let date = (object["timestamp"] as? String).flatMap(LocalUsage.parseDate) ?? fallbackDate
        return AccountQuota(session: window("primary"), weekly: window("secondary"), credits: credits, observedAt: date)
    }
}
