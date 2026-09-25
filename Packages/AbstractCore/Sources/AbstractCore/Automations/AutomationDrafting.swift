import Foundation

/// An automation drafted from a description in plain words by a headless
/// model call, for the automation page to fill in and you to review.
public enum AutomationDrafting {
    public struct Proposal: Sendable, Equatable {
        public var name: String
        /// What the agent does on every run, in Markdown.
        public var instructions: String
        /// RRULE bodies, each valid in `timezone`. Empty: only by hand.
        public var schedules: [String]
        /// One of the project names offered, or nil for none.
        public var project: String?
        /// Every run continues one chat of its own, rather than starting a new chat.
        public var continuesOwnChat: Bool
        public var policy: PermissionPolicy

        public init(name: String, instructions: String, schedules: [String], project: String?, continuesOwnChat: Bool,
                    policy: PermissionPolicy) {
            self.name = name; self.instructions = instructions; self.schedules = schedules; self.project = project
            self.continuesOwnChat = continuesOwnChat; self.policy = policy
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unsupportedAgent(String)
        case noAnswer(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedAgent(let name): "Drafting needs Claude or Codex; \(name) can't draft."
            case .noAnswer(let why): why
            }
        }
    }

    /// Longest description sent.
    static let descriptionLimit = 4_000

    public static func prompt(description: String, projects: [String], timezone: String, now: Date = Date()) -> String {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = text.count > descriptionLimit ? String(text.prefix(descriptionLimit)) + "…" : text
        let list = projects.isEmpty ? "(none)" : projects.map { "- \($0)" }.joined(separator: "\n")
        return """
            You set up automations for Abstract, a Mac app that runs coding agents in chats. An automation runs on a \
            schedule; each run sends its instructions to an agent in a chat. Turn the description below into one. \
            Reply with only a JSON object and nothing else:
            {"name": "…", "instructions": "…", "schedules": ["…"], "project": "…", "chat": "new", "permissions": "edits"}

            - name: what it does, at most 40 characters, in sentence case.
            - instructions: what the agent does on every run, written to the agent, in Markdown: the goal, concrete \
            steps, and what to report at the end. Leave the schedule out of it.
            - schedules: RFC 5545 RRULE bodies without "RRULE:", in the user's time zone, using FREQ (HOURLY, DAILY, \
            WEEKLY or MONTHLY), INTERVAL, BYDAY, BYMONTHDAY, BYHOUR and BYMINUTE. Every weekday at 9:00 is \
            FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0. An empty list when it only runs when started by hand.
            - project: exactly one of the project names listed when the description is about one of them, else null.
            - chat: "own" (one chat every run continues, so it remembers earlier runs) when runs build on each other, \
            or when the agent starts other chats to do the work, so it keeps track of the chats it started. "new" (a \
            fresh chat each run, in a worktree of its own) when the agent does the work itself and each run stands \
            alone. An agent starts chats, each in a new worktree of a project, with `abstract session create --project \
            <name> --name <title> --branch <branch> --agent claude --prompt-file -` (the prompt on stdin); say so in \
            the instructions when the work should be split into chats.
            - permissions: "edits" (file edits accepted) usually; "ask" only when the user wants to approve each \
            action; "full" only when they ask for full autonomy.

            Projects:
            \(list)

            Time zone: \(timezone). Now: \(now.formatted(.iso8601)).

            The description:
            <description>
            \(clipped)
            </description>
            """
    }

    /// `claude -p` with no tools, JSON output, the prompt on stdin.
    static let claudeArguments = ["-p", "--tools", "", "--model", "sonnet", "--output-format", "json", "--no-session-persistence"]

    static func launchSpec(home: String, binary: String?, providerId: String, model: String?, request: String) -> LaunchSpec? {
        switch providerId {
        case "claude":
            return LaunchSpec(command: binary ?? "claude", args: claudeArguments, cwd: home, stdinInitial: request, keepStdinOpen: false)
        case "codex":
            var args = ["exec", "--json", "-C", home, "--skip-git-repo-check", "-s", "read-only"]
            if let model { args += ["-m", model] }
            args += ["--", request]
            return LaunchSpec(command: binary ?? "codex", args: args, cwd: home, keepStdinOpen: false)
        default:
            return nil
        }
    }

    /// Asks the agent's CLI, for at most `timeout`.
    public static func draft(executor: any Executor, binary: String?, providerId: String, model: String? = nil,
                             description: String, projects: [String], timezone: String,
                             timeout: Duration = .seconds(90)) async throws -> Proposal {
        let request = prompt(description: description, projects: projects, timezone: timezone)
        guard let spec = launchSpec(home: executor.homeDirectory, binary: binary, providerId: providerId, model: model, request: request) else {
            throw Failure.unsupportedAgent(ProviderRegistry.name(providerId))
        }
        let result = try await executor.run(spec, timeout: timeout)
        if result.timedOut { throw Failure.noAnswer("\(ProviderRegistry.name(providerId)) didn't answer in time.") }
        guard result.ok else {
            throw Failure.noAnswer("\(ProviderRegistry.name(providerId)) couldn't draft it: \(result.lastLine ?? "it exited with an error").")
        }
        let parsed = providerId == "claude" ? parse(result.stdout) : parseCodex(result.stdout)
        guard let parsed else { throw Failure.noAnswer("The answer wasn't an automation. Try describing it again.") }
        return proposal(parsed, projects: projects, timezone: timezone)
    }

    /// The fields inside `claude --output-format json` output, whose
    /// `result` holds the object, possibly in a code fence.
    static func parse(_ output: String) -> [String: Any]? {
        guard let envelope = ChatNaming.firstObject(in: output), let data = envelope.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if outer["is_error"] as? Bool == true { return nil }
        return fields(in: (outer["result"] as? String) ?? envelope)
    }

    /// Codex writes one event per line; the last agent message holds the object.
    static func parseCodex(_ output: String) -> [String: Any]? {
        var found: [String: Any]?
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String, let object = fields(in: text) else { continue }
            found = object
        }
        return found
    }

    private static func fields(in text: String) -> [String: Any]? {
        guard let object = ChatNaming.lastObject(in: text), let data = object.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any], fields["instructions"] != nil else { return nil }
        return fields
    }

    /// What the page can use: a rule that doesn't hold is dropped, a
    /// project that isn't one of yours is none.
    static func proposal(_ fields: [String: Any], projects: [String], timezone: String) -> Proposal {
        let name = ((fields["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let schedules = ((fields["schedules"] as? [Any]) ?? []).compactMap { $0 as? String }.compactMap { raw -> String? in
            var rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if rule.uppercased().hasPrefix("RRULE:") { rule = String(rule.dropFirst(6)) }
            return (try? Schedule.validate(rrule: rule, timezone: timezone)) != nil ? rule : nil
        }
        let project = (fields["project"] as? String).flatMap { wanted in
            projects.first { $0 == wanted } ?? projects.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        let policy: PermissionPolicy = switch fields["permissions"] as? String {
        case "ask": .ask
        case "full": .bypass
        default: .autoEdits
        }
        return Proposal(name: String(name.prefix(60)), instructions: ((fields["instructions"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        schedules: schedules, project: project, continuesOwnChat: fields["chat"] as? String == "own", policy: policy)
    }
}
