import Foundation

/// A chat's title and branch from a quick headless model call, following a
/// project's naming instructions. Any failure returns nil and the caller
/// keeps its usual naming.
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
        return """
            Name a coding task for a developer tool. Reply with only a JSON object and nothing else:
            {"title": "…", "branch": "…"}

            - title: a short chat title for the task, at most 60 characters, in plain words.
            - branch: a git branch name for the work: lowercase kebab-case words, at most 60 characters, \
            no spaces. It may start with a type folder such as fix/ or feat/ when the instructions say so.

            Follow these naming instructions from the project:
            <instructions>
            \(instructions.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// Runs the CLI (`binary`, else `claude` on the login PATH) for at most
    /// `timeout`.
    public static func suggest(executor: any Executor, binary: String?, instructions: String, task: String,
                               timeout: Duration = .seconds(20)) async -> Suggestion? {
        let spec = LaunchSpec(command: binary ?? "claude", args: arguments, cwd: executor.homeDirectory,
                              stdinInitial: prompt(instructions: instructions, task: task), keepStdinOpen: false)
        guard let result = try? await executor.run(spec, timeout: timeout), result.ok else { return nil }
        return parse(result.stdout)
    }

    /// One line, no surrounding quotes, clipped like `Workspace.title`.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw.components(separatedBy: .newlines).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”").union(.whitespaces))
        return title.count > 60 ? String(title.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : title
    }

    /// From the first `{` to its matching `}`.
    private static func firstObject(in text: String) -> String? {
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
    private static func lastObject(in text: String) -> String? {
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
