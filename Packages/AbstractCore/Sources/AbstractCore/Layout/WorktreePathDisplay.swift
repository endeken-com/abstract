/// A short worktree path for narrow rows, with the home directory shown as `~`.
public enum WorktreePathDisplay {
    public static func abbreviated(_ path: String, homeDirectory: String) -> String {
        var home = homeDirectory
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if home == "/" { return "~" + path }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
