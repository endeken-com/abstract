import Foundation

/// The skill a tool call follows, when it shows (ABS-122): the skill tool
/// of Claude (`skill`) and OpenCode (`name`), or a command that reads a
/// skill's `SKILL.md`, which is how Codex and Muse load one.
public enum SkillUse {
    static let readers: Set<String> = ["cat", "sed", "head", "nl", "bat", "less", "more"]

    public static func name(tool: String, input: JSONValue) -> String? {
        if tool.lowercased() == "skill" {
            return (input["skill"]?.string ?? input["name"]?.string).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let command = input["command"]?.string ?? input["cmd"]?.string else { return nil }
        return name(readBy: command)
    }

    /// `<name>` from a command that only reads `…/<name>/SKILL.md`: one
    /// reader, nothing chained, redirected or substituted.
    static func name(readBy command: String) -> String? {
        let body = shellBody(command)
        guard body.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>`$\n")) == nil,
              let range = body.range(of: "/SKILL.md"),
              let reader = body.split(separator: " ").first, readers.contains(String(reader)) else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\""))
        let folder = body[..<range.lowerBound]
        let name = folder.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty || name.unicodeScalars.contains(where: separators.contains) ? nil : name
    }

    /// The command a `zsh -lc '…'` wrapper runs, else the command itself.
    static func shellBody(_ command: String) -> String {
        let s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"] {
            for flag in [" -lc ", " -c "] where s.hasPrefix(shell + flag) {
                let body = s.dropFirst(shell.count + flag.count)
                guard let quote = body.first, quote == "\"" || quote == "'", body.count >= 2, body.last == quote else { continue }
                return String(body.dropFirst().dropLast())
            }
        }
        return s
    }
}
