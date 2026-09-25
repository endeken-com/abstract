import Foundation

/// A chat's summarized title from a quick headless model call. Project
/// instructions may also supply a branch name. A failed call returns nil.
public enum ChatNaming {
    public struct Suggestion: Sendable, Hashable {
        public var title: String
        /// Safe for a branch: kebab-case, possibly with a type folder (`fix/…`).
        public var branch: String
        public init(title: String, branch: String) { self.title = title; self.branch = branch }
    }

    /// Longest task text sent: enough to name it, short enough to stay quick.
    static let taskLimit = 2_000

    /// `claude -p` with no tools, the small model and JSON output, reading
    /// the prompt from stdin (`--tools` takes several values, so a prompt
    /// argument after it would be read as one).
    public static let arguments = ["-p", "--tools", "", "--model", "haiku", "--output-format", "json",
                                   "--no-session-persistence"]

    public static func prompt(instructions: String, task: String) -> String {
        let task = task.count > taskLimit ? String(task.prefix(taskLimit)) + "…" : task
        let guidance = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            Summarize this coding request as a short chat title. Reply with only a JSON object and nothing else:
            {"title": "…", "branch": "…"}

            - title: a short chat title for the task, at most 60 characters, in plain words.
            - branch: a git branch name for the work: lowercase kebab-case words, at most 60 characters, \
            no spaces. It may start with a type folder such as fix/ or feat/ when the instructions say so.

            Follow these naming instructions from the project when provided:
            <instructions>
            \(guidance)
            </instructions>

            The task:
            <task>
            \(task.trimmingCharacters(in: .whitespacesAndNewlines))
            </task>
            """
    }

    /// The suggestion inside `claude --output-format json` output: its
    /// `result` text holds the JSON object, possibly in a code fence.
    public static func parse(_ output: String) -> Suggestion? {
        guard let envelope = firstObject(in: output),
              let data = envelope.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if outer["is_error"] as? Bool == true { return nil }
        let text = (outer["result"] as? String) ?? envelope
        guard let inner = lastObject(in: text), let innerData = inner.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let rawTitle = fields["title"] as? String else { return nil }
        let title = cleanTitle(rawTitle)
        guard !title.isEmpty else { return nil }
        let branch = (fields["branch"] as? String).flatMap { WorktreeNaming.branchSlug($0) } ?? WorktreeNaming.slugify(title)
        return Suggestion(title: title, branch: branch)
    }

    /// Runs the selected provider's CLI for at most `timeout`.
    public static func suggest(executor: any Executor, binary: String?, providerId: String = "claude", model: String? = nil,
                               instructions: String, task: String,
                               timeout: Duration = .seconds(20)) async -> Suggestion? {
        guard let spec = launchSpec(home: executor.homeDirectory, binary: binary, providerId: providerId, model: model,
                                    instructions: instructions, task: task) else { return nil }
        guard let result = try? await executor.run(spec, timeout: timeout), result.ok else { return nil }
        return providerId == "claude" ? parse(result.stdout) : parseCodex(result.stdout)
    }

    static func launchSpec(home: String, binary: String?, providerId: String, model: String?,
                           instructions: String, task: String) -> LaunchSpec? {
        let request = prompt(instructions: instructions, task: task)
        if providerId == "claude" {
            return LaunchSpec(command: binary ?? "claude", args: arguments, cwd: home,
                              stdinInitial: request, keepStdinOpen: false)
        }
        guard providerId == "codex" else { return nil }
        var args = ["exec", "--json", "-C", home, "--skip-git-repo-check", "-s", "read-only"]
        if let model { args += ["-m", model] }
        args += ["--", request]
        return LaunchSpec(command: binary ?? "codex", args: args, cwd: home,
                          stdinInitial: nil, keepStdinOpen: false)
    }

    /// Codex writes one event per line; the final agent message contains the
    /// requested JSON, and earlier messages may be commentary.
    static func parseCodex(_ output: String) -> Suggestion? {
        var suggestion: Suggestion?
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String else { continue }
            if let parsed = parse(text) { suggestion = parsed }
        }
        return suggestion
    }

    /// One line, no surrounding quotes, clipped like `Workspace.title`.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw.components(separatedBy: .newlines).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”").union(.whitespaces))
        return title.count > 60 ? String(title.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : title
    }

    /// From the first `{` to its matching `}`.
    static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for i in text[start...].indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true } else if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
        }
        return nil
    }

    /// The last balanced object: a model that explains before answering
    /// still ends with the answer.
    static func lastObject(in text: String) -> String? {
        var rest = Substring(text)
        var found: String?
        while let object = firstObject(in: String(rest)) {
            found = object
            guard let range = rest.range(of: object) else { break }
            rest = rest[range.upperBound...]
        }
        return found
    }
}
