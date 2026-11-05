import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// A project's settings as one document, grouped into cards: the header
/// (icon, name, remote), then New chats, Permissions, Git, Agent context,
/// Scripts and the danger zone, with a rail beside them that follows the
/// scroll. Every change is stored at once; text is stored after a pause.
struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projectId: String
    /// `origin`'s URL; nil until read, then "" when there is none.
    @State private var origin: String?
    @State private var spy = SectionSpy()
    /// Counts stored changes, for the header's "Saved".
    @State private var savedTick = 0
    /// What was stored when the page opened; changes before then aren't saves.
    @State private var openedAt = Date.now

    var body: some View {
        if let project = model.project(projectId) {
            let owner = origin.flatMap(GitRemote.githubOwner)
            GeometryReader { geo in
                let showsRail = geo.size.width >= ProjectPage.railBreakpoint
                ScrollViewReader { proxy in
                    let jump = { (section: ProjectSettingsSection) in
                        spy.hold(section)
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) { proxy.scrollTo(section, anchor: .top) }
                    }
                    ZStack(alignment: .top) {
                        ScrollView {
                            columns(rail: showsRail) {
                                Color.clear.frame(height: 1)
                            } content: {
                                VStack(alignment: .leading, spacing: 0) {
                                    ProjectHeader(project: project, origin: origin, owner: owner, savedTick: savedTick,
                                                  jump: showsRail ? nil : jump)
                                    NewChatSection(project: project)
                                    PermissionsSection(project: project)
                                    GitSection(project: project)
                                    ContextSection(project: project)
                                    ScriptsSection(project: project)
                                    DangerSection(project: project)
                                }
                            }
                            .padding(.top, Space.xl)
                            .padding(.bottom, 56)
                        }
                        .coordinateSpace(.named(ProjectPage.scrollSpace))
                        .onScrollGeometryChange(for: Bool.self) { g in
                            g.visibleRect.maxY >= g.contentSize.height - 4
                        } action: { _, atEnd in spy.atEnd = atEnd }
                        .btThinScrollIndicator()

                        // Drawn over the scroll view so it stays put; lined up
                        // with the column the scroll view leaves for it.
                        if showsRail {
                            columns(rail: true) {
                                ProjectSettingsRail(jump: jump)
                            } content: {
                                Color.clear.frame(height: 1).allowsHitTesting(false)
                            }
                            .padding(.top, Space.xl)
                        }
                    }
                }
                .onChange(of: geo.size.height, initial: true) { _, height in spy.viewportHeight = height }
            }
            .environment(spy)
            .background(Color.btCanvas)
            .task(id: project.rootPath) {
                origin = await Git.originURL(model.executor, root: project.rootPath) ?? ""
            }
            .onChange(of: saved(project)) {
                // Rules, servers and links still loading as the page opens aren't saves.
                if Date.now.timeIntervalSince(openedAt) > 1 { savedTick += 1 }
            }
        } else {
            EmptyStateView(symbol: "folder.badge.questionmark", title: "This project no longer exists")
        }
    }

    /// The rail's column (or none) and the page's, centred together.
    private func columns<Leading: View, Content: View>(rail: Bool, @ViewBuilder leading: () -> Leading,
                                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: ProjectPage.railGap) {
            if rail { leading().frame(width: ProjectPage.railWidth, alignment: .topLeading) }
            content().frame(maxWidth: ProjectPage.width, alignment: .leading)
        }
        .frame(maxWidth: (rail ? ProjectPage.railWidth + ProjectPage.railGap : 0) + ProjectPage.width)
        .padding(.horizontal, Space.xxl)
        .frame(maxWidth: .infinity)
    }

    /// Everything this page stores for the project. Reordering the sidebar
    /// isn't a save here, and nor is a server's tool list being refreshed.
    private func saved(_ project: Project) -> SavedState {
        var p = project
        p.sortOrder = 0
        let servers = model.toolServers(for: project.id).map { server in
            var s = server
            s.tools = []
            s.listedAt = nil
            s.listError = nil
            return s
        }
        let links = model.projectIssueTrackers(project.id).linked.map { "\($0.tracker.pluginId)=\($0.link.title)" }
        return SavedState(project: p, rules: model.permissionRules(for: project.id), servers: servers, links: links)
    }

    private struct SavedState: Equatable {
        let project: Project
        let rules: [PermissionRule]
        let servers: [ProjectToolServer]
        let links: [String]
    }
}

// MARK: - Shared pieces

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
            .accessibilityLabel(help)
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

/// The project itself: its icon and name (both changed in place), its
/// remote, and the tracker projects it links to.
private struct ProjectHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let origin: String?
    let owner: String?
    let savedTick: Int
    /// Set when the window is too narrow for the rail.
    let jump: ((ProjectSettingsSection) -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            ProjectIconButton(project: project, owner: owner, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                NameField(project: project)
                HStack(spacing: Space.md) {
                    remote
                    // The tracker projects it links to (ABS-143).
                    ForEach(model.projectIssueTrackers(project.id).linked) { item in
                        HStack(spacing: 5) {
                            TrackerGlyph(pluginId: item.tracker.pluginId, size: 12)
                            Text(item.link.title).font(.btCallout).lineLimit(1)
                        }
                        .foregroundStyle(Color.btTextSecondary)
                        .help("Linked to \(item.link.title) in \(item.tracker.title)")
                    }
                }
                .frame(minHeight: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: Space.xs) {
                if let jump { ProjectSettingsJumpMenu(jump: jump).padding(.trailing, -Chip.inset) }
                SavedBadge(tick: savedTick)
            }
        }
    }

    @ViewBuilder
    private var remote: some View {
        switch origin {
        case nil:
            Text("github.com/owner/repository").font(BTFont.mono(12)).redacted(reason: .placeholder)
        case ""?:
            Text("No remote").font(.btCallout).foregroundStyle(Color.btTextTertiary)
        case let url?:
            HStack(spacing: Space.xxs) {
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

/// The project's name as the page's title, edited where it stands.
private struct NameField: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var name: String
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(project: Project) {
        self.project = project
        _name = State(initialValue: project.name)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        TextField("Name", text: $name, prompt: Text("Project name"))
            .textFieldStyle(.plain)
            .font(.btTitle)
            // At rest the name is drawn by the label over it, which can end
            // in "…"; the field's own text shows only while it's edited.
            .foregroundStyle(focused ? Color.btText : .clear)
            .overlay(alignment: .leading) {
                if !focused {
                    Text(name)
                        .font(.btTitle)
                        .foregroundStyle(Color.btText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($focused)
            .onSubmit { focused = false }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(focused ? Color.btField : hovering ? Color.btHover : .clear, in: shape)
            .overlay(shape.strokeBorder(focused ? Color.btFieldBorderFocused : .clear, lineWidth: 1))
            .padding(.leading, -6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.12), value: focused)
            .help(name.isEmpty ? "Rename the project" : "Rename “\(name)”")
            .accessibilityLabel("Project name")
            .autosave($name, stored: project.name, normalize: trimmed) { model.renameProject(project.id, to: $0) }
            // A project keeps a name: leaving it empty puts the old one back.
            .onChange(of: focused) { _, now in
                if !now, trimmed(name).isEmpty { name = project.name }
            }
    }
}

// MARK: - New chats

/// What a new chat in this project starts with; the Launcher fills these in.
private struct NewChatSection: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        PageSection(section: .chats) {
            SettingsCard {
                CardRow(title: "Agent", warning: missingAgent) {
                    SentenceMenu(title: ProviderRegistry.name(project.defaultProviderId), logo: project.defaultProviderId) {
                        Picker("Agent", selection: Binding(get: { project.defaultProviderId },
                                                           set: { id in model.updateProject(project.id) { $0.defaultProviderId = id } })) {
                            ForEach(model.pickableAgents(keeping: project.defaultProviderId), id: \.id) { p in
                                Label {
                                    Text(p.name)
                                } icon: {
                                    if let icon = ProviderRegistry.menuImage(p.id) { Image(nsImage: icon) }
                                }
                                .tag(p.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .padding(.trailing, -Chip.inset)
                }
                CardRow(title: "Runs on", detail: "The Mac its new chats start on. One that isn't connected falls back to this Mac.") {
                    DeviceMenu(project: project).padding(.trailing, -Chip.inset)
                }
                if !model.profiles.isEmpty {
                    CardRow(title: "Profiles", detail: "The saved setups the New Chat window offers here.",
                            info: "Profiles are saved setups of agent, model, permissions and instructions. Manage them in Settings › Profiles.") {
                        ProfilesChip(project: project).padding(.trailing, -Chip.inset)
                    }
                }
                CardRow(title: "Code history",
                        detail: project.agentHistoryEnabled ? "Agents can look up what earlier chats here decided."
                                                            : "Agents get no history of earlier chats here.",
                        info: "Before changing code, an agent can look up what earlier chats in this project were asked, corrected and decided about it, and is told to follow those decisions.") {
                    Toggle(isOn: Binding(get: { project.agentHistoryEnabled },
                                         set: { on in model.updateProject(project.id) { $0.agentHistory = on } })) { EmptyView() }
                        .toggleStyle(QuietSwitchStyle())
                        .accessibilityLabel("Give agents the history of the code they change")
                }
            }
        }
    }

    private var missingAgent: String? {
        guard model.providerStatus[project.defaultProviderId]?.available == false else { return nil }
        return "\(ProviderRegistry.name(project.defaultProviderId)) wasn't found on this Mac. Set its path in Settings › Agents."
    }
}

/// Where the project's new chats run: this Mac, or a paired Mac. The
/// Launcher pre-selects it; a Mac that isn't connected falls back to
/// this one there, with a note saying so.
private struct DeviceMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project

    private var name: String {
        guard let id = project.defaultDeviceId else { return "This Mac" }
        return model.remote.paired.first { $0.id == id }?.peer.name ?? "A paired Mac"
    }

    var body: some View {
        SentenceMenu(title: name) {
            Picker("Device", selection: Binding(get: { project.defaultDeviceId },
                                                set: { id in model.updateProject(project.id) { $0.defaultDeviceId = id } })) {
                Label("This Mac", systemImage: "laptopcomputer").tag(String?.none)
                ForEach(model.remote.paired) { device in
                    Label(device.peer.name, systemImage: "desktopcomputer").tag(Optional(device.id))
                }
                if let id = project.defaultDeviceId, !model.remote.paired.contains(where: { $0.id == id }) {
                    Label("A Mac that isn't paired anymore", systemImage: "desktopcomputer").tag(Optional(id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help("Where this project's new chats run")
    }
}

/// "3 of 4 offered", opening the list of profiles to turn on and off.
private struct ProfilesChip: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let offered = model.profiles.filter { project.profileIds?.contains($0.id) ?? true }.count
        let title = offered == model.profiles.count ? "All offered" : "\(offered) of \(model.profiles.count) offered"
        SentencePopover(title: title) { _ in
            PopoverList {
                ForEach(model.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { project.profileIds?.contains(profile.id) ?? true },
                        set: { on in offer(profile.id, on) }))
                }
            }
        }
    }

    /// Offer a profile in this project, or stop offering it. Every
    /// profile on is kept as no choice at all, so a profile added later
    /// shows here too.
    private func offer(_ profileId: String, _ on: Bool) {
        let all = model.profiles.map(\.id)
        model.updateProject(project.id) { p in
            var picked = Set(p.profileIds ?? all)
            if on { picked.insert(profileId) } else { picked.remove(profileId) }
            p.profileIds = picked == Set(all) ? nil : all.filter { picked.contains($0) }
        }
    }
}

// MARK: - Permissions

/// The policy new chats start with, and the answers remembered for this
/// project. Each rule answers matching requests in every chat; deleting
/// one brings the card back.
private struct PermissionsSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    /// The rule being edited, or a new one being written.
    @State private var editing: PermissionRule?
    @State private var adding = false

    var body: some View {
        PageSection(section: .permissions) {
            SettingsCard {
                CardRow(title: "New chats start with", detail: project.defaultPermissionPolicy.detail) {
                    SentenceMenu(title: project.defaultPermissionPolicy.title) {
                        ForEach(PermissionPolicy.autonomyCases, id: \.self) { p in
                            Toggle(isOn: Binding(get: { project.defaultPermissionPolicy == p },
                                                 set: { _ in model.updateProject(project.id) { $0.defaultPermissionPolicy = p } })) {
                                Text(p.title)
                                Text(p.detail)
                            }
                        }
                    }
                    .padding(.trailing, -Chip.inset)
                }
            }
            CardGroup(title: "Remembered rules",
                      info: "A request matching a rule is answered for you, and its row in the chat names the rule. A deny rule beats an allow rule.") {
                SettingsCard {
                    let rules = model.permissionRules(for: project.id)
                    if rules.isEmpty {
                        CardEmptyRow("No rules yet. When an agent asks for permission, choose “Always Allow in This Project…” or “Always Deny in This Project…” from its menu.")
                    }
                    ForEach(rules) { rule in
                        CardItemRow(title: rule.pattern, monoTitle: true, meta: detail(rule)) {
                            Image(systemName: rule.decision == .allow ? "checkmark.circle" : "nosign")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(rule.decision == .allow ? Color.btAdded : Color.btRemoved)
                                .frame(width: 16)
                                .accessibilityLabel(rule.decision.title)
                        } actions: {
                            Button("Edit…") { editing = rule }
                            Button("Delete", role: .destructive) { model.deletePermissionRule(rule) }
                        }
                    }
                    CardAddRow(title: "Add a Rule…") { adding = true }
                }
            }
        }
        .sheet(isPresented: $adding) {
            PermissionRuleSheet(projectId: project.id, seed: PermissionRuleSeed())
        }
        .sheet(item: $editing) { rule in
            PermissionRuleSheet(projectId: project.id, existing: rule, seed: PermissionRuleSeed(rule: rule))
        }
    }

    private func detail(_ rule: PermissionRule) -> String {
        var text = "\(rule.decision.title) · \(rule.kind.title)"
        if let expiresAt = rule.expiresAt {
            text += rule.isExpired() ? " · expired \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
                                      : " · expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }
}

// MARK: - Git

/// The repository on this Mac, and how each chat's worktree and branch are
/// made: where it starts, its prefix, its folder, what it checks out, and
/// how chats and branches are named.
private struct GitSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var baseRef: String
    @State private var sparse: String
    @State private var instructions: String
    @State private var moving = false
    @State private var locationError: String?

    /// The tail a chosen folder gets, like the global default's.
    static let folderTail = "/{repo}-{hash}/{slug}"

    init(project: Project) {
        self.project = project
        _baseRef = State(initialValue: project.defaultBaseRef)
        _sparse = State(initialValue: project.sparseCheckout.joined(separator: "\n"))
        _instructions = State(initialValue: project.namingInstructions ?? "")
    }

    private var home: String { model.executor.homeDirectory }

    var body: some View {
        PageSection(section: .git) {
            SettingsCard {
                CardRow(title: "Repository", detail: "Its folder on this Mac. Choose the new one if you moved it.", error: locationError) {
                    HStack(spacing: Space.xs) {
                        PathText(text: AppModel.abbreviated(project.rootPath, home: home))
                        if moving { ProgressView().controlSize(.mini) }
                        ValueButton(symbol: "folder", help: "Choose the repository's folder…", action: relocate)
                            .disabled(moving)
                    }
                }
                CardRow(title: "Branch from", detail: "The branch or commit each new chat's worktree starts from.") {
                    BTTextField("Branch from", text: $baseRef, prompt: "HEAD", mono: true)
                        .frame(width: 200)
                        .autosave($baseRef, stored: project.defaultBaseRef, normalize: trimmed) { value in
                            guard let ref = Project.baseRef(typed: value) else { return }
                            model.updateProject(project.id) { $0.defaultBaseRef = ref }
                        }
                }
                BranchPrefixRow(project: project)
                CardRow(title: "Worktrees",
                        detail: project.worktreeTemplate == nil ? "Where new worktrees go: the global default."
                                                                : "Where new worktrees go: this project's own folder.") {
                    HStack(spacing: Space.xs) {
                        PathText(text: displayed(project.worktreeTemplate ?? model.worktreeTemplate),
                                 quiet: project.worktreeTemplate == nil)
                        ValueButton(symbol: "folder", help: "Choose a folder for this project's worktrees…", action: chooseWorktreeFolder)
                        if project.worktreeTemplate != nil {
                            ValueButton(symbol: "arrow.uturn.backward", help: "Use the global default") {
                                model.updateProject(project.id) { $0.worktreeTemplate = nil }
                            }
                        }
                    }
                }
            }
            SettingsCard {
                CardStackedRow(title: "Sparse checkout",
                               detail: "Folders new worktrees check out, one per line. Empty checks out everything.",
                               info: "Paths are relative to the repository root. Files at the root are always included.") {
                    GrowingEditor(text: $sparse, placeholder: "apps/web\npackages/ui", mono: true, minHeight: 76)
                        .autosave($sparse, stored: project.sparseCheckout.joined(separator: "\n"), delay: .milliseconds(800),
                                  normalize: { SparseCheckout.parse($0).joined(separator: "\n") }) { value in
                            model.updateProject(project.id) { $0.sparseCheckout = SparseCheckout.parse(value) }
                        }
                }
            }
            SettingsCard {
                CardStackedRow(title: "Naming instructions",
                               detail: "Guides chat titles and branch names for every agent.",
                               info: "Commit messages come from your agent's own instructions (AGENTS.md or CLAUDE.md) and from the chat title.") {
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

/// The global prefix, none, or one of this project's own.
private struct BranchPrefixRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var customPrefix: String
    /// Custom stays chosen while its field is being edited, even empty.
    @State private var choosingCustom = false

    init(project: Project) {
        self.project = project
        _customPrefix = State(initialValue: project.branchPrefix ?? "")
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
        CardRow(title: "Branch prefix", detail: "Put in front of each new branch in this project.",
                warning: mode == .custom ? BranchPrefixCheck.warning(customPrefix) : nil) {
            HStack(spacing: Space.sm) {
                if mode == .custom {
                    BTTextField("Prefix", text: $customPrefix, prompt: "e.g. wes/", mono: true)
                        .frame(width: 140)
                        // The draft may be stale: the prefix can change while the
                        // field is hidden (another device, the Launcher). Without
                        // this, the empty draft would be saved over it.
                        .onAppear { if !choosingCustom { customPrefix = project.branchPrefix ?? "" } }
                        .autosave($customPrefix, stored: project.branchPrefix ?? "",
                                  normalize: { $0.trimmingCharacters(in: .whitespaces) }) { value in
                            model.updateProject(project.id) { $0.branchPrefix = value.trimmingCharacters(in: .whitespaces) }
                        }
                }
                SentenceMenu(title: title) {
                    Picker("Branch prefix", selection: Binding(get: { mode }, set: { choose($0) })) {
                        Text("Use Global Default (\(model.branchPrefix.isEmpty ? "none" : model.branchPrefix))").tag(Mode.global)
                        Text("No Prefix").tag(Mode.none)
                        Text("Custom…").tag(Mode.custom)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .padding(.trailing, -Chip.inset)
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

// MARK: - Agent context

/// What the project's agents get beside their own setup: skills, MCP
/// servers, plugin tools and the issue tracker.
private struct ContextSection: View {
    let project: Project

    var body: some View {
        PageSection(section: .context) {
            SkillsGroup(project: project)
            ToolsGroup(project: project)
            PluginToolsGroup(project: project)
            IssueTrackerGroup(project: project)
        }
    }
}

/// The library skills this project's chats get (ABS-122), chosen from
/// Settings › Skills, and the ones its own files hold.
private struct SkillsGroup: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        CardGroup(title: "Skills", info: info) {
            SettingsCard {
                let sources = model.skillSources.map { ($0, model.skills(in: $0.id)) }.filter { !$0.1.isEmpty }
                if sources.isEmpty {
                    CardEmptyRow("The skill library is empty. Add a folder or a GitHub repository of skills in Settings › Skills.")
                }
                ForEach(sources, id: \.0.id) { source, skills in
                    CardRow(title: source.title,
                            detail: source.kind == .github ? "GitHub, pinned to \(source.commit.map { String($0.prefix(7)) } ?? "?")"
                                                           : "A folder on this Mac") {
                        SkillsChip(project: project, skills: skills).padding(.trailing, -Chip.inset)
                    }
                }
                let own = model.projectSkills(project.id)
                if !own.isEmpty {
                    CardRow(title: "In this project's files", detail: own.map(\.name).joined(separator: ", "),
                            info: "Kept in the project's own files. Agents that read their folder already use them.")
                }
            }
        }
        .onAppear { model.reloadSkills() }
    }

    /// Who gets them, and who can't.
    private var info: String {
        let unable = ProviderRegistry.all.filter { $0.skillDelivery == nil }.map(\.name)
        let base = "Every chat in this project gets the skills chosen here when its agent starts; a profile can add more. Removing one leaves it out of chats that start after."
        return unable.isEmpty ? base : base + " \(unable.joined(separator: ", ")) can't take skills, so its chats run without them."
    }
}

/// "2 of 9 on", opening one source's skills to turn on and off.
private struct SkillsChip: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let skills: [LibrarySkill]

    var body: some View {
        let on = skills.filter { project.assignedSkills.contains($0.id) }.count
        let title = on == 0 ? "None on" : on == skills.count ? "All \(on) on" : "\(on) of \(skills.count) on"
        SentencePopover(title: title, quiet: on == 0) { _ in
            PopoverList {
                ForEach(skills) { skill in
                    Toggle(skill.name, isOn: Binding(
                        get: { project.assignedSkills.contains(skill.id) },
                        set: { assigned in model.setSkill(skill.id, assigned: assigned, projectId: project.id) }))
                        .help(skill.description ?? skill.name)
                }
            }
        }
    }
}

/// Tools plugins give this project's agents, each on, asking first, or off.
private struct PluginToolsGroup: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let tools = model.pluginTools(in: project)
        if !tools.isEmpty {
            CardGroup(title: "Plugin tools",
                      info: "Tools your plugins give this project's agents. Ask first shows each call in the chat for you to allow; Off leaves it out from the agent's next turn.") {
                SettingsCard {
                    ForEach(tools, id: \.key) { tool in
                        CardRow(title: tool.label) {
                            SentenceMenu(title: tool.mode.title) {
                                ForEach(PluginToolMode.allCases, id: \.self) { mode in
                                    Toggle(isOn: Binding(get: { tool.mode == mode },
                                                         set: { _ in model.setPluginToolMode(project.id, tool, mode) })) {
                                        Text(mode.title)
                                        Text(mode.detail)
                                    }
                                }
                            }
                            .padding(.trailing, -Chip.inset)
                        }
                        .help(tool.tool.description)
                    }
                }
            }
        }
    }
}

// MARK: - Scripts

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
        case .setup: "Runs in each new chat's worktree, fresh from origin, before its agent starts. The chat shows its output while it runs."
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
        PageSection(section: .scripts) {
            SettingsCard {
                HStack(spacing: Space.sm) {
                    PageTabs(selection: $tab, items: ScriptKind.allCases.map { .init(value: $0, title: $0.title) })
                    Spacer(minLength: Space.sm)
                    Button("Import…", action: importFile)
                        .buttonStyle(.bt(.ghost, size: .small))
                        .help("Load a script file into the \(tab.title.lowercased()) script")
                }
                .padding(.horizontal, ProjectPage.rowInset)
                .padding(.vertical, Space.sm)
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
        .padding(.horizontal, ProjectPage.rowInset)
        .padding(.vertical, Space.md)
    }
}

// MARK: - Danger zone

private struct DangerSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var confirming = false

    var body: some View {
        PageSection(section: .danger) {
            SettingsCard(tone: .danger) {
                CardRow(title: "Delete project",
                        detail: "Removes \(project.name) and its chats from Abstract. The repository and its worktrees stay on disk.") {
                    Button("Delete Project…") { confirming = true }
                        .buttonStyle(.bt(.danger, size: .small))
                }
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
