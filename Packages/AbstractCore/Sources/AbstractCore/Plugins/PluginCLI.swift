import Foundation

// Plugins that run a command-line tool (ABS-139). A plugin with `cli`
// names one binary, how to install it, and the exact subcommands it may
// run, each marked read or write. The host runs only those, with no
// shell, in a project folder or chat worktree the plugin can read,
// through that chat's executor. Reads go through the app-wide git budget;
// writes ask first (ABS-92) unless the person started them. The rules
// live here.

/// The `cli` block of a manifest, and what a record keeps of it once
/// granted.
public struct PluginCLI: Sendable, Hashable, Codable {
    /// A plain name looked up on the login shell's PATH, like `gh`.
    public var binary: String
    /// How to install it, shown when it's missing: "brew install gh".
    public var install: String?
    public var commands: [Command]

    public struct Command: Sendable, Hashable, Codable {
        public enum Access: String, Sendable, Hashable, Codable { case read, write }
        /// The subcommand's words, like `["pr", "list"]`. Whatever the
        /// plugin passes after them is its own.
        public var args: [String]
        public var access: Access

        public init(_ args: [String], _ access: Access) { self.args = args; self.access = access }

        public var words: String { args.joined(separator: " ") }
    }

    public init(binary: String, install: String? = nil, commands: [Command]) {
        self.binary = binary; self.install = install; self.commands = commands
    }

    public static let commandLimit = 32
    public static let wordLimit = 4
    public static let installLimit = 120
    /// What one run may pass: arguments, and characters across them.
    public static let argumentLimit = 64
    public static let argumentTextLimit = 48 * 1024
    /// What one run hands back.
    public static let outputLimit = 4 * 1024 * 1024
    public static let errorOutputLimit = 64 * 1024
    /// How long a read may take inside the git budget, and a write outside it.
    public static let readTimeout: Duration = .seconds(30)
    public static let writeTimeout: Duration = .seconds(120)

    /// Binaries a plugin may never name: shells, interpreters and
    /// launchers would run anything, and git belongs to Abstract itself.
    public static let refusedBinaries: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "env", "sudo", "su", "doas", "login",
        "osascript", "open", "xargs", "nohup", "exec", "eval", "command", "launchctl", "script",
        "python", "python3", "ruby", "perl", "node", "deno", "bun", "php", "lua", "awk", "swift",
        "git", "ssh", "scp", "rsync", "curl", "wget", "abstract",
    ]

    /// The command a run's arguments start with: the longest declared one
    /// whose words they begin with. Nil when none.
    public func command(for args: [String]) -> Command? {
        commands.filter { args.starts(with: $0.args) }.max { $0.args.count < $1.args.count }
    }

    public var reads: [Command] { commands.filter { $0.access == .read } }
    public var writes: [Command] { commands.filter { $0.access == .write } }

    /// Whether `other`'s commands are all in this one, each with the same
    /// or less access: an update within it needs no new review.
    public func covers(_ other: PluginCLI) -> Bool {
        guard binary == other.binary else { return false }
        return other.commands.allSatisfy { wanted in
            commands.contains { $0.args == wanted.args && ($0.access == .write || wanted.access == .read) }
        }
    }

    /// The review sentences: the binary, then every command in plain words.
    public var sentences: [String] {
        var out = ["Run \(binary) on your Mac, in your projects' folders, with no other program and only these commands."]
        if !reads.isEmpty {
            out.append("To read: " + reads.map { "\(binary) \($0.words)" }.joined(separator: ", ") + ".")
        }
        if !writes.isEmpty {
            out.append("To change things, asking you first: " + writes.map { "\(binary) \($0.words)" }.joined(separator: ", ") + ".")
        }
        if let install, !install.isEmpty { out.append("It needs \(binary) installed (\(install)).") }
        return out
    }

    func validate() throws {
        func refuse(_ why: String) -> PluginValidationError { .invalidManifest("cli: \(why)") }
        guard Self.isWord(binary, allowDots: true), !Self.refusedBinaries.contains(binary.lowercased()) else {
            throw refuse("binary must be a plain program name, not a path, shell or interpreter")
        }
        if let install {
            guard install.count <= Self.installLimit, !install.contains("\n") else { throw refuse("install is one short line") }
        }
        guard !commands.isEmpty, commands.count <= Self.commandLimit else {
            throw refuse("list between 1 and \(Self.commandLimit) commands")
        }
        guard Set(commands.map(\.args)).count == commands.count else { throw refuse("a command is listed twice") }
        for command in commands {
            guard !command.args.isEmpty, command.args.count <= Self.wordLimit,
                  command.args.allSatisfy({ Self.isWord($0, allowDots: false) }) else {
                throw refuse("each command is up to \(Self.wordLimit) words like pr list, with no flags")
            }
        }
    }

    /// A plain program name, never a path or an option.
    public static func isProgramName(_ name: String) -> Bool { isWord(name, allowDots: true) }

    /// Lowercase letters, digits and `-` (and `.`/`_` in a binary's name),
    /// never starting with `-` or `.`.
    static func isWord(_ word: String, allowDots: Bool) -> Bool {
        guard let first = word.first, first != "-", first != ".", word.count <= 40 else { return false }
        return word.allSatisfy { c in
            (c.isASCII && (c.isLowercase || c.isNumber)) || c == "-" || (allowDots && (c == "." || c == "_"))
        }
    }
}

/// One run a plugin asked for, checked at the bridge.
public struct PluginCLIRequest: Sendable, Equatable {
    /// The whole argument list, declared words first.
    public var args: [String]
    /// The declared command they start with.
    public var command: PluginCLI.Command
    /// Where it runs: a chat's worktree, or a project's folder. Neither
    /// runs it outside any folder, on this Mac.
    public var chatId: String?
    public var projectKey: String?
    /// The code host call it serves (ABS-139), when the host handed it one.
    public var callId: String?

    public init(args: [String], command: PluginCLI.Command, chatId: String? = nil, projectKey: String? = nil,
                callId: String? = nil) {
        self.args = args; self.command = command; self.chatId = chatId; self.projectKey = projectKey; self.callId = callId
    }

    public var isWrite: Bool { command.access == .write }
}

/// What a run handed back to the plugin.
public struct PluginCLIResult: Sendable, Equatable {
    public var code: Int32
    public var stdout: String
    public var stderr: String
    public var truncated: Bool

    public init(code: Int32, stdout: String, stderr: String, truncated: Bool = false) {
        self.code = code; self.stdout = stdout; self.stderr = stderr; self.truncated = truncated
    }

    public func jsonValue() -> JSONValue {
        .object(["code": .number(Double(code)), "ok": .bool(code == 0), "stdout": .string(stdout),
                 "stderr": .string(stderr), "truncated": .bool(truncated)])
    }
}

/// Why a run didn't happen, in a plain sentence.
public enum PluginCLIError: Error, Sendable, Equatable, LocalizedError {
    case refused(String)
    /// The binary isn't on the login shell's PATH.
    case missing(binary: String, install: String?)

    public var errorDescription: String? {
        switch self {
        case .refused(let why): why
        case .missing(let binary, let install):
            install.map { "\(binary) isn't installed. Install it with `\($0)`." } ?? "\(binary) isn't installed."
        }
    }

    public func jsonValue() -> JSONValue {
        var object: [String: JSONValue] = ["message": .string(errorDescription ?? "")]
        if case .missing(let binary, let install) = self {
            object["missing"] = .string(binary)
            if let install { object["install"] = .string(install) }
        }
        return .object(object)
    }
}

/// How a checked run goes ahead.
public enum PluginCLIRoute: Sendable, Equatable {
    /// A read: inside the git budget.
    case read
    /// A write the person started or always allows: straight away.
    case write
    /// A write that asks first (ABS-92).
    case ask

    /// A write runs unasked only when the person started the code host
    /// call it serves, or always allows this plugin's writes.
    public static func of(_ request: PluginCLIRequest, alwaysAllowed: Bool, personStarted: Bool) -> PluginCLIRoute {
        guard request.isWrite else { return .read }
        return personStarted || alwaysAllowed ? .write : .ask
    }
}

/// Runs checked requests: in a readable folder only, with no shell, reads
/// in the budget and writes under a time limit.
public struct PluginCLIRunner: Sendable {
    public var budget: GitBudget

    public init(budget: GitBudget = .shared) { self.budget = budget }

    /// `cwd` is the folder the request resolved to; `readable` the project
    /// folders and worktrees the plugin can read. A folder outside them is
    /// refused before anything runs.
    public func run(_ request: PluginCLIRequest, cli: PluginCLI, executor: any Executor,
                    cwd: String?, readable: [String]) async throws -> PluginCLIResult {
        guard cli.command(for: request.args) == request.command else {
            throw PluginCLIError.refused("This plugin hasn't been granted running \(cli.binary) \(request.args.prefix(2).joined(separator: " ")).")
        }
        if let cwd, !Self.isInside(cwd, readable) {
            throw PluginCLIError.refused("That folder isn't one of the projects this plugin can read.")
        }
        guard await executor.which(cli.binary) != nil else {
            throw PluginCLIError.missing(binary: cli.binary, install: cli.install)
        }
        let binary = cli.binary, args = request.args
        let out: ExecResult
        if request.isWrite {
            out = try await withTimeLimit(PluginCLI.writeTimeout, what: "`\(binary) \(request.command.words)`") {
                try await executor.run(binary, args, cwd: cwd, stdin: nil)
            }
        } else {
            out = try await budget.run(in: cwd ?? "", what: "`\(binary) \(request.command.words)`",
                                       coalescing: [binary] + args, timeout: PluginCLI.readTimeout) {
                try await executor.run(binary, args, cwd: cwd, stdin: nil)
            }
        }
        let truncated = out.stdout.utf8.count > PluginCLI.outputLimit || out.stderr.utf8.count > PluginCLI.errorOutputLimit
        return PluginCLIResult(code: out.code, stdout: Self.cut(out.stdout, PluginCLI.outputLimit),
                               stderr: Self.cut(out.stderr, PluginCLI.errorOutputLimit), truncated: truncated)
    }

    /// `path` is one of `roots` or inside one, compared without symlinks.
    public static func isInside(_ path: String, _ roots: [String]) -> Bool {
        let target = canonical(path)
        return roots.contains { root in
            let r = canonical(root)
            return !r.isEmpty && (target == r || target.hasPrefix(r.hasSuffix("/") ? r : r + "/"))
        }
    }

    static func canonical(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var out = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if out.hasPrefix("/private/") { out = String(out.dropFirst("/private".count)) }
        return out
    }

    private static func cut(_ text: String, _ limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        return String(decoding: Array(text.utf8.prefix(limit)), as: UTF8.self)
    }
}
