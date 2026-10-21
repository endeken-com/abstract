import Foundation

/// Library skills (ABS-122) in the chat's own folder, laid out where its
/// agent already looks, so the user's own skills folder is never written to:
///
///     <chat folder>/claude/.claude/skills/<name>   Claude, with --add-dir
///     <chat folder>/codex-home/skills/<name>       Codex and Muse, as CODEX_HOME
///     <chat folder>/skills/<name>                  OpenCode, in skills.paths
///
/// A library skill is a copy (a clone, on APFS) of its folder as the
/// library has it at this launch, so an agent that may write in its
/// folder changes only its own chat's copy, never the library.
public extension ChatConfigFiles {
    /// Lays `skills` out in `directory` the way `delivery` says and names
    /// the folder the agent is given. nil when there are no skills: the
    /// agent starts as it would without Abstract's library.
    static func prepareSkills(_ skills: [LibrarySkill], delivery: SkillDelivery, in directory: String, home: String,
                              fileManager fm: FileManager = .default) throws -> SkillsLaunch? {
        guard !skills.isEmpty else { return nil }
        let named = skills.compactMap { skill in folderName(skill.name).map { Entry(name: $0, source: skill.folder, copied: true) } }
        switch delivery {
        case .addedDirectory:
            let root = directory + "/claude"
            try place(named, into: root + "/.claude/skills", under: directory, fileManager: fm)
            return SkillsLaunch(folder: root)
        case .codexHome:
            let overlay = directory + "/codex-home"
            let real = home + "/.codex"
            try mirror(real, into: overlay, under: directory, except: "skills", fileManager: fm)
            // The user's own skills stay; Codex writes its built-in ones
            // (`.system`) into the stand-in itself.
            let ours = Set(named.map(\.name))
            let own = ((try? fm.contentsOfDirectory(atPath: real + "/skills")) ?? []).sorted()
                .filter { !$0.hasPrefix(".") && !ours.contains($0) }
                .map { Entry(name: $0, source: real + "/skills/" + $0, copied: false) }
            try place(own + named, into: overlay + "/skills", under: directory, fileManager: fm)
            return SkillsLaunch(folder: overlay)
        case .skillsPath:
            let root = directory + "/skills"
            try place(named, into: root, under: directory, fileManager: fm)
            return SkillsLaunch(folder: root)
        }
    }

    /// A skill's name as a folder name; nil when nothing usable is left.
    internal static func folderName(_ name: String) -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? nil : cleaned
    }

    /// A skill folder to put in place: a copy of a library skill, or a
    /// link to one of the user's own (which they can already change).
    internal struct Entry {
        var name: String
        var source: String
        var copied: Bool
    }

    /// `dir` holds exactly these skills: what an earlier launch put there
    /// goes; hidden folders (Codex's built-in `.system`) stay.
    internal static func place(_ entries: [Entry], into dir: String, under chat: String, fileManager fm: FileManager) throws {
        try realFolder(dir, under: chat, fileManager: fm)
        for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !entry.hasPrefix(".") {
            try fm.removeItem(atPath: dir + "/" + entry)
        }
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.name).inserted {
            let path = dir + "/" + entry.name
            if entry.copied { try fm.copyItem(atPath: entry.source, toPath: path) }
            else { try fm.createSymbolicLink(atPath: path, withDestinationPath: entry.source) }
        }
    }

    /// `overlay` links to every entry of `real` but `except`, so an agent
    /// given it as its home reads and writes its real sign-in, settings,
    /// sessions and history. What it creates there that `real` doesn't
    /// have stays in the overlay.
    internal static func mirror(_ real: String, into overlay: String, under chat: String, except: String,
                                fileManager fm: FileManager) throws {
        try realFolder(overlay, under: chat, fileManager: fm)
        let entries = Set(((try? fm.contentsOfDirectory(atPath: real)) ?? []).filter { $0 != except })
        for entry in (try? fm.contentsOfDirectory(atPath: overlay)) ?? [] where entry != except {
            let path = overlay + "/" + entry
            if isLink(path, fm), !entries.contains(entry) || (try? fm.destinationOfSymbolicLink(atPath: path)) != real + "/" + entry {
                try fm.removeItem(atPath: path)
            }
        }
        for entry in entries.sorted() where !isLink(overlay + "/" + entry, fm) && !fm.fileExists(atPath: overlay + "/" + entry) {
            try fm.createSymbolicLink(atPath: overlay + "/" + entry, withDestinationPath: real + "/" + entry)
        }
    }

    /// Makes `dir` and every folder between `chat` and it a real folder.
    /// The chat's agent may write in its folder: a link it left there
    /// in place of one is removed (the link alone), never followed, so
    /// clearing the folder can't reach anything outside it.
    internal static func realFolder(_ dir: String, under chat: String, fileManager fm: FileManager) throws {
        try fm.createDirectory(atPath: chat, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isRealFolder(chat, fm), dir.hasPrefix(chat + "/") else {
            throw AbstractError.message("The chat's folder at \(chat) isn't a folder.")
        }
        var path = chat
        for part in dir.dropFirst(chat.count + 1).split(separator: "/") {
            path += "/" + part
            if (try? fm.attributesOfItem(atPath: path)) != nil, !isRealFolder(path, fm) { try fm.removeItem(atPath: path) }
            if !isRealFolder(path, fm) { try fm.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        }
    }

    /// A folder itself, not a link to one.
    private static func isRealFolder(_ path: String, _ fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isLink(_ path: String, _ fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
}
