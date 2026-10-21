import Foundation

/// One page of a plugin data pull (ABS-95). The snapshot stays small; the
/// bigger read grants are pulled a page at a time instead.
public struct PluginPage: Sendable, Hashable {
    public var offset: Int
    public var limit: Int

    public static let defaultLimit = 50
    public static let maxLimit = 200

    public init(offset: Int = 0, limit: Int = defaultLimit) {
        self.offset = max(0, offset)
        self.limit = min(Self.maxLimit, max(1, limit))
    }

    public init(payload: JSONValue?) {
        self.init(offset: payload?["offset"]?.int ?? 0,
                  limit: payload?["limit"]?.int ?? Self.defaultLimit)
    }

    public func slice<T>(_ items: [T]) -> ArraySlice<T> {
        items.dropFirst(offset).prefix(limit)
    }
}

/// The payloads behind `usage.read`, `turns.read`, `transcripts.read`,
/// `automations.read` and `pullRequests.read`. Each builder encodes only its allowlisted fields;
/// nothing else about a chat, a file or an automation is ever included.
public enum PluginData {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func envelope(items: [JSONValue], total: Int, page: PluginPage) -> JSONValue {
        .object([
            "items": .array(items),
            "total": .number(Double(total)),
            "offset": .number(Double(page.offset)),
            "limit": .number(Double(page.limit)),
            "hasMore": .bool(page.offset + items.count < total),
        ])
    }

    // MARK: Usage

    /// One model response from the Usage ledger, with the chat it ran in
    /// resolved by the host (nil when it ran outside any chat).
    public struct UsageEntry: Sendable, Hashable {
        public var chatId: String?
        public var agentId: String
        public var model: String
        public var at: Date
        public var tokens: LocalUsage.Tokens
        /// The agent's own figure when it logged one, else the list price
        /// — the same figure Settings → Usage shows.
        public var costUsd: Double
        public var estimated: Bool

        public init(chatId: String?, record: LocalUsage.Record) {
            self.chatId = chatId
            agentId = record.provider.rawValue
            model = record.model
            at = record.date
            tokens = record.tokens
            let priced = ModelPricing.price(record)
            costUsd = priced.cost
            estimated = priced.estimated
        }

        public init(chatId: String?, agentId: String, model: String, at: Date,
                    tokens: LocalUsage.Tokens, costUsd: Double, estimated: Bool) {
            self.chatId = chatId; self.agentId = agentId; self.model = model; self.at = at
            self.tokens = tokens; self.costUsd = costUsd; self.estimated = estimated
        }
    }

    static func tokenFields(_ tokens: LocalUsage.Tokens) -> [String: JSONValue] {
        [
            "inputTokens": .number(Double(tokens.input)),
            "outputTokens": .number(Double(tokens.output)),
            "cacheReadTokens": .number(Double(tokens.cacheRead)),
            "cacheWriteTokens": .number(Double(tokens.cacheWrite)),
            "totalTokens": .number(Double(tokens.total)),
        ]
    }

    /// `view` is `chats` (a total per chat), `entries` (one row per model
    /// response, newest first) or `days` (a total per day and agent).
    public static func usage(entries: [UsageEntry], view: String, chatId: String?,
                             page: PluginPage, calendar: Calendar = .current) -> JSONValue {
        let rows = chatId.map { id in entries.filter { $0.chatId == id } } ?? entries
        switch view {
        case "entries":
            let sorted = rows.sorted { $0.at > $1.at }
            let items = page.slice(sorted).map { entry -> JSONValue in
                var object = tokenFields(entry.tokens)
                object["at"] = .string(iso(entry.at))
                object["agentId"] = .string(entry.agentId)
                object["model"] = .string(entry.model)
                object["costUsd"] = .number(entry.costUsd)
                object["estimated"] = .bool(entry.estimated)
                if let chatId = entry.chatId { object["chatId"] = .string(chatId) }
                return .object(object)
            }
            return envelope(items: items, total: sorted.count, page: page)
        case "days":
            struct Key: Hashable { var day: String; var agentId: String }
            var totals: [Key: (LocalUsage.Tokens, Double)] = [:]
            for entry in rows {
                let c = calendar.dateComponents([.year, .month, .day], from: entry.at)
                let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
                let old = totals[Key(day: day, agentId: entry.agentId)] ?? (LocalUsage.Tokens(), 0)
                totals[Key(day: day, agentId: entry.agentId)] = (old.0 + entry.tokens, old.1 + entry.costUsd)
            }
            let sorted = totals.sorted { ($0.key.day, $0.key.agentId) > ($1.key.day, $1.key.agentId) }
            let items = page.slice(sorted).map { key, value -> JSONValue in
                var object = tokenFields(value.0)
                object["day"] = .string(key.day)
                object["agentId"] = .string(key.agentId)
                object["costUsd"] = .number(value.1)
                return .object(object)
            }
            return envelope(items: items, total: sorted.count, page: page)
        default:
            var byChat: [String: (LocalUsage.Tokens, Double, Int, Date)] = [:]
            for entry in rows {
                guard let chatId = entry.chatId else { continue }
                let old = byChat[chatId] ?? (LocalUsage.Tokens(), 0, 0, entry.at)
                byChat[chatId] = (old.0 + entry.tokens, old.1 + entry.costUsd, old.2 + 1, max(old.3, entry.at))
            }
            let sorted = byChat.sorted { $0.value.3 > $1.value.3 }
            let items = page.slice(sorted).map { chatId, value -> JSONValue in
                var object = tokenFields(value.0)
                object["chatId"] = .string(chatId)
                object["costUsd"] = .number(value.1)
                object["responses"] = .number(Double(value.2))
                object["lastAt"] = .string(iso(value.3))
                return .object(object)
            }
            return envelope(items: items, total: sorted.count, page: page)
        }
    }

    // MARK: Turns

    /// Every finished turn's line (ABS-59): when it ran, how it ended and
    /// what the agent said it did. Chats keep the host's order.
    public static func turns(chats: [(chatId: String, timeline: Timeline)], page: PluginPage) -> JSONValue {
        var all: [JSONValue] = []
        for chat in chats {
            var index = 0
            for case let .turn(_, info) in chat.timeline.blocks {
                index += 1
                var object: [String: JSONValue] = [
                    "chatId": .string(chat.chatId),
                    "turn": .number(Double(index)),
                    "outcome": .string(outcome(info.ending)),
                ]
                if let startedAt = info.startedAt { object["startedAt"] = .string(iso(startedAt)) }
                if let endedAt = info.endedAt { object["endedAt"] = .string(iso(endedAt)) }
                if let durationMs = info.durationMs { object["durationMs"] = .number(Double(durationMs)) }
                if let summary = info.summary { object["summary"] = .string(summary) }
                all.append(.object(object))
            }
        }
        return envelope(items: Array(page.slice(all)), total: all.count, page: page)
    }

    static func outcome(_ ending: TurnInfo.Ending) -> String {
        switch ending {
        case .done: "done"
        case .stopped: "stopped"
        case .failed: "failed"
        }
    }

    // MARK: Transcripts

    /// Messages from chats in the picked projects only. Included: your
    /// messages, the agent's replies, tool names, the file paths a tool
    /// was aimed at, and pull-request and commit references in the text.
    /// Never included: file contents, tool input beyond its paths, or
    /// anything a tool printed.
    public static func transcript(chats: [(chatId: String, projectKey: String?, timeline: Timeline)],
                                  allowedProjectKeys: Set<String>, page: PluginPage) -> JSONValue {
        var all: [JSONValue] = []
        for chat in chats {
            guard let projectKey = chat.projectKey, allowedProjectKeys.contains(projectKey) else { continue }
            for entry in chat.timeline.entries {
                switch entry.event {
                case let .text(role, text, _, partial) where !partial:
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    var object: [String: JSONValue] = [
                        "chatId": .string(chat.chatId),
                        "projectKey": .string(projectKey),
                        "kind": .string(role.rawValue),
                        "text": .string(text),
                        "references": references(in: text),
                    ]
                    if let at = entry.at { object["at"] = .string(iso(at)) }
                    all.append(.object(object))
                case let .toolUse(_, name, input, edit):
                    var paths = filePaths(in: input)
                    if let edit, !paths.contains(edit.filePath) { paths.append(edit.filePath) }
                    var object: [String: JSONValue] = [
                        "chatId": .string(chat.chatId),
                        "projectKey": .string(projectKey),
                        "kind": .string("tool"),
                        "toolName": .string(name),
                        "filePaths": .array(paths.map(JSONValue.string)),
                    ]
                    if let at = entry.at { object["at"] = .string(iso(at)) }
                    all.append(.object(object))
                default:
                    continue
                }
            }
        }
        return envelope(items: Array(page.slice(all)), total: all.count, page: page)
    }

    /// Only the paths a tool call was aimed at — never what it read or wrote.
    static func filePaths(in input: JSONValue) -> [String] {
        var paths: [String] = []
        for key in ["file_path", "filePath", "path", "notebook_path"] {
            if let path = input[key]?.string, !paths.contains(path) { paths.append(path) }
        }
        for key in ["paths", "files", "file_paths"] {
            for case let .string(path) in input[key]?.array ?? [] where !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    static func references(in text: String) -> JSONValue {
        var pullRequests: [Int] = []
        var commits: [String] = []
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        for number in matches(#"(?:#|pull/)(\d{1,9})\b"#) {
            if let value = Int(number), !pullRequests.contains(value) { pullRequests.append(value) }
        }
        for sha in matches(#"\b([0-9a-f]{7,40})\b"#)
        where sha.contains(where: \.isLetter) && sha.contains(where: \.isNumber) && !commits.contains(sha) {
            commits.append(sha)
        }
        return .object([
            "pullRequests": .array(pullRequests.map { .number(Double($0)) }),
            "commits": .array(commits.map(JSONValue.string)),
        ])
    }

    // MARK: Automations

    /// Names, schedules, and when each last ran and how. An automation's
    /// instructions are never included.
    public static func automations(items: [(automation: Automation, projectKey: String?, lastRun: AutomationRun?)],
                                   page: PluginPage) -> JSONValue {
        let all = items.map { item -> JSONValue in
            var object: [String: JSONValue] = [
                "id": .string(item.automation.id),
                "name": .string(item.automation.name),
                "agentId": .string(item.automation.providerId),
                "enabled": .bool(item.automation.enabled),
                "schedules": .array(item.automation.triggers.map {
                    .object(["rrule": .string($0.rrule), "timezone": .string($0.timezone)])
                }),
            ]
            if let projectKey = item.projectKey { object["projectKey"] = .string(projectKey) }
            if let nextRunAt = item.automation.nextRunAt { object["nextRunAt"] = .string(iso(nextRunAt)) }
            if let run = item.lastRun {
                var lastRun: [String: JSONValue] = [
                    "at": .string(iso(run.firedAt)),
                    "outcome": .string(run.status.rawValue),
                ]
                if let chatId = run.sessionId { lastRun["chatId"] = .string(chatId) }
                object["lastRun"] = .object(lastRun)
            }
            return .object(object)
        }
        return envelope(items: Array(page.slice(all)), total: all.count, page: page)
    }

    // MARK: Pull requests (ABS-109)

    /// Longest text one review or comment carries; GitHub allows far more.
    public static let pullRequestTextLimit = 4_000

    /// A chat's pull request as its Pull Request tab shows it: checks,
    /// reviews, comments, and the threads on its code. No avatars, and
    /// nothing about the repository beyond the pull request's own link.
    public static func pullRequest(_ pr: PullRequest) -> JSONValue {
        func text(_ body: String) -> JSONValue {
            .string(body.count > pullRequestTextLimit ? body.prefix(pullRequestTextLimit - 1) + "…" : body)
        }
        func date(_ value: Date?) -> JSONValue { value.map { .string(iso($0)) } ?? .null }
        func optional(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
        let outcome: [PullRequest.Check.Outcome: String] = [.pending: "pending", .passed: "passed", .failed: "failed", .skipped: "skipped"]
        let verdict: [PullRequest.Review.Verdict: String] = [
            .approved: "approved", .changesRequested: "changesRequested", .commented: "commented",
            .dismissed: "dismissed", .pending: "pending",
        ]
        var object: [String: JSONValue] = [
            "number": .number(Double(pr.number)),
            "title": .string(pr.title),
            "state": .string(pr.state.rawValue.lowercased()),
            "isDraft": .bool(pr.isDraft),
            "url": pr.url.map { .string($0.absoluteString) } ?? .null,
            "checks": .array(pr.checks.map { check in
                .object(["name": .string(check.name), "workflow": check.workflow.map(JSONValue.string) ?? .null,
                         "outcome": .string(outcome[check.outcome] ?? "pending"),
                         "url": check.url.map { .string($0.absoluteString) } ?? .null])
            }),
            "reviews": .array(pr.reviews.map { review in
                .object(["author": .string(review.author), "verdict": .string(verdict[review.verdict] ?? "commented"),
                         "body": text(review.body), "submittedAt": date(review.submittedAt)])
            }),
            "comments": .array(pr.comments.map { comment in
                .object(["author": .string(comment.author), "body": text(comment.body),
                         "createdAt": date(comment.createdAt), "isBot": .bool(comment.isBot)])
            }),
            "threads": .array(pr.threads.map { thread in
                .object(["id": .string(thread.id), "path": .string(thread.path),
                         "line": optional(thread.line), "originalLine": optional(thread.originalLine),
                         "isResolved": .bool(thread.isResolved), "isOutdated": .bool(thread.isOutdated),
                         "comments": .array(thread.comments.map { comment in
                             .object(["id": .string(comment.id), "author": .string(comment.author), "body": text(comment.body),
                                      "createdAt": date(comment.createdAt),
                                      "url": comment.url.map { .string($0.absoluteString) } ?? .null])
                         })])
            }),
        ]
        if let decision = pr.reviewDecision { object["reviewDecision"] = .string(decision.rawValue.lowercased()) }
        return .object(object)
    }
}
