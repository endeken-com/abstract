import Foundation

/// What a paired device may run on this Mac for a chat's worktree: git, gh
/// and revund, inside this Mac's projects, without the options that would
/// let them run some other program or write somewhere else.
public enum RemoteAccess {
    static let commands: Set<String> = ["git", "gh", "revund"]
    /// Git settings Abstract itself passes; any other `-c` could run a program.
    static let gitSettings: Set<String> = ["core.quotepath", "user.email", "user.name", "color.ui"]
    static let gitOptions = ["-C", "--git-dir", "--work-tree", "--exec-path", "--upload-pack", "--receive-pack", "--config-env",
                             "--output", "--ext-diff", "--textconv"]

    /// Why the command can't run, or nil when it can. `allowed` says whether
    /// a folder is inside one of this Mac's projects or worktrees.
    public static func refusal(_ command: String, _ args: [String], cwd: String?, allowed: (String?) -> Bool) -> String? {
        let name = (command as NSString).lastPathComponent
        guard commands.contains(name), command == name else { return "Only git, gh and revund run for another Mac." }
        // Outside a folder, only asking what's installed and signed in.
        if cwd == nil, args == ["--version"] || (name == "gh" && args == ["auth", "status"]) { return nil }
        guard allowed(cwd) else { return "That folder isn't one of this Mac's projects." }
        switch name {
        case "git":
            for (i, arg) in args.enumerated() {
                if gitOptions.contains(where: { arg == $0 || arg.hasPrefix($0 + "=") }) { return "git \(arg) isn't allowed from another Mac." }
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

    /// A process's environment from another device: variables like
    /// GIT_SSH_COMMAND or DYLD_* would run programs, so only a Revund key comes across.
    public static func environment(_ env: [String: String]) -> [String: String] {
        env.filter { $0.key == "REVUND_API_KEY" }
    }
}
