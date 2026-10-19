import Foundation

/// Turn records for chats from before Abstract kept them, read from their
/// logs. A log has no `HEAD`s, so a turn's commits are the ones git printed
/// when the agent committed (`[branch 1a2b3c4] …`), or, as agents often
/// commit quietly, the ones whose subject its `git commit` commands carry;
/// its pull request is the one `gh pr create` printed.
public enum HistoryBackfill {
    /// One turn as its log reads.
    struct LoggedTurn {
        var lines: ClosedRange<Int>
        var transcript: TurnTranscript
        /// Abbreviated, as git printed them.
        var commits: [String]
        /// The commands it committed with, for the messages they carry.
        var commitCommands: [String]
        var pullRequest: Int?
    }

    private static let commitPattern = try! NSRegularExpression(pattern: #"\[[^\]\s]+(?: \(root-commit\))? ([0-9a-f]{7,40})\] "#)
    private static let pullRequestPattern = try! NSRegularExpression(pattern: #"https://github\.com/[^/\s]+/[^/\s]+/pull/([0-9]+)"#)

    /// Splits a chat's log into turns: one ends when the agent goes idle,
    /// finishes or fails, or, for an agent that doesn't say (OpenCode), when
    /// your next message comes after it reported the end of a step.
    static func turns(_ lines: [(seq: Int, line: OutputLine)], providerId: String) -> [LoggedTurn] {
        let stream = ChatStream(providerId: ChatStream.firstProvider(in: lines.map(\.line), current: providerId))
        var turns: [LoggedTurn] = []
        var current: [(seq: Int, events: [AgentEvent], at: Date?)] = []
        var ended = false
        var reported = false
        func close() {
            defer { current = []; ended = false; reported = false }
            guard let first = current.first?.seq, let last = current.last?.seq else { return }
            var timeline = Timeline()
            for line in current { timeline.append(contentsOf: line.events, at: line.at) }
            let transcript = TurnTranscript(timeline.entries)
            guard transcript.request != nil || transcript.worked else { return }
            let shipped = Self.shipped(timeline.entries)
            turns.append(LoggedTurn(lines: first...last, transcript: transcript, commits: shipped.commits,
                                    commitCommands: shipped.commands, pullRequest: shipped.pullRequest))
        }
        for (seq, line) in lines {
            let events = stream.feed(line)
            if events.contains(where: { if case .text(.user, _, _, _) = $0 { true } else { false } }), ended || reported { close() }
            current.append((seq, events, line.at))
            for event in events {
                switch event {
                case .status(.idle, _), .status(.finished, _), .status(.errored, _): ended = true
                case .turnEnd, .usage: reported = true
                case .text(.user, _, _, _): reported = false
                default: break
                }
            }
            if ended, events.contains(where: { if case .status = $0 { true } else { false } }) { close() }
        }
        close()
        return turns
    }

    /// The commits and pull request the agent's commands reported making.
    static func shipped(_ entries: [TimelineEntry]) -> (commits: [String], commands: [String], pullRequest: Int?) {
        var inputs: [String: String] = [:]
        var commits: [String] = []
        var commands: [String] = []
        var pullRequest: Int?
        func read(_ event: AgentEvent) {
            switch event {
            case let .toolUse(id, _, input, _):
                let command = strings(input).joined(separator: "\n")
                inputs[id] = command
                if command.contains("git commit") || command.contains("git -C") && command.contains(" commit") { commands.append(command) }
            case let .toolResult(id, output, false, _):
                let ns = output as NSString
                let all = NSRange(location: 0, length: ns.length)
                let command = inputs[id] ?? ""
                if command.contains("commit") {
                    for m in commitPattern.matches(in: output, range: all) {
                        let sha = ns.substring(with: m.range(at: 1))
                        if !commits.contains(sha) { commits.append(sha) }
                    }
                }
                if command.contains("pr create"), let m = pullRequestPattern.firstMatch(in: output, range: all) {
                    pullRequest = Int(ns.substring(with: m.range(at: 1)))
                }
            case let .subagent(_, inner):
                read(inner)
            default:
                break
            }
        }
        for entry in entries { read(entry.event) }
        return (commits, commands, pullRequest)
    }

    private static func strings(_ value: JSONValue) -> [String] {
        switch value {
        case let .string(s): [s]
        case let .array(a): a.flatMap(strings)
        case let .object(o): o.keys.sorted().flatMap { strings(o[$0]!) }
        default: []
        }
    }

    /// A subject shorter than this ("Fix", "WIP") says too little to match on.
    static let shortestSubject = 12

    /// Every commit `repo` has, with its subject, for
    /// matching the messages of quiet commits.
    public static func subjects(_ exec: any Executor, repo: String) async -> [(sha: String, subject: String)] {
        guard let out = try? await Git.git(exec, cwd: repo, ["log", "--all", "--format=%H%x00%s"]), out.ok else { return [] }
        return GitText.lines(out.stdout).compactMap { line in
            let parts = line.components(separatedBy: "\0")
            return parts.count == 2 && parts[1].count >= shortestSubject ? (parts[0], parts[1]) : nil
        }
    }

    /// Records the turns of `session`'s log that aren't recorded yet, with
    /// the commits they reported making that `repo` has. Returns them.
    @discardableResult
    /// `subjects`: the repository's commits (`subjects(_:repo:)`), for
    /// commits made quietly.
    public static func backfill(_ session: Session, lines: [(seq: Int, line: OutputLine)], store: Store, exec: any Executor,
                                repo: String, subjects: [(sha: String, subject: String)] = []) async -> [TurnRecord] {
        let previous = try? store.lastTurnRecord(sessionId: session.id)
        let fresh = lines.filter { $0.seq > (previous?.logEnd ?? 0) }
        var number = previous?.number ?? 0
        var records: [TurnRecord] = []
        for turn in turns(fresh, providerId: session.handoffFrom ?? session.providerId) {
            var shas: [String] = []
            for short in turn.commits {
                if let sha = await Shipping.revision(exec, repo, short), !shas.contains(sha) { shas.append(sha) }
            }
            for command in turn.commitCommands {
                for (sha, subject) in subjects where !shas.contains(sha) && command.contains(subject) { shas.append(sha) }
            }
            var files = Set(turn.transcript.editedPaths.compactMap { path in
                session.worktreePath.flatMap { TurnTranscript.relative(path, to: $0) } ?? (path.hasPrefix("/") ? nil : path)
            })
            var patchIds: [String: String] = [:]
            if !shas.isEmpty {
                patchIds = await TurnGit.patchIds(exec, cwd: repo, ["log", "--no-walk=unsorted", "--no-merges"] + shas)
                if let out = try? await Git.git(exec, cwd: repo, ["show", "--no-walk=unsorted", "--format=", "--name-only"] + shas), out.ok {
                    files.formUnion(GitText.lines(out.stdout).map(GitText.trimmed).filter { !$0.isEmpty })
                }
            }
            number += 1
            let summary = SecretMasking.mask(turn.transcript.summary)
            let record = TurnRecord(
                projectId: session.projectId, sessionId: session.id, chatName: session.name, providerId: session.providerId,
                number: number, startedAt: turn.transcript.startedAt, endedAt: turn.transcript.endedAt,
                request: SecretMasking.mask(turn.transcript.request),
                corrections: turn.transcript.corrections.map(SecretMasking.mask), summary: summary,
                decision: HistoryEntry.derivedDecision(from: summary),
                files: files.sorted(), branch: session.branch, pullRequest: turn.pullRequest,
                ticket: TurnRecorder.ticket(pullRequestBody: nil, branch: session.branch),
                logStart: turn.lines.lowerBound, logEnd: turn.lines.upperBound)
            do {
                try store.save(record)
                try store.link(shas.map { TurnCommit(sha: $0, turnId: record.id, link: .turn, patchId: patchIds[$0]) })
            } catch { continue }
            records.append(record)
        }
        // A pull request one turn opened is the whole chat's.
        if let number = records.lazy.compactMap(\.pullRequest).last {
            _ = try? store.setPullRequest(number, ticket: nil, sessionId: session.id)
        }
        return records
    }
}

/// How much of a branch's history leads back to a turn, and why the rest doesn't.
public struct HistoryCoverage: Sendable {
    public struct Miss: Sendable, Hashable {
        public var sha: String
        public var subject: String
        public var reason: String
    }

    public var commits = 0
    /// Commits traced to a turn, by how.
    public var mapped: [CommitLink: Int] = [:]
    public var misses: [Miss] = []

    public var mappedCount: Int { mapped.values.reduce(0, +) }

    /// The commits of `ref` since `since` (a date git reads), each traced
    /// with `history`. `pullRequests`: number → head branch.
    public static func measure(_ history: TurnHistory, exec: any Executor, repo: String, ref: String, since: String,
                               pullRequests: [Int: String]) async throws -> HistoryCoverage {
        let shas = GitText.lines(try await Git.gitOK(exec, cwd: repo, ["rev-list", "--since=\(since)", ref])).map(GitText.trimmed)
        // Which pull request each commit came in with: what its merge brought.
        var mergedBy: [String: Int] = [:]
        for sha in shas {
            guard let facts = await TurnHistory.facts(sha, exec: exec, repo: repo), facts.parents.count == 2,
                  let pr = TurnHistory.pullRequest(subject: facts.subject, parents: 2) else { continue }
            let brought = GitText.lines((try? await Git.gitOK(exec, cwd: repo, ["rev-list", "\(facts.parents[0])..\(facts.parents[1])"])) ?? "")
            for c in brought { mergedBy[GitText.trimmed(c)] = mergedBy[GitText.trimmed(c)] ?? pr.number }
        }
        var coverage = HistoryCoverage()
        for sha in shas {
            guard let origin = await history.origin(of: sha, exec: exec, repo: repo, pullRequests: pullRequests) else { continue }
            coverage.commits += 1
            if let link = origin.link, !origin.turns.isEmpty {
                coverage.mapped[link, default: 0] += 1
                continue
            }
            let reason: String
            if let pr = origin.pullRequest ?? mergedBy[sha] {
                let known = !((try? history.store.turnRecords(projectId: history.projectId, pullRequest: pr)) ?? []).isEmpty
                    || pullRequests[pr].map { !((try? history.store.turnRecords(projectId: history.projectId, branch: $0)) ?? []).isEmpty } == true
                if origin.pullRequest != nil {
                    reason = known ? "merges a pull request whose chat has no turn records" : "merges a pull request whose chat is gone"
                } else {
                    reason = known ? "on a pull request's branch, but no turn of its chat made it (by hand, or outside the log)"
                        : "on a pull request's branch whose chat is gone"
                }
            } else {
                reason = "committed straight to \(ref), outside a pull request"
            }
            coverage.misses.append(Miss(sha: sha, subject: origin.subject, reason: reason))
        }
        return coverage
    }

    /// The share, how commits were traced, and the misses grouped by why.
    public var report: String {
        let share = commits == 0 ? 0 : Double(mappedCount) / Double(commits) * 100
        var lines = [String(format: "%d of %d commits map to a turn (%.0f%%).", mappedCount, commits, share)]
        for link in CommitLink.allCases where mapped[link] != nil {
            lines.append("  \(link.rawValue): \(mapped[link]!)")
        }
        let reasons = Dictionary(grouping: misses, by: \.reason).sorted { $0.value.count > $1.value.count }
        if !reasons.isEmpty { lines.append("Not mapped:") }
        for (reason, misses) in reasons { lines.append("  \(misses.count): \(reason)") }
        return lines.joined(separator: "\n")
    }
}
