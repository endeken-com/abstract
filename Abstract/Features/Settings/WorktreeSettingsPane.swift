import SwiftUI
import AbstractCore

/// Where worktrees live and what their branches are called.
struct WorktreeSettingsPane: View {
    @Environment(AppModel.self) private var model

    private static let sampleRepo = "api"
    private static let sampleSlug = "oslo"
    private static let sampleBranchSlug = "fix-login"

    private static let tokens: [(token: String, meaning: String)] = [
        ("{home}", "Your home folder"),
        ("{repo}", "The repository's folder name"),
        ("{hash}", "8 characters of the repo path's hash, keeping same-named repos apart"),
        ("{slug}", "The short worktree name, lowercased and dashed"),
        ("{branch}", "The full branch name, prefix included"),
        ("{prefix}", "The branch prefix below"),
    ]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                SettingsInputRow(title: "Worktree location",
                                 detail: "The folder each chat's worktree is created in. Projects can override it.",
                                 warning: templateWarning) {
                    TextField("Worktree location", text: $model.worktreeTemplate, prompt: Text(WorktreeNaming.defaultTemplate))
                        .labelsHidden()
                        .font(.btMono)
                        .btField()
                }
                SettingsInputRow(title: "Branch prefix",
                                 detail: "Put in front of every branch Abstract creates, so its branches group together.",
                                 warning: prefixWarning) {
                    TextField("Branch prefix", text: $model.branchPrefix, prompt: Text(WorktreeNaming.defaultBranchPrefix))
                        .labelsHidden()
                        .font(.btMono)
                        .btField()
                }
            } header: {
                Text("Naming")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Worktree")
                    Text(abbreviated(preview.path))
                        .font(.btMono)
                        .foregroundStyle(Color.btTextSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(preview.path)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Branch")
                    Text(preview.branch)
                        .font(.btMono)
                        .foregroundStyle(Color.btTextSecondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Preview")
            } footer: {
                SettingsCaption("By default, worktree folders use city names and branches describe the task. This shows “Oslo” and “fix-login” in “\(Self.sampleRepo)”.")
            }

            Section {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: 6) {
                    ForEach(Self.tokens, id: \.token) { item in
                        GridRow {
                            Text(item.token)
                                .font(.btMono)
                                .foregroundStyle(Color.btText)
                            Text(item.meaning)
                                .font(.btCallout)
                                .foregroundStyle(Color.btTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Tokens")
            }

            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.md) {
                        SettingsCaption("Existing worktrees stay where they are; new chats use the new names.")
                        Spacer(minLength: Space.sm)
                        resetButton
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                        SettingsCaption("Existing worktrees stay where they are; new chats use the new names.")
                        resetButton
                    }
                }
            }
        }
        .settingsPane()
    }

    private var resetButton: some View {
        Button("Reset to Default") {
            model.worktreeTemplate = WorktreeNaming.defaultTemplate
            model.branchPrefix = WorktreeNaming.defaultBranchPrefix
        }
        .disabled(model.worktreeTemplate == WorktreeNaming.defaultTemplate && model.branchPrefix == WorktreeNaming.defaultBranchPrefix)
        .fixedSize()
    }

    private var preview: (path: String, branch: String) {
        let home = model.executor.homeDirectory
        let prefix = model.branchPrefix
        let branch = prefix + Self.sampleBranchSlug
        let path = WorktreeNaming.render(
            template: model.worktreeTemplate.isEmpty ? WorktreeNaming.defaultTemplate : model.worktreeTemplate,
            home: home, repo: Self.sampleRepo, hash: WorktreeNaming.shortHash(home + "/code/" + Self.sampleRepo),
            slug: Self.sampleSlug, branch: branch, prefix: prefix
        )
        return (path, branch)
    }

    /// The home folder shown as ~ so the interesting part stays visible.
    private func abbreviated(_ path: String) -> String {
        let home = model.executor.homeDirectory
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private var templateWarning: String? {
        let t = model.worktreeTemplate
        if t.trimmingCharacters(in: .whitespaces).isEmpty { return "A location is required. Reset to the default below." }
        if !t.contains("{slug}") && !t.contains("{branch}") { return "Include {slug} or {branch} so each chat gets its own folder." }
        if t.hasPrefix("~") { return "~ isn't expanded here. Start the path with {home} instead." }
        if !t.hasPrefix("/") && !t.hasPrefix("{home}") { return "Use an absolute path, e.g. one starting with {home}." }
        return nil
    }

    private var prefixWarning: String? {
        let p = model.branchPrefix
        if p.contains(where: \.isWhitespace) { return "Branch names can't contain spaces." }
        if p.contains("..") || p.contains("~") || p.contains("^") || p.contains(":") || p.contains("\\") {
            return "Git doesn't allow .., ~, ^, : or \\ in branch names."
        }
        return nil
    }
}
