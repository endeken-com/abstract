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

    /// `<name>` from a command reading `…/<name>/SKILL.md`, and nothing else.
    static func name(readBy command: String) -> String? {
        guard !command.contains(">"), let range = command.range(of: "/SKILL.md") else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\";|&()"))
        let words = command.components(separatedBy: separators).filter { !$0.isEmpty }
        guard words.contains(where: readers.contains) else { return nil }
        let folder = command[..<range.lowerBound]
        let name = folder.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty || name.unicodeScalars.contains(where: separators.contains) ? nil : name
    }
}
