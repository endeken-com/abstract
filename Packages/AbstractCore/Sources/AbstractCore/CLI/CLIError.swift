import Foundation

/// Why an `abstract` command failed. Printed as `{"code","message"}` on
/// stdout, with a non-zero exit status.
public struct CLIError: Error, Equatable, Sendable {
    public enum Code: String, Sendable, Codable, CaseIterable {
        /// The command line itself is wrong: an unknown command or option, a missing
        /// or repeated one, an empty or unreadable prompt, an invalid branch name.
        case invalidArguments = "invalid_arguments"
        case projectNotFound = "project_not_found"
        case sessionNotFound = "session_not_found"
        /// Not an agent `abstract` can drive.
        case unknownAgent = "unknown_agent"
        /// An unarchived session in the project already has the name.
        case nameTaken = "name_taken"
        /// The branch exists already.
        case branchExists = "branch_exists"
        /// The session is open in the app, or another command is working on it.
        case sessionLocked = "session_locked"
        case agentNotRunning = "agent_not_running"
        case agentAlreadyRunning = "agent_already_running"
        /// The agent didn't come up. `create` rolled everything back.
        case agentStartFailed = "agent_start_failed"
        /// The session has no worktree to run an agent in any more.
        case worktreeMissing = "worktree_missing"
        /// git couldn't create the worktree (a missing base ref, say).
        case worktreeFailed = "worktree_failed"
        case internalError = "internal"
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code; self.message = message
    }

    /// 2 for a malformed command line, 1 for everything else.
    public var exitStatus: Int32 { code == .invalidArguments ? 2 : 1 }
}
