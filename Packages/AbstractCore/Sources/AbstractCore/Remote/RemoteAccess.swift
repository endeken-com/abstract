import Foundation

/// What a paired device may run on this Mac for a chat's worktree: git, gh
/// and revund, inside this Mac's projects, without the options that would
/// let them run some other program or write somewhere else.
public enum RemoteAccess {
    static let commands: Set<String> = ["git", "gh", "revund"]
    /// Git settings Abstract itself passes; any other `-c` could run a program.
    static let gitSettings: Set<String> = ["core.quotepath", "user.email", "user.name", "color.ui"]
    static let gitOptions = ["-C", "--git-dir", "--work-tree", "--exec-path", "--upload-pack", "--receive-pack", "--config-env",
                             "--output", "--ext-diff", "--textconv", "--open-files-in-pager",
                             // `git apply` writing outside the repository.
                             "--unsafe-paths", "--directory"]
    /// The only command that takes input from another Mac: Accept's `git apply`.
    static let applyFlags: Set<String> = ["--check", "--3way", "-R"]

    /// Why the command can't run, or nil when it can. `allowed` says whether
    /// a folder is inside one of this Mac's projects or worktrees. `input`:
    /// the command comes with stdin, which only Accept's patch does.
    /// `plugins` are the command-line tools this Mac's enabled plugins were
    /// granted (ABS-139): their declared commands run too, the same way.
    public static func refusal(_ command: String, _ args: [String], cwd: String?, input: Bool = false,
                               plugins: [PluginCLI] = [], allowed: (String?) -> Bool) -> String? {
        let name = (command as NSString).lastPathComponent
        let plugin = command == name ? pluginRefusal(name, args, cwd: cwd, input: input, plugins: plugins, allowed: allowed) : nil
        if plugin == .some(nil) { return nil }
        guard commands.contains(name), command == name else {
            return plugin ?? "Only git, gh, revund and your plugins' tools run for another Mac."
        }
        return builtInRefusal(name, args, cwd: cwd, input: input, allowed: allowed)
    }

    /// nil when no plugin names the binary; `.some(nil)` when one allows the
    /// command: a declared command, no input, in a project folder (or, for
    /// a read, outside any folder).
    static func pluginRefusal(_ name: String, _ args: [String], cwd: String?, input: Bool,
                              plugins: [PluginCLI], allowed: (String?) -> Bool) -> String?? {
        let declared = plugins.filter { $0.binary == name && !PluginCLI.refusedBinaries.contains(name) }
        guard !declared.isEmpty else { return nil }
        if input { return .some("Only accepting a patch sends input from another Mac.") }
        if cwd == nil, args == ["--version"] { return .some(nil) }
        guard let found = declared.lazy.compactMap({ $0.command(for: args) }).first else {
            return .some("\(name) \(args.first ?? "") isn't allowed from another Mac.")
        }
        if cwd == nil, found.access == .read { return .some(nil) }
        return .some(allowed(cwd) ? nil : "That folder isn't one of this Mac's projects.")
    }

    static func builtInRefusal(_ name: String, _ args: [String], cwd: String?, input: Bool,
                               allowed: (String?) -> Bool) -> String? {
        if input, !(name == "git" && args.first == "apply" && args.last == "-" && args.dropFirst().dropLast().allSatisfy(applyFlags.contains)) {
            return "Only accepting a patch sends input from another Mac."
        }
        // Outside a folder, only asking what's installed and signed in.
        if cwd == nil, args == ["--version"] || (name == "gh" && args == ["auth", "status"]) { return nil }
        guard allowed(cwd) else { return "That folder isn't one of this Mac's projects." }
        switch name {
        case "git":
            // `git grep -O<program>` opens what it finds in that program, bundled
            // (-nO…) or abbreviated (--open…) too: only Search in Files' own grep runs.
            // Before the command, only options that take no value: one that does
            // (--namespace x) would hide which command runs.
            guard let command = gitCommand(args), !command.hasPrefix("-") else {
                return "git \(gitCommand(args) ?? "") isn't allowed from another Mac."
            }
            if command == "grep" {
                return isSearchInFiles(args) ? nil : "Only Search in Files runs git grep from another Mac."
            }
            for (i, arg) in args.enumerated() {
                if gitOptions.contains(where: { matches(arg, $0) }) { return "git \(arg) isn't allowed from another Mac." }
                if arg == "-c" {
                    let setting = i + 1 < args.count ? args[i + 1].split(separator: "=").first.map { $0.lowercased() } ?? "" : ""
                    if !gitSettings.contains(setting) { return "git -c \(setting) isn't allowed from another Mac." }
                }
            }
        case "gh":
            // gh aliases and extensions run programs; only what Abstract asks gh for.
            guard ["pr", "issue", "api", "repo"].contains(args.first ?? "") else { return "gh \(args.first ?? "") isn't allowed from another Mac." }
        default:
            guard ["review", "feedback"].contains(args.first ?? "") else { return "revund \(args.first ?? "") isn't allowed from another Mac." }
            if let i = args.firstIndex(of: "--repo"), !allowed(i + 1 < args.count ? args[i + 1] : nil) {
                return "That folder isn't one of this Mac's projects."
            }
        }
        return nil
    }

    /// The flags `WorktreeSearch.arguments` passes, then `-e <pattern> --` and nothing more.
    static let searchFlags: Set<String> = ["-z", "-n", "--column", "-I", "--color=never", "--untracked", "--no-index",
                                           "--exclude-standard", "--fixed-strings", "--extended-regexp", "--ignore-case",
                                           "--word-regexp"]

    /// git's own options, before the command, that take no value.
    static let globalFlags: Set<String> = ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "--glob-pathspecs",
                                           "--noglob-pathspecs", "--icase-pathspecs", "--no-replace-objects", "--no-advice"]

    /// The git command, past `-c` settings and `globalFlags` before it. Any
    /// other option there comes back instead, and is refused.
    static func gitCommand(_ args: [String]) -> String? {
        var i = 0
        while i < args.count, args[i] == "-c" || globalFlags.contains(args[i]) { i += args[i] == "-c" ? 2 : 1 }
        return i < args.count ? args[i] : nil
    }

    static func isSearchInFiles(_ args: [String]) -> Bool {
        guard args.count >= 4, args.first == "grep", args[args.count - 3] == "-e", args.last == "--" else { return false }
        return args.dropFirst().dropLast(3).allSatisfy(searchFlags.contains)
    }

    /// `arg` is `option`, gives it a value, or, for a long option, abbreviates
    /// it: git takes any unambiguous start of a long option's name.
    static func matches(_ arg: String, _ option: String) -> Bool {
        if arg == option || arg.hasPrefix(option + "=") { return true }
        guard option.hasPrefix("--"), arg.hasPrefix("--") else { return false }
        let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
        return name.count > 2 && option.hasPrefix(name)
    }

    /// A process's environment from another device: variables like
    /// GIT_SSH_COMMAND or DYLD_* would run programs, so only a Revund key comes across.
    public static func environment(_ env: [String: String]) -> [String: String] {
        env.filter { $0.key == "REVUND_API_KEY" }
    }
}
