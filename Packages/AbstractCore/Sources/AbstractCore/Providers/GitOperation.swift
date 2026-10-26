import Foundation

/// Git activity attributed to a command that has finished successfully.
public enum GitOperation: Sendable, Hashable {
    case commit(sha: String, kind: String, branch: String?)
    case push(branch: String?)
    case pullRequest(number: Int, url: URL?, action: String)

    /// Claude's `tool_use_result.gitOperation` can describe several operations
    /// from one Bash invocation.
    public static func claude(_ value: JSONValue?) -> [GitOperation] {
        guard let value, value.object != nil else { return [] }
        var operations: [GitOperation] = []
        if let commit = value["commit"], let sha = commit["sha"]?.string, !sha.isEmpty {
            operations.append(.commit(sha: sha, kind: commit["kind"]?.string ?? "committed",
                                      branch: commit["branch"]?.string))
        }
        if let push = value["push"], push.object != nil {
            operations.append(.push(branch: push["branch"]?.string))
        }
        if let pr = value["pr"], let number = pr["number"]?.int,
           let action = pr["action"]?.string {
            operations.append(.pullRequest(number: number, url: pr["url"]?.string.flatMap(URL.init(string:)), action: action))
        }
        return operations
    }

    /// Other agents provide command text and output, but no classification.
    /// Limit PR detection to a successful `gh pr create` and a GitHub PR URL.
    public static func fallback(command: String, output: String, succeeded: Bool) -> [GitOperation] {
        guard succeeded else { return [] }
        var operations: [GitOperation] = []
        if command.range(of: #"\bgh\s+pr\s+create\b"#, options: .regularExpression) != nil,
           let match = output.range(of: #"https://[^\s/]+/[^\s/]+/[^\s/]+/pull/[0-9]+"#, options: .regularExpression),
           let url = URL(string: String(output[match])),
           let number = Int(url.lastPathComponent) {
            operations.append(.pullRequest(number: number, url: url, action: "created"))
        }
        if command.range(of: #"\bgit\s+push\b"#, options: .regularExpression) != nil {
            operations.append(.push(branch: nil))
        }
        return operations
    }
}
