import Foundation

/// Where skills in the library come from (ABS-122): a folder on this Mac,
/// or a GitHub repository checked out at a pinned commit. A project's own
/// skills aren't a source; they are read from its files (`SkillScanner.projectSkills`).
public struct SkillSource: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case folder, github }

    public var id: String
    public var kind: Kind
    /// The folder's path, or the repository as `owner/name`.
    public var location: String
    /// The commit a GitHub source is pinned to. It moves only when you
    /// update it, after seeing the diff.
    public var commit: String?
    public var addedAt: Date

    public init(id: String = UUID().uuidString, kind: Kind, location: String, commit: String? = nil, addedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.location = location; self.commit = commit; self.addedAt = addedAt
    }

    /// What the library shows for it: the folder's name, or `owner/name`.
    public var title: String {
        kind == .github ? location : (location as NSString).lastPathComponent
    }

    /// The folder its skills are read from: the folder itself, or the
    /// repository's checkout under `library`.
    public func folder(library: String) -> String {
        kind == .folder ? location : library + "/" + id
    }
}

/// One skill: a folder holding `SKILL.md`.
public struct LibrarySkill: Sendable, Hashable, Identifiable {
    /// `<source id>/<path in the source>`, stable while the skill stays put.
    public var id: String
    /// From `SKILL.md`'s front matter, else the folder's name. Agents
    /// find the skill by it, so it is also its folder's name when delivered.
    public var name: String
    public var description: String?
    /// The skill's folder.
    public var folder: String
    public var sourceId: String

    public init(id: String, name: String, description: String? = nil, folder: String, sourceId: String) {
        self.id = id; self.name = name; self.description = description; self.folder = folder; self.sourceId = sourceId
    }
}

/// Finds skills in a folder: every folder holding a `SKILL.md`, at any
/// depth up to a few levels (`skills/<name>`, `.claude/skills/<name>`).
public enum SkillScanner {
    /// The folders a project keeps its own skills in, for any agent.
    public static let projectFolders = [".claude/skills", ".agents/skills", ".codex/skills", ".opencode/skills"]

    static let maxDepth = 4
    /// Never looked inside: they hold no skills of their own, or far too much.
    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData"]

    /// Skills under `root`, sorted by name; ids are `sourceId/<relative path>`.
    public static func skills(in root: String, sourceId: String, fileManager fm: FileManager = .default) -> [LibrarySkill] {
        var found: [LibrarySkill] = []
        func visit(_ dir: String, relative: String, depth: Int) {
            if !relative.isEmpty, let skill = skill(at: dir, id: sourceId + "/" + relative, sourceId: sourceId) {
                found.append(skill)
                return
            }
            guard depth < maxDepth, let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries.sorted() where !skipped.contains(entry) {
                var isDir: ObjCBool = false
                let path = dir + "/" + entry
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                visit(path, relative: relative.isEmpty ? entry : relative + "/" + entry, depth: depth + 1)
            }
        }
        visit(root, relative: "", depth: 0)
        return found.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The skill in `folder`, when it holds a `SKILL.md`.
    public static func skill(at folder: String, id: String, sourceId: String) -> LibrarySkill? {
        guard let text = try? String(contentsOfFile: folder + "/SKILL.md", encoding: .utf8) else { return nil }
        let meta = frontMatter(text)
        let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (folder as NSString).lastPathComponent
        return LibrarySkill(id: id, name: name, description: meta["description"], folder: folder, sourceId: sourceId)
    }

    /// A project's own skills, read from its files: listed, never delivered,
    /// since agents already read them from the worktree.
    public static func projectSkills(root: String, fileManager fm: FileManager = .default) -> [LibrarySkill] {
        projectFolders.flatMap { folder in
            skills(in: root + "/" + folder, sourceId: "project", fileManager: fm).map {
                var skill = $0
                skill.id = "project/" + folder + "/" + String($0.id.dropFirst("project/".count))
                return skill
            }
        }
    }

    /// The simple `key: value` lines between the leading `---` fences.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}

/// The library as a whole: its sources' skills, and which of them a chat gets.
public enum SkillLibrary {
    /// The setting the sources are saved under.
    public static let sourcesKey = "skillSources"

    /// What the chat says when its agent can't take the skills it would get.
    public static func unsupportedNote(provider: any ProviderDefinition, skills: [LibrarySkill]) -> String? {
        guard provider.skillDelivery == nil, !skills.isEmpty else { return nil }
        let names = skills.map(\.name).joined(separator: ", ")
        return "\(provider.name) can't take skills from Abstract, so this chat runs without \(names)."
    }

    /// Where GitHub sources are checked out, in Abstract's data folder.
    public static func folder(dataDirectory: String) -> String { dataDirectory + "/skills" }

    /// Every skill the sources hold, in source order.
    public static func skills(sources: [SkillSource], library: String, fileManager fm: FileManager = .default) -> [LibrarySkill] {
        sources.flatMap { SkillScanner.skills(in: $0.folder(library: library), sourceId: $0.id, fileManager: fm) }
    }

    /// The skills a chat's agent gets: its project's, then the ones its
    /// profile adds (ABS-101), each name once. An id the library no longer
    /// holds is left out.
    public static func chatSkills(project: [String], profile: [String], available: [LibrarySkill]) -> [LibrarySkill] {
        let byId = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names = Set<String>()
        return (project + profile).compactMap { byId[$0] }.filter { names.insert($0.name).inserted }
    }
}

/// `owner/name` from what you paste: `owner/name`, a github.com URL (with
/// `.git`, or a path into the repository after it), or an SSH remote.
public enum GitHubRepository {
    public static func parse(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "git@", "ssh://git@"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        for host in ["www.github.com/", "github.com/", "github.com:"] where s.hasPrefix(host) { s.removeFirst(host.count) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0]
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !owner.isEmpty, !name.isEmpty, !name.hasPrefix("."),
              owner.unicodeScalars.allSatisfy(allowed.contains), name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return owner + "/" + name
    }

    /// The URL it is cloned from.
    public static func cloneURL(_ repository: String) -> String { "https://github.com/\(repository).git" }
}
