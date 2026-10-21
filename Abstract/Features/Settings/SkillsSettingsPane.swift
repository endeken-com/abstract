import AppKit
import SwiftUI
import AbstractCore

/// The skill library (ABS-122): folders and GitHub repositories of
/// skills, managed once and chosen per project in Project Settings. A
/// repository stays at the commit it was added at until you update it,
/// after seeing the diff.
struct SkillsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var repository = ""
    @State private var adding = false
    @State private var error: String?
    @State private var checking: String?
    @State private var update: SkillUpdate?

    var body: some View {
        Form {
            ForEach(model.skillSources) { source in
                SkillSourceSection(source: source, checking: checking == source.id) { check(source) }
            }
            Section {
                LabeledContent {
                    Button("Add Folder…", action: addFolder)
                } label: {
                    Text("A folder")
                    Text("Every folder in it holding a SKILL.md is a skill. Edits there reach the next chat that starts.")
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("owner/name", text: $repository, prompt: Text("owner/name or URL"))
                            .labelsHidden()
                            .btField(compact: true)
                            .frame(maxWidth: 240)
                            .onSubmit(addRepository)
                        Button(adding ? "Adding…" : "Add", action: addRepository)
                            .buttonStyle(.bt(.secondary, size: .small))
                            .disabled(adding || repository.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } label: {
                    Text("A GitHub repository")
                    Text(error ?? "Pinned to its latest commit now. It changes only when you update it.")
                        .foregroundStyle(error == nil ? Color.btTextSecondary : Color.btRemoved)
                }
            } header: {
                Text("Add skills")
            } footer: {
                SettingsCaption("A skill is a folder with a SKILL.md that tells an agent how to do one kind of task. Choose which ones each project's chats get in its Project Settings. Abstract hands them to the chat's agent when it starts, and never changes an agent's own skills folder.")
            }
            let projects = model.projects.filter { $0.archivedAt == nil }
                .map { ($0, model.projectSkills($0.id)) }.filter { !$0.1.isEmpty }
            if !projects.isEmpty {
                Section {
                    ForEach(projects, id: \.0.id) { project, skills in
                        LabeledContent {
                            Text(skills.map(\.name).joined(separator: ", "))
                                .foregroundStyle(Color.btTextSecondary)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text(project.name)
                        }
                    }
                } header: {
                    Text("In your projects")
                } footer: {
                    SettingsCaption("Skills a project keeps in its own files, such as .claude/skills. Agents that read that folder already use them, so they are listed here, not handed out again.")
                }
            }
        }
        .settingsPane()
        .onAppear { model.reloadSkills() }
        .sheet(item: $update) { update in
            SkillUpdateSheet(update: update) { self.update = nil }
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

    private func addRepository() {
        let text = repository
        guard !adding, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        adding = true
        error = nil
        Task {
            do {
                try await model.addSkillRepository(text)
                repository = ""
            } catch {
                self.error = error.localizedDescription
            }
            adding = false
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

/// One source: where it is, its skills, and what can be done with it.
private struct SkillSourceSection: View {
    @Environment(AppModel.self) private var model
    let source: SkillSource
    let checking: Bool
    let onCheck: () -> Void

    var body: some View {
        Section {
            let skills = model.skills(in: source.id)
            if skills.isEmpty {
                SettingsCaption(source.kind == .folder && !FileManager.default.fileExists(atPath: source.location)
                                ? "This folder isn't there any more." : "No skills here: none of its folders holds a SKILL.md.")
            }
            ForEach(skills) { skill in
                LabeledContent {
                    EmptyView()
                } label: {
                    Text(skill.name)
                    if let description = skill.description { Text(description).lineLimit(2) }
                }
            }
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
        } header: {
            HStack(spacing: Space.sm) {
                Image(systemName: source.kind == .github ? "shippingbox" : "folder")
                    .foregroundStyle(Color.btTextSecondary)
                Text(source.title).font(.btHeadline).foregroundStyle(Color.btText)
            }
        }
    }
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
