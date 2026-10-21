import Foundation
import AbstractCore

/// A GitHub source's newer commit, with what it changes, waiting for you
/// to update to it.
struct SkillUpdate: Identifiable, Equatable {
    var sourceId: String
    var from: String
    var to: String
    var diff: String
    var id: String { sourceId + "@" + to }
}

/// The skill library (ABS-122): skills managed once here and given to
/// every agent in the projects that choose them. Agents get them at
/// launch, in each chat's own folder; their own skills folders are never
/// written to.
extension AppModel {
    /// Abstract's data folder, which holds the library's checkouts.
    var dataDirectory: String { AttachmentStore.root.deletingLastPathComponent().path }

    /// Where each chat's launch files go: `agent-config/<chat id>/` beside
    /// the attachments.
    static var agentConfigRoot: String {
        AttachmentStore.root.deletingLastPathComponent().appendingPathComponent("agent-config").path
    }

    private var libraryFolder: String { SkillLibrary.folder(dataDirectory: dataDirectory) }

    /// Reads the sources' skills again, after they change on disk.
    func reloadSkills() {
        librarySkills = SkillLibrary.skills(sources: skillSources, library: libraryFolder)
    }

    func skills(in sourceId: String) -> [LibrarySkill] { librarySkills.filter { $0.sourceId == sourceId } }

    func librarySkill(_ id: String) -> LibrarySkill? { librarySkills.first { $0.id == id } }

    /// A project's own skills, from its files: listed, not delivered.
    func projectSkills(_ projectId: String?) -> [LibrarySkill] {
        guard let project = project(projectId), projects.contains(where: { $0.id == project.id }) else { return [] }
        return SkillScanner.projectSkills(root: project.rootPath)
    }

    func addSkillFolder(_ path: String) {
        guard !skillSources.contains(where: { $0.kind == .folder && $0.location == path }) else {
            flash("That folder is already in the library.")
            return
        }
        skillSources.append(SkillSource(kind: .folder, location: path))
        reloadSkills()
        if skills(in: skillSources.last?.id ?? "").isEmpty { flash("No skills found in that folder yet: each needs a SKILL.md.") }
    }

    /// Clones the repository and pins it to its default branch's commit now.
    func addSkillRepository(_ text: String) async throws {
        guard let repository = GitHubRepository.parse(text) else {
            throw AbstractError.message("Enter a GitHub repository as owner/name or its URL.")
        }
        guard !skillSources.contains(where: { $0.kind == .github && $0.location == repository }) else {
            throw AbstractError.message("\(repository) is already in the library.")
        }
        var source = SkillSource(kind: .github, location: repository)
        let folder = source.folder(library: libraryFolder)
        source.commit = try await SkillRepository.clone(executor, url: GitHubRepository.cloneURL(repository), into: folder)
        skillSources.append(source)
        reloadSkills()
        if skills(in: source.id).isEmpty { flash("\(repository) has no skills: none of its folders holds a SKILL.md.") }
    }

    /// Takes the source out of the library and out of every project and
    /// profile that chose its skills. Chats already running keep theirs.
    func removeSkillSource(_ id: String) {
        guard let source = skillSources.first(where: { $0.id == id }) else { return }
        let gone = Set(skills(in: id).map(\.id))
        skillSources.removeAll { $0.id == id }
        if source.kind == .github { try? FileManager.default.removeItem(atPath: source.folder(library: libraryFolder)) }
        for project in projects where project.assignedSkills.contains(where: gone.contains) {
            updateProject(project.id) { $0.skillIds = $0.assignedSkills.filter { !gone.contains($0) } }
        }
        for var profile in profiles where profile.skills.contains(where: gone.contains) {
            profile.skills.removeAll(where: gone.contains)
            saveProfile(profile)
        }
        reloadSkills()
    }

    /// The repository's newest commit and what it changes from the pinned
    /// one; nil when the source is up to date. Nothing moves yet.
    func checkSkillUpdate(_ id: String) async throws -> SkillUpdate? {
        guard let source = skillSources.first(where: { $0.id == id }), source.kind == .github, let pinned = source.commit else { return nil }
        let folder = source.folder(library: libraryFolder)
        let latest = try await SkillRepository.latest(executor, folder: folder)
        guard latest != pinned else { return nil }
        let diff = try await SkillRepository.diff(executor, folder: folder, from: pinned, to: latest)
        return SkillUpdate(sourceId: id, from: pinned, to: latest, diff: diff)
    }

    /// Moves the source to the commit whose diff you saw. New chats get it.
    func applySkillUpdate(_ update: SkillUpdate) async throws {
        guard let index = skillSources.firstIndex(where: { $0.id == update.sourceId }),
              skillSources[index].commit == update.from else { return }
        try await SkillRepository.pin(executor, folder: skillSources[index].folder(library: libraryFolder), commit: update.to)
        skillSources[index].commit = update.to
        reloadSkills()
    }

    /// Whether a project's chats get the skill.
    func setSkill(_ skillId: String, assigned: Bool, projectId: String) {
        updateProject(projectId) { p in
            var ids = p.assignedSkills.filter { $0 != skillId }
            if assigned { ids.append(skillId) }
            p.skillIds = ids
        }
    }

    /// Whether chats started from the profile get the skill too.
    func setSkill(_ skillId: String, added: Bool, profileId: String) {
        guard var profile = profile(profileId) else { return }
        profile.skills.removeAll { $0 == skillId }
        if added { profile.skills.append(skillId) }
        saveProfile(profile)
    }
}
