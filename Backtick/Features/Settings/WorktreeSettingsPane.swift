import SwiftUI
import BacktickCore

/// Where worktrees live and what their branches are called.
struct WorktreeSettingsPane: View {
    @Environment(AppModel.self) private var model

    private static let sampleRepo = "api"
    private static let sampleSlug = "fix-login"

    private static let tokens: [(token: String, meaning: String)] = [
        ("{home}", "Your home folder"),
        ("{repo}", "The repository's folder name"),
        ("{hash}", "8 characters of the repo path's hash, keeping same-named repos apart"),
        ("{slug}", "The chat's title, lowercased and dashed"),
        ("{branch}", "The full branch name, prefix included"),
        ("{prefix}", "The branch prefix below"),
    ]

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Worktree location")
                    TextField("Worktree location", text: $model.worktreeTemplate, prompt: Text(WorktreeNaming.defaultTemplate))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.btMono)
                    SettingsCaption("The folder each chat's worktree is created in. Projects can override it.")
                    if let warning = templateWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.btCaption)
                            .foregroundStyle(Color.btWarning)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Branch prefix")
                    TextField("Branch prefix", text: $model.branchPrefix, prompt: Text(WorktreeNaming.defaultBranchPrefix))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.btMono)
                    SettingsCaption("Put in front of every branch Backtick creates, so its branches group together.")
                    if let warning = prefixWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.btCaption)
                            .foregroundStyle(Color.btWarning)
                    }
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
                SettingsCaption("For a repository named “\(Self.sampleRepo)” and a chat titled “Fix login”.")
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
                HStack {
                    SettingsCaption("Existing worktrees stay where they are; new chats use the new names.")
                    Spacer()
                    Button("Reset to Default") {
                        model.worktreeTemplate = WorktreeNaming.defaultTemplate
                        model.branchPrefix = WorktreeNaming.defaultBranchPrefix
                    }
                    .disabled(model.worktreeTemplate == WorktreeNaming.defaultTemplate && model.branchPrefix == WorktreeNaming.defaultBranchPrefix)
                }
            }
        }
        .settingsPane()
    }

    private var preview: (path: String, branch: String) {
        let home = model.executor.homeDirectory
        let prefix = model.branchPrefix
        let branch = prefix + Self.sampleSlug
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
