import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// A project's settings as one quiet document: the header, then General,
/// Branches & naming, Location & checkout, Lifecycle scripts and the danger
/// zone. Every change is stored at once; text is stored after a pause.
struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    let projectId: String
    /// `origin`'s URL; nil until read, then "" when there is none.
    @State private var origin: String?

    var body: some View {
        if let project = model.project(projectId) {
            let owner = origin.flatMap(GitRemote.githubOwner)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ProjectHeader(project: project, owner: owner)
                    GeneralSection(project: project, origin: origin, owner: owner)
                    BranchSection(project: project)
                    LocationSection(project: project)
                    ScriptsSection(project: project)
                    DangerSection(project: project)
                }
                .frame(maxWidth: ProjectPage.width, alignment: .leading)
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.xl)
                .padding(.bottom, 56)
            }
            .background(Color.btCanvas)
            .task(id: project.rootPath) {
                origin = await Git.originURL(model.executor, root: project.rootPath) ?? ""
            }
        } else {
            EmptyStateView(symbol: "folder.badge.questionmark", title: "This project no longer exists")
        }
    }
}

/// Where everything on the page lines up.
enum ProjectPage {
    static let width: CGFloat = 760
    /// The label column; controls start after it.
    static let labelWidth: CGFloat = 248
    static let columnGap: CGFloat = Space.xl
    /// Every simple row's control line.
    static let controlHeight: CGFloat = Field.height
    static let rowGap: CGFloat = 20
}

// MARK: - Layout pieces

/// A section: its small label, an optional sentence, then its rows.
private struct PageSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AutoSectionLabel(title: title)
            if let detail {
                Text(detail)
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.xs)
            }
            VStack(alignment: .leading, spacing: ProjectPage.rowGap) { content() }
                .padding(.top, Space.xs)
        }
        .padding(.top, 40)
    }
}

/// Label (and what it does) on the left, the control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: ProjectPage.columnGap) {
            RowLabel(title: title, detail: detail)
                .frame(width: ProjectPage.labelWidth, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, minHeight: ProjectPage.controlHeight, alignment: .topLeading)
        }
    }
}

/// A row whose editor takes the page's full width, under its label.
private struct StackedSetting<Editor: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var editor: () -> Editor

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            RowLabel(title: title, detail: detail, centred: false)
            editor()
        }
    }
}

private struct RowLabel: View {
    let title: String
    let detail: String?
    /// The title sits level with a 30 pt control beside it.
    var centred = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.btBody)
                .foregroundStyle(Color.btText)
                .frame(minHeight: centred ? ProjectPage.controlHeight : 0, alignment: .leading)
            if let detail {
                Text(detail)
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, centred ? -5 : 0)
            }
        }
    }
}

/// A path or remote as it reads: mono, muted, cut in the middle when long.
private struct PathText: View {
    let text: String
    var quiet = false

    var body: some View {
        Text(text)
            .font(BTFont.mono(12))
            .foregroundStyle(quiet ? Color.btTextTertiary : Color.btTextSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }
}

/// Text that stores itself after a short pause, and follows the stored
/// value when it changes somewhere else.
private struct Autosave: ViewModifier {
    @Binding var draft: String
    /// What is stored now, in the draft's terms.
    let stored: String
    var delay: Duration = .milliseconds(500)
    /// How the draft reads once stored (trimmed, normalised).
    var normalize: (String) -> String = { $0 }
    let save: (String) -> Void
    @State private var lastSaved: String?

    func body(content: Content) -> some View {
        content
            .task(id: draft) {
                guard normalize(draft) != stored else { return }
                guard (try? await Task.sleep(for: delay)) != nil else { return }
                commit()
            }
            .onChange(of: stored) { _, new in
                // Our own save coming back: keep typing undisturbed.
                if new == lastSaved { return }
                if normalize(draft) != new { draft = new }
            }
            .onDisappear { if normalize(draft) != stored { commit() } }
    }

    private func commit() {
        lastSaved = normalize(draft)
        save(draft)
    }
}

private extension View {
    func autosave(_ draft: Binding<String>, stored: String, delay: Duration = .milliseconds(500),
                  normalize: @escaping (String) -> String = { $0 }, save: @escaping (String) -> Void) -> some View {
        modifier(Autosave(draft: draft, stored: stored, delay: delay, normalize: normalize, save: save))
    }
}

/// The shared editor, as tall as its text: the page scrolls, never the
/// editor. A hidden copy of the text sizes it.
private struct GrowingEditor: View {
    @Binding var text: String
    var placeholder: String? = nil
    var mono = false
    var minHeight: CGFloat = 76

    var body: some View {
        Text(text + "\n ")
            .font(mono ? BTFont.mono(12.5) : .btBody)
            .padding(.horizontal, Field.inset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay {
                BTTextEditor(text: $text, placeholder: placeholder, mono: mono, minHeight: minHeight)
                    .scrollDisabled(true)
                    .scrollIndicators(.never)
            }
    }
}

/// A small icon button beside a value (open, choose a folder).
private struct ValueButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.icon(size: 24))
            .help(help)
    }
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

private func chooseFolder(message: String, prompt: String, startingAt path: String?) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = prompt
    if let path { panel.directoryURL = URL(fileURLWithPath: path) }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

// MARK: - Header

private struct ProjectHeader: View {
    let project: Project
    let owner: String?

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            ProjectIconView(project: project, owner: owner, size: 36)
            Text(project.name)
                .font(BTFont.ui(24, .semibold))
                .foregroundStyle(Color.btText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Space.lg)
            DeviceMenu()
        }
    }
}

/// Where the project's agents run. This Mac is the only place today.
private struct DeviceMenu: View {
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("Device", selection: .constant("local")) {
                Label("This Mac", systemImage: "laptopcomputer").tag("local")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "laptopcomputer").font(.system(size: 11, weight: .regular))
                Text("This Mac").font(.btCallout.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Color.btTextTertiary)
            }
            .foregroundStyle(Color.btTextSecondary)
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(hovering ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .padding(.trailing, -7)
        .help("Where this project's agents run")
    }
}

// MARK: - General

private struct GeneralSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let origin: String?
    let owner: String?
    @State private var name: String

    init(project: Project, origin: String?, owner: String?) {
        self.project = project
        self.origin = origin
        self.owner = owner
        _name = State(initialValue: project.name)
    }

    var body: some View {
        PageSection(title: "General") {
            SettingRow(title: "Name") {
                BTTextField("Name", text: $name, prompt: "Project name")
                    .frame(maxWidth: 320)
                    .autosave($name, stored: project.name, normalize: trimmed) { model.renameProject(project.id, to: $0) }
            }
            SettingRow(title: "Repository") {
                repository.frame(minHeight: ProjectPage.controlHeight)
            }
            SettingRow(title: "Icon",
                       detail: "Pick an icon and a color, or upload a custom image. Defaults to the linked GitHub owner's avatar.") {
                ProjectIconButton(project: project, owner: owner)
            }
        }
    }

    @ViewBuilder
    private var repository: some View {
        switch origin {
        case nil:
            Color.clear.frame(width: 1, height: 1)
        case ""?:
            Text("No origin remote").font(.btBody).foregroundStyle(Color.btTextTertiary)
        case let url?:
            HStack(spacing: Space.xs) {
                PathText(text: url)
                if let web = GitRemote.webURL(url) {
                    ValueButton(symbol: "arrow.up.right", help: "Open \(web.host ?? "it") in your browser") {
                        NSWorkspace.shared.open(web)
                    }
                }
            }
        }
    }
}

// MARK: - Branches & naming

private struct BranchSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var customPrefix: String
    /// Custom stays chosen while its field is being edited, even empty.
    @State private var choosingCustom = false
    @State private var instructions: String

    init(project: Project) {
        self.project = project
        _customPrefix = State(initialValue: project.branchPrefix ?? "")
        _instructions = State(initialValue: project.namingInstructions ?? "")
    }

    private enum Mode: Hashable { case global, none, custom }

    private var mode: Mode {
        if choosingCustom { return .custom }
        switch project.branchPrefix {
        case nil: return .global
        case ""?: return .none
        default: return .custom
        }
    }

    var body: some View {
        PageSection(title: "Branches & naming") {
            SettingRow(title: "Branch prefix", detail: "Put in front of each new branch in this project.") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.sm) {
                        SentenceMenu(title: title) {
                            Picker("Branch prefix", selection: Binding(get: { mode }, set: { choose($0) })) {
                                Text("Use Global Default (\(model.branchPrefix.isEmpty ? "none" : model.branchPrefix))").tag(Mode.global)
                                Text("No Prefix").tag(Mode.none)
                                Text("Custom…").tag(Mode.custom)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        .padding(.leading, -Chip.inset)
                        if mode == .custom {
                            BTTextField("Prefix", text: $customPrefix, prompt: "e.g. wes/", mono: true)
                                .frame(width: 180)
                                .autosave($customPrefix, stored: project.branchPrefix ?? "",
                                          normalize: { $0.trimmingCharacters(in: .whitespaces) }) { value in
                                    model.updateProject(project.id) { $0.branchPrefix = value.trimmingCharacters(in: .whitespaces) }
                                }
                        }
                    }
                    .frame(minHeight: ProjectPage.controlHeight)
                    if mode == .custom, let warning = BranchPrefixCheck.warning(customPrefix) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.btCallout)
                            .foregroundStyle(Color.btWarning)
                    }
                }
            }
            StackedSetting(title: "Naming instructions",
                           detail: "Guides AI-generated workspace and branch names for this project. Empty uses the default naming.") {
                GrowingEditor(text: $instructions,
                             placeholder: "e.g. Start branches with fix/ or feat/. Keep titles short, in sentence case.",
                             minHeight: 76)
                    .autosave($instructions, stored: project.namingInstructions ?? "", delay: .milliseconds(800),
                              normalize: trimmed) { value in
                        model.updateProject(project.id) { $0.namingInstructions = trimmed(value).isEmpty ? nil : trimmed(value) }
                    }
            }
        }
    }

    private var title: String {
        switch mode {
        case .global: "Global default (\(model.branchPrefix.isEmpty ? "none" : model.branchPrefix))"
        case .none: "No prefix"
        case .custom: "Custom"
        }
    }

    private func choose(_ new: Mode) {
        switch new {
        case .global:
            choosingCustom = false
            model.updateProject(project.id) { $0.branchPrefix = nil }
        case .none:
            choosingCustom = false
            model.updateProject(project.id) { $0.branchPrefix = "" }
        case .custom:
            choosingCustom = true
            if (project.branchPrefix ?? "").isEmpty {
                customPrefix = model.branchPrefix
                model.updateProject(project.id) { $0.branchPrefix = model.branchPrefix }
            }
        }
    }
}

/// What git won't take in a branch prefix.
enum BranchPrefixCheck {
    static func warning(_ prefix: String) -> String? {
        if prefix.contains(where: \.isWhitespace) { return "Branch names can't contain spaces." }
        if prefix.contains("..") || prefix.contains("~") || prefix.contains("^") || prefix.contains(":") || prefix.contains("\\") {
            return "Git doesn't allow .., ~, ^, : or \\ in branch names."
        }
        return nil
    }
}

// MARK: - Location & checkout

private struct LocationSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var sparse: String
    @State private var moving = false
    @State private var locationError: String?

    /// The tail a chosen folder gets, like the global default's.
    static let folderTail = "/{repo}-{hash}/{slug}"

    init(project: Project) {
        self.project = project
        _sparse = State(initialValue: project.sparseCheckout.joined(separator: "\n"))
    }

    private var home: String { model.executor.homeDirectory }

    var body: some View {
        PageSection(title: "Location & checkout") {
            SettingRow(title: "Location", detail: "The repository on this Mac. Choose its new folder if you moved it.") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        PathText(text: AppModel.abbreviated(project.rootPath, home: home))
                        if moving { ProgressView().controlSize(.mini) }
                        ValueButton(symbol: "folder", help: "Choose the repository's folder…", action: relocate)
                            .disabled(moving)
                    }
                    .frame(minHeight: ProjectPage.controlHeight)
                    if let locationError {
                        Text(locationError)
                            .font(.btCallout)
                            .foregroundStyle(Color.btRemoved)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            SettingRow(title: "Worktrees", detail: "Where this project's new worktrees are created.") {
                HStack(spacing: Space.xs) {
                    if let template = project.worktreeTemplate {
                        PathText(text: displayed(template))
                        ValueButton(symbol: "folder", help: "Choose another folder…", action: chooseWorktreeFolder)
                        Button("Use Global Default") { model.updateProject(project.id) { $0.worktreeTemplate = nil } }
                            .buttonStyle(.bt(.ghost, size: .small))
                    } else {
                        Text("Global default").font(.btBody).foregroundStyle(Color.btTextTertiary).fixedSize()
                        PathText(text: displayed(model.worktreeTemplate), quiet: true)
                            .padding(.leading, Space.xs)
                        ValueButton(symbol: "folder", help: "Choose a folder for this project's worktrees…", action: chooseWorktreeFolder)
                    }
                }
                .frame(minHeight: ProjectPage.controlHeight)
            }
            StackedSetting(title: "Sparse checkout",
                           detail: "Folders new worktrees check out, one per line, relative to the repository root. Files at the root are always included. Empty checks out everything.") {
                GrowingEditor(text: $sparse, placeholder: "apps/web\npackages/ui", mono: true, minHeight: 76)
                    .autosave($sparse, stored: project.sparseCheckout.joined(separator: "\n"), delay: .milliseconds(800),
                              normalize: { SparseCheckout.parse($0).joined(separator: "\n") }) { value in
                        model.updateProject(project.id) { $0.sparseCheckout = SparseCheckout.parse(value) }
                    }
            }
        }
    }

    /// A template as a folder: the base when it ends like the default, else
    /// the template itself; `{home}` and the home folder as ~.
    private func displayed(_ template: String) -> String {
        var text = template.hasSuffix(Self.folderTail) ? String(template.dropLast(Self.folderTail.count)) : template
        if text.hasPrefix("{home}") { text = "~" + text.dropFirst("{home}".count) }
        return AppModel.abbreviated(text, home: home)
    }

    private func relocate() {
        guard let dir = chooseFolder(message: "Choose where \(project.name) is now", prompt: "Use This Folder",
                                     startingAt: (project.rootPath as NSString).deletingLastPathComponent) else { return }
        moving = true
        locationError = nil
        Task {
            do {
                try await model.relocateProject(project.id, to: dir)
            } catch {
                locationError = error.localizedDescription
            }
            moving = false
        }
    }

    private func chooseWorktreeFolder() {
        let current = project.worktreeTemplate.map { displayed($0) }
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        guard let dir = chooseFolder(message: "Choose where \(project.name)'s worktrees go", prompt: "Use This Folder",
                                     startingAt: current) else { return }
        let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        model.updateProject(project.id) { $0.worktreeTemplate = base + Self.folderTail }
    }
}

// MARK: - Lifecycle scripts

private enum ScriptKind: String, CaseIterable, Hashable {
    case setup, teardown, run

    var title: String {
        switch self {
        case .setup: "Setup"
        case .teardown: "Teardown"
        case .run: "Run"
        }
    }

    var detail: String {
        switch self {
        case .setup: "Runs in a terminal under the chat when its new worktree is created. The agent starts alongside it."
        case .teardown: "Runs in the worktree before Abstract removes it, for at most a minute. Removal goes ahead if it fails."
        case .run: "The Run button in the chat's toolbar runs this in a terminal under the chat; pressing it again restarts it."
        }
    }

    var placeholder: String {
        switch self {
        case .setup: "npm install\ncp \"$HOME/.config/app/.env\" ."
        case .teardown: "docker compose down"
        case .run: "npm run dev"
        }
    }

    func value(_ p: Project) -> String? {
        switch self {
        case .setup: p.setupScript
        case .teardown: p.teardownScript
        case .run: p.runScript
        }
    }

    /// Blank lines around it and trailing spaces dropped; otherwise as typed.
    static func storedForm(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.last == " " || l.last == "\t" || l.last == "\r" { l.removeLast() }
            return l
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    func set(_ p: inout Project, _ text: String?) {
        switch self {
        case .setup: p.setupScript = text
        case .teardown: p.teardownScript = text
        case .run: p.runScript = text
        }
    }
}

private struct ScriptsSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @AppStorage("projectSettings.scriptTab") private var tab: ScriptKind = .setup

    var body: some View {
        PageSection(title: "Lifecycle scripts", detail: "Commands run for workspace setup, teardown, and the Run button.") {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    PageTabs(selection: $tab, items: ScriptKind.allCases.map { .init(value: $0, title: $0.title) })
                    Spacer(minLength: Space.sm)
                    Button("Import…", action: importFile)
                        .buttonStyle(.bt(.ghost, size: .small))
                        .padding(.trailing, -9)
                        .help("Load a script file into the \(tab.title.lowercased()) script")
                }
                ScriptEditor(project: project, kind: tab).id(tab)
            }
        }
    }

    /// Stores the file's text as the current tab's script; its editor follows.
    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a script for \(project.name)'s \(tab.title.lowercased()) step"
        panel.prompt = "Import"
        panel.directoryURL = URL(fileURLWithPath: project.rootPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 256 * 1024, let contents = String(data: data, encoding: .utf8) else {
                model.flash("That file isn't a text script.", isError: true)
                return
            }
            let script = ScriptKind.storedForm(contents)
            let kind = tab
            model.updateProject(project.id) { kind.set(&$0, script.isEmpty ? nil : script) }
        } catch {
            model.flash(error.localizedDescription, isError: true)
        }
    }
}

private struct ScriptEditor: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let kind: ScriptKind
    @State private var text: String

    init(project: Project, kind: ScriptKind) {
        self.project = project
        self.kind = kind
        _text = State(initialValue: kind.value(project) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(kind.detail)
                .font(.btCallout)
                .foregroundStyle(Color.btTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            GrowingEditor(text: $text, placeholder: kind.placeholder, mono: true, minHeight: 132)
                .autosave($text, stored: kind.value(project) ?? "", delay: .milliseconds(800),
                          normalize: ScriptKind.storedForm) { value in
                    let stored = ScriptKind.storedForm(value)
                    model.updateProject(project.id) { kind.set(&$0, stored.isEmpty ? nil : stored) }
                }
        }
    }
}

// MARK: - Danger zone

private struct DangerSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var confirming = false

    var body: some View {
        PageSection(title: "Danger zone") {
            SettingRow(title: "Delete project", detail: "Removes \(project.name) and its chats from Abstract.") {
                Button("Delete Project…") { confirming = true }
                    .buttonStyle(.bt(.danger, size: .small))
                    .padding(.leading, -9)
                    .frame(minHeight: ProjectPage.controlHeight)
            }
        }
        .alert("Remove \(project.name) from Abstract?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { model.removeProject(project.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its chats are removed from Abstract. The repository and any worktrees on disk are left alone.")
        }
    }
}
