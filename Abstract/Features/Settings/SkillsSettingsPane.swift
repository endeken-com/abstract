import AppKit
import SwiftUI
import AbstractCore

/// The skill library (ABS-122): folders and GitHub repositories of
/// skills, managed once and chosen per project in Project Settings. A
/// repository stays at the commit it was added at until you update it,
/// after seeing the diff.
struct SkillsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var checking: String?
    @State private var update: SkillUpdate?
    @State private var query = ""
    @State private var expandedSourceId: String?
    @State private var expandedProjectId: String?
    @State private var projectSkillsById: [String: [LibrarySkill]] = [:]

    var body: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillsBySource = Dictionary(grouping: model.librarySkills, by: \.sourceId)
        let sources = model.skillSources.filter { source in
            let skills = skillsBySource[source.id] ?? []
            return search.isEmpty || skillSearchMatches(search, in: source.title + " " + source.location)
                || skills.contains { skillSearchMatches(search, in: $0.name + " " + ($0.description ?? "")) }
        }
        let projects = model.projects.filter { $0.archivedAt == nil }
            .compactMap { project -> (Project, [LibrarySkill])? in
                guard let skills = projectSkillsById[project.id], !skills.isEmpty else { return nil }
                return (project, skills)
            }
            .filter { project, skills in
                search.isEmpty || skillSearchMatches(search, in: project.name)
                    || skills.contains { skillSearchMatches(search, in: $0.name + " " + ($0.description ?? "")) }
            }
        Form {
            if !model.skillSources.isEmpty || projectSkillsById.values.contains(where: { !$0.isEmpty }) {
                Section {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.btTextTertiary)
                        TextField("Search skills and sources", text: $query)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search skills and sources")
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.btTextTertiary)
                            .accessibilityLabel("Clear search")
                        }
                    }
                } footer: {
                    SettingsCaption("\(model.librarySkills.count) \(model.librarySkills.count == 1 ? "skill" : "skills") in \(model.skillSources.count) \(model.skillSources.count == 1 ? "source" : "sources"). Select a source to browse its skills.")
                }
            }
            Section {
                if !sources.isEmpty {
                    ForEach(sources) { source in
                        SkillSourceRows(source: source, skills: skillsBySource[source.id] ?? [], query: search,
                                        expanded: expandedSourceId == source.id,
                                        checking: checking == source.id,
                                        onToggle: { expandedSourceId = expandedSourceId == source.id ? nil : source.id },
                                        onCheck: { check(source) })
                    }
                } else if !search.isEmpty {
                    SettingsCaption("No library skills or sources match “\(search)”.")
                } else {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.btTextSecondary)
                        Text("Your skill library is empty")
                            .font(.btBodyMedium)
                            .foregroundStyle(Color.btText)
                        SettingsCaption("Use Add Skills above to choose a folder or GitHub repository. Its skills will appear here for your projects.")
                    }
                    .padding(.vertical, Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Library")
            } footer: {
                SettingsCaption("A skill is a folder with a SKILL.md. Choose which library skills each project's chats get in Project Settings. Abstract hands them to the agent when a chat starts.")
            }
            .id("skills.library")
            Section {
                if !projects.isEmpty {
                    ForEach(projects, id: \.0.id) { project, skills in
                        ProjectSkillRows(projectName: project.name, skills: skills, query: search,
                                         expanded: expandedProjectId == project.id) {
                            expandedProjectId = expandedProjectId == project.id ? nil : project.id
                        }
                    }
                } else if !search.isEmpty {
                    SettingsCaption("No project skills match “\(search)”.")
                } else {
                    SettingsCaption("Skills stored in a project's own files will appear here.")
                }
            } header: {
                Text("In your projects")
            } footer: {
                SettingsCaption("These skills live in each project's own files. Agents that read those folders already use them, so Abstract does not hand them out again.")
            }
            .id("skills.projects")
        }
        .settingsScrollablePane()
        .onAppear {
            model.reloadSkills()
            projectSkillsById = Dictionary(uniqueKeysWithValues: model.projects
                .filter { $0.archivedAt == nil }
                .map { ($0.id, model.projectSkills($0.id)) })
        }
        .sheet(item: $update) { update in
            SkillUpdateSheet(update: update) { self.update = nil }
        }
    }

    private func check(_ source: SkillSource) {
        checking = source.id
        Task {
            do {
                if let found = try await model.checkSkillUpdate(source.id) { update = found }
                else { model.flash("\(source.title) is up to date.") }
            } catch {
                model.flash("Couldn't check \(source.title): \(error.localizedDescription)", isError: true)
            }
            checking = nil
        }
    }
}

/// Kept beside the Skills title so adding a source never depends on scroll position.
struct SkillsAddButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingRepositorySheet = false

    var body: some View {
        Menu {
            Button("Folder…", action: addFolder)
            Button("GitHub Repository…") { showingRepositorySheet = true }
        } label: {
            Label("Add Skills", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.bt(.secondary, size: .small))
        .fixedSize()
        .sheet(isPresented: $showingRepositorySheet) {
            SkillRepositoryAddSheet { showingRepositorySheet = false }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder of skills"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addSkillFolder(url.path)
    }
}

private struct SkillRepositoryAddSheet: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    @State private var repository = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Add Skills from GitHub").font(.btHeadline)
            Text("Enter owner/name or a GitHub URL. Abstract pins the repository to its latest commit; it changes only when you choose Update.")
                .font(.btBody)
                .foregroundStyle(Color.btTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("owner/name or URL", text: $repository)
                .btField()
                .onSubmit(addRepository)
                .accessibilityLabel("GitHub repository")
            if let error {
                Text(error)
                    .font(.btCaption)
                    .foregroundStyle(Color.btRemoved)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(adding)
                Button(adding ? "Adding…" : "Add", action: addRepository)
                    .keyboardShortcut(.defaultAction)
                    .disabled(adding || repository.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 440)
    }

    private func addRepository() {
        let text = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adding, !text.isEmpty else { return }
        adding = true
        error = nil
        Task {
            do {
                try await model.addSkillRepository(text)
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            adding = false
        }
    }
}

/// One source: where it is, its skills, and what can be done with it.
private struct SkillSourceRows: View {
    @Environment(AppModel.self) private var model
    let source: SkillSource
    let skills: [LibrarySkill]
    let query: String
    let expanded: Bool
    let checking: Bool
    let onToggle: () -> Void
    let onCheck: () -> Void

    var body: some View {
        let matchingSkills = query.isEmpty ? [] : skills.filter {
            skillSearchMatches(query, in: $0.name + " " + ($0.description ?? ""))
        }
        let visibleSkills = expanded ? skills : matchingSkills
        Group {
            Button(action: onToggle) {
                HStack(spacing: Space.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.btCaption)
                        .frame(width: 12)
                    Image(systemName: source.kind == .github ? "shippingbox" : "folder")
                    Text(source.title).font(.btHeadline)
                    Spacer()
                    Text(query.isEmpty || expanded || matchingSkills.isEmpty ? skillCount(skills.count) : "\(matchingSkills.count) of \(skillCount(skills.count))")
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextSecondary)
                }
                .foregroundStyle(Color.btText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(source.title), \(skillCount(skills.count))")
            .accessibilityHint(expanded ? "Collapse source" : "Expand source")
            if skills.isEmpty && expanded {
                SettingsCaption(source.kind == .folder && !FileManager.default.fileExists(atPath: source.location)
                                ? "This folder isn't there any more." : "No skills here: none of its folders holds a SKILL.md.")
            }
            ForEach(visibleSkills) { skill in
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(skill.name)
                    if let description = skill.description { Text(description).lineLimit(2) }
                }
            }
            if expanded {
                LabeledContent {
                    HStack(spacing: 6) {
                        if source.kind == .github {
                            Button(checking ? "Checking…" : "Update…", action: onCheck)
                                .disabled(checking)
                        }
                        Button("Remove", role: .destructive) { model.removeSkillSource(source.id) }
                    }
                } label: {
                    Text(source.kind == .github ? "Pinned to \(source.commit.map { String($0.prefix(7)) } ?? "?")" : source.location)
                    Text(source.kind == .github ? "Update shows what changed before anything moves. Removing takes its skills out of every project."
                         : "Removing takes its skills out of every project. The folder itself stays.")
                }
            }
        }
    }
}

private struct ProjectSkillRows: View {
    let projectName: String
    let skills: [LibrarySkill]
    let query: String
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let matchingSkills = query.isEmpty ? [] : skills.filter {
            skillSearchMatches(query, in: $0.name + " " + ($0.description ?? ""))
        }
        Group {
            Button(action: onToggle) {
                HStack(spacing: Space.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.btCaption)
                        .frame(width: 12)
                    Image(systemName: "folder")
                    Text(projectName).font(.btHeadline)
                    Spacer()
                    Text(query.isEmpty || expanded || matchingSkills.isEmpty ? skillCount(skills.count) : "\(matchingSkills.count) of \(skillCount(skills.count))")
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextSecondary)
                }
                .foregroundStyle(Color.btText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(projectName), \(skillCount(skills.count))")
            .accessibilityHint(expanded ? "Collapse project" : "Expand project")
            ForEach(expanded ? skills : matchingSkills) { skill in
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(skill.name)
                    if let description = skill.description { Text(description).lineLimit(2) }
                }
            }
        }
    }
}

private func skillCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "skill" : "skills")"
}

private func skillSearchMatches(_ query: String, in text: String) -> Bool {
    let terms = query.split(whereSeparator: \.isWhitespace)
    return terms.allSatisfy { text.localizedStandardContains(String($0)) }
}

/// A repository's newer commit, as a diff, before the source moves to it.
private struct SkillUpdateSheet: View {
    @Environment(AppModel.self) private var model
    let update: SkillUpdate
    let onClose: () -> Void
    @State private var applying = false

    var body: some View {
        let files = Diff.parse(update.diff)
        let title = model.skillSources.first { $0.id == update.sourceId }?.title ?? "Skills"
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Update \(title)?").font(.btHeadline)
            Text("From \(update.from.prefix(7)) to \(update.to.prefix(7)): \(files.count) \(files.count == 1 ? "file changes" : "files change"). Chats that start after the update get the new version; running ones keep theirs.")
                .font(.btCallout)
                .foregroundStyle(Color.btTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(files) { file in SkillDiffFile(file: file) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240, maxHeight: 460)
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(applying ? "Updating…" : "Update") {
                    applying = true
                    Task {
                        do { try await model.applySkillUpdate(update) } catch {
                            model.flash("Couldn't update \(title): \(error.localizedDescription)", isError: true)
                        }
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(applying)
            }
        }
        .padding(Space.xl)
        .frame(width: 640)
    }
}

private struct SkillDiffFile: View {
    let file: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.sm) {
                Text(file.path).font(.btChatMonoSmall).foregroundStyle(Color.btText)
                DiffCounts(additions: file.additions, deletions: file.deletions, hideZeros: true)
            }
            .padding(.bottom, 2)
            ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                Text(hunk.header).font(.btChatMonoSmall).foregroundStyle(Color.btTextTertiary)
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    Text(String(line.origin.rawValue) + line.content)
                        .font(.btChatMonoSmall)
                        .foregroundStyle(line.origin == .added ? Color.btAdded : line.origin == .removed ? Color.btRemoved : Color.btTextSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
