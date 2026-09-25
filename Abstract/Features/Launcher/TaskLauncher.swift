import AppKit
import SwiftUI
import AbstractCore

/// Describe a task, pick where, with which agent and model, start. Used on
/// the New screen and in the New Chat sheet so starting work feels the same.
struct TaskLauncher: View {
    @Environment(AppModel.self) private var model
    var initialProjectId: String?
    var autofocus = true
    /// Inside a sheet the sheet is the container; draw no field frame of our own.
    var embedded = false
    var onStarted: () -> Void = {}

    @State private var prompt = ""
    @State private var attachments: [PromptAttachment] = []
    /// The paired Mac the chat runs on; nil is this one. Its project,
    /// worktree and files stay on that Mac; you work from here.
    @State private var device: String?
    @State private var projectId: String?
    @State private var providerId = "claude"
    @State private var modelId: String?
    @State private var effort: String?
    @State private var baseRef = "HEAD"
    /// nil: a new worktree from `baseRef`. Otherwise the chat starts in this one.
    @State private var worktree: WorktreeInfo?
    @State private var worktrees: [WorktreeInfo] = []
    @State private var policy: PermissionPolicy = .ask
    @State private var starting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Describe the task. Be as specific as you would with a colleague.", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(BTFont.ui(14))
                .lineSpacing(3)
                .lineLimit(3...14)
                .focused($focused)
                .padding(.horizontal, embedded ? Field.inset : Space.lg)
                .padding(.top, embedded ? Field.inset : 14)
                .padding(.bottom, embedded ? Field.inset : Space.md)
                // In the sheet the prompt is the field; on the New screen the whole box is.
                .modifier(OptionalFieldChrome(active: embedded, focused: focused))
                .padding(.bottom, embedded ? Space.md : 0)
                .returnBreaksLine(commandReturn: start)

            if !attachments.isEmpty {
                AttachmentTray(attachments: $attachments)
                    .padding(.horizontal, embedded ? 0 : Space.lg)
                    .padding(.bottom, Space.md)
            }

            HStack(alignment: .bottom, spacing: Space.md) {
                // The choices wrap onto another line rather than push the sheet
                // wider; space alone separates them.
                FlowRow(spacing: Space.xs, lineSpacing: 4) {
                    AttachUploadButton(attachments: $attachments)
                    if !onlineDevices.isEmpty { DeviceMenu(device: deviceBinding, devices: onlineDevices) }
                    CompactMenu(title: model.project(projectId)?.name ?? "Project") {
                        Picker("Project", selection: projectBinding) {
                            ForEach(deviceProjects) { p in Text(p.name).tag(Optional(p.id)) }
                        }
                        .pickerStyle(.inline)
                        if device == nil {
                            Divider()
                            Button("Add Project…") { model.isAddingProject = true }
                        }
                    }
                    CompactMenu(title: ProviderRegistry.name(providerId), logo: providerId) {
                        Picker("Agent", selection: providerBinding) {
                            ForEach(model.pickableAgents(on: device, keeping: providerId), id: \.id) { p in
                                Label {
                                    Text(p.name)
                                } icon: {
                                    if let icon = ProviderRegistry.menuImage(p.id) { Image(nsImage: icon) }
                                }
                                .tag(p.id)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    ModelMenu(providerId: providerId, modelId: $modelId, device: device)
                    if !model.efforts(providerId: providerId, model: modelId, on: device).levels.isEmpty {
                        EffortMenu(providerId: providerId, modelId: modelId, effort: $effort, device: device)
                    }
                    CompactMenu(title: policy.title) {
                        Picker("Permissions", selection: $policy) {
                            ForEach(PermissionPolicy.allCases, id: \.self) { p in Text(p.title).tag(p) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Text(ProviderRegistry.provider(providerId)?.permissionDetail(policy) ?? policy.detail)
                    }
                    HStack(spacing: 4) {
                        WorktreeMenu(worktree: $worktree, worktrees: worktrees)
                        if worktree == nil { BaseRefField(baseRef: $baseRef) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AttachmentButtons(repoRoot: model.project(projectId)?.rootPath, projectId: projectId, attachments: $attachments)
                Button(action: start) {
                    HStack(spacing: 6) {
                        if starting { ProgressView().controlSize(.small).tint(Color.btOnAccent) }
                        Text(starting ? "Starting" : "Start")
                        if !starting { Text("⌘↩").font(.btCallout).opacity(0.7) }
                    }
                }
                .buttonStyle(.btPrimary)
                .disabled(!canStart)
                .fixedSize()
            }
            .padding(.horizontal, embedded ? 0 : Space.md)
            .padding(.bottom, Space.md)

            if let worktree, let holder = model.chat(usingWorktree: worktree.path) {
                Text("“\(holder.name)” works here now. Starting stops its agent and this chat takes the worktree.")
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextSecondary)
                    .padding(.horizontal, embedded ? 0 : Space.lg)
                    .padding(.bottom, Space.md)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.btCallout)
                    .foregroundStyle(Color.btRemoved)
                    .padding(.horizontal, embedded ? 0 : Space.lg)
                    .padding(.bottom, Space.md)
                    .textSelection(.enabled)
            } else if device == nil, let status = model.providerStatus[providerId], !status.available {
                Label("\(ProviderRegistry.name(providerId)) wasn't found on this Mac. Set its path in Settings › Agents.", systemImage: "exclamationmark.triangle")
                    .font(.btCallout)
                    .foregroundStyle(Color.btWarning)
                    .padding(.horizontal, embedded ? 0 : Space.lg)
                    .padding(.bottom, Space.md)
            }
        }
        .modifier(OptionalFieldChrome(active: !embedded, focused: focused))
        .attachmentInput($attachments, focused: focused)
        .onAppear {
            let firstRemoteProject = onlineDevices.compactMap { device in
                model.remote.links[device.id]?.snapshot?.projects.first { $0.archivedAt == nil }?.id
            }.first
            let initial = initialProjectId ?? model.selectedSession?.projectId ?? model.projects.first?.id ?? firstRemoteProject
            // A project on a paired Mac starts its chat there.
            device = initial.flatMap { id in model.projects.contains { $0.id == id } ? nil : model.remote.device(ofProject: id) }
            select(initial)
            if autofocus { focused = true }
        }
        .onChange(of: model.focusLauncherToken) { focused = true }
        .task(id: projectId) {
            let found = await model.reusableWorktrees(projectId: projectId)
            worktrees = found
            // "New Chat Here" asked for one; otherwise keep a choice that still exists.
            if let wanted = model.newChatWorktree {
                model.newChatWorktree = nil
                worktree = found.first { AppModel.canonical($0.path) == AppModel.canonical(wanted) }
            } else if let current = worktree, !found.contains(current) {
                worktree = nil
            }
        }
        .onChange(of: modelId) {
            let levels = model.efforts(providerId: providerId, model: modelId, on: device).levels
            effort = effort.flatMap { levels.contains($0) ? $0 : nil }
        }
    }

    /// Paired Macs connected now, with their names.
    private var onlineDevices: [(id: String, name: String)] {
        model.remote.links.values.filter { $0.state == .online && $0.snapshot != nil }
            .map { ($0.device.id, $0.device.peer.name) }.sorted { $0.name < $1.name }
    }

    private var deviceProjects: [Project] {
        guard let device else { return model.projects }
        return (model.remote.links[device]?.snapshot?.projects ?? []).filter { $0.archivedAt == nil }
    }

    /// The agents the chosen Mac can run.
    private var deviceProviders: [any ProviderDefinition] {
        guard let device, let available = model.remote.links[device]?.snapshot?.providers else { return ProviderRegistry.all }
        return ProviderRegistry.all.filter { available.contains($0.id) }
    }

    private var deviceBinding: Binding<String?> {
        Binding(get: { device }, set: { new in
            guard new != device else { return }
            device = new
            worktree = nil
            modelId = nil
            effort = nil
            select(deviceProjects.first?.id)
        })
    }

    private var projectBinding: Binding<String?> {
        Binding(get: { projectId }, set: { select($0) })
    }

    private var providerBinding: Binding<String> {
        Binding(get: { providerId }, set: { new in
            if new != providerId { modelId = nil; effort = nil }
            providerId = new
        })
    }

    private var canStart: Bool {
        !starting && projectId != nil && (device == nil || deviceProviders.contains { $0.id == providerId })
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func select(_ id: String?) {
        if id != projectId { worktree = nil }
        projectId = id
        guard let p = model.project(id) else { return }
        let selectedProvider = device == nil ? p.defaultProviderId
            : (deviceProviders.first { $0.id == p.defaultProviderId } ?? deviceProviders.first)?.id ?? p.defaultProviderId
        if selectedProvider != providerId { modelId = nil; effort = nil }
        providerId = selectedProvider
        baseRef = p.defaultBaseRef
        policy = p.defaultPermissionPolicy
    }

    private func start() {
        guard canStart, let projectId else { return }
        starting = true
        error = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if let device {
                    let id = try await model.remote.startChat(on: device, RemoteStart(
                        projectId: projectId, providerId: providerId, prompt: text, attachments: attachments, baseRef: baseRef,
                        policy: policy, model: modelId, effort: effort, worktree: worktree?.path))
                    model.open(id, newTab: true)
                } else {
                    try await model.startChat(projectId: projectId, providerId: providerId, prompt: text, attachments: attachments,
                                              baseRef: baseRef, policy: policy, model: modelId, effort: effort, existing: worktree)
                }
                prompt = ""
                attachments = []
                onStarted()
            } catch {
                self.error = error.localizedDescription
            }
            starting = false
        }
    }
}

/// Which Mac the chat runs on: this one, or a paired Mac that's connected.
private struct DeviceMenu: View {
    @Binding var device: String?
    let devices: [(id: String, name: String)]

    var body: some View {
        CompactMenu(title: devices.first { $0.id == device }?.name ?? "This Mac") {
            Picker("Runs on", selection: $device) {
                Label("This Mac", systemImage: "laptopcomputer").tag(String?.none)
                ForEach(devices, id: \.id) { d in Label(d.name, systemImage: "desktopcomputer").tag(Optional(d.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            Text("The chat runs where its project is; you work on it from here.")
        }
        .help("Which Mac the chat runs on")
    }
}

/// Where the chat works: a new worktree, or one that already exists
/// (its branch, and which chat holds it now).
private struct WorktreeMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var worktree: WorktreeInfo?
    let worktrees: [WorktreeInfo]

    var body: some View {
        CompactMenu(title: worktree.map(label) ?? "New worktree") {
            Picker("Worktree", selection: $worktree) {
                Text("New worktree").tag(WorktreeInfo?.none)
                if !worktrees.isEmpty {
                    Divider()
                    ForEach(worktrees) { w in
                        if let holder = model.chat(usingWorktree: w.path) {
                            Text("\(label(w)) — used by “\(holder.name)”").tag(Optional(w))
                        } else {
                            Text(label(w)).tag(Optional(w))
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        }
    }

    /// The branch, without the prefix every Abstract branch shares.
    private func label(_ w: WorktreeInfo) -> String {
        guard let branch = w.branch else { return (w.path as NSString).lastPathComponent }
        let prefix = model.branchPrefix
        return !prefix.isEmpty && branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
    }
}


/// A dropdown drawn as a line of text with a small chevron. No fill, no
/// border, a faint wash on hover; the menu itself is the system's own.
struct CompactMenu<Content: View>: View {
    let title: String
    var logo: String? = nil
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                if let logo { ProviderLogo(providerId: logo, size: 12) }
                Text(title).font(.btCallout.weight(.medium)).foregroundStyle(Color.btTextSecondary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Color.btTextTertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(hovering ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// Default model, the account's models, pinned versions, or any name typed
/// in. Rows are checkmark items whose second line (the NSMenu subtitle) says
/// what the model is.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let providerId: String
    @Binding var modelId: String?
    /// The paired Mac the chat runs on; nil is this one.
    var device: String? = nil
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if typing {
            TextField("model name", text: $draft)
                .textFieldStyle(.plain)
                .font(.btMono)
                .frame(width: 130)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onSubmit(commit)
                .onExitCommand { typing = false }
                .onChange(of: fieldFocused) { _, f in if !f { commit() } }
                .padding(.horizontal, 8)
                .frame(height: Field.compactHeight)
                .btFieldChrome(focused: fieldFocused)
        } else {
            let catalog = model.models(for: providerId, on: device)
            CompactMenu(title: label(catalog)) {
                Section("Model") {
                    row(model.defaultModelName(for: providerId, on: device).map { "Default (\($0))" } ?? "Default", detail: nil, id: nil)
                    ForEach(catalog.models) { row($0) }
                    if let custom = modelId, catalog.option(custom) == nil { row(custom, detail: nil, id: custom) }
                }
                if !catalog.versions.isEmpty {
                    Section("Specific versions") {
                        ForEach(catalog.versions) { row($0) }
                    }
                }
                Divider()
                Button("Other Model…") { draft = modelId ?? ""; typing = true }
            }
        }
    }

    private func label(_ catalog: ModelCatalog) -> String {
        guard let modelId else { return model.defaultModelName(for: providerId, on: device) ?? "Default model" }
        return catalog.option(modelId)?.label ?? modelId
    }

    private func row(_ option: ModelOption) -> some View {
        let detail = [option.note, option.detail].compactMap { $0 }.joined(separator: " · ")
        return row(option.label, detail: detail.isEmpty ? nil : detail, id: option.id)
    }

    /// A Toggle rather than a Picker option: only a Toggle or Button label
    /// with two Texts becomes a menu item with a subtitle.
    private func row(_ title: String, detail: String?, id: String?) -> some View {
        Toggle(isOn: Binding(get: { modelId == id }, set: { _ in modelId = id })) {
            Text(title)
            if let detail { Text(detail) }
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        modelId = name.isEmpty ? nil : name
        typing = false
    }
}

/// Reasoning effort for the chosen model. Draws nothing for a model that
/// takes none.
struct EffortMenu: View {
    @Environment(AppModel.self) private var model
    let providerId: String
    let modelId: String?
    @Binding var effort: String?
    var device: String? = nil

    var body: some View {
        let efforts = model.efforts(providerId: providerId, model: modelId, on: device)
        if !efforts.levels.isEmpty {
            CompactMenu(title: (effort ?? efforts.defaultLevel).map(ModelOption.effortTitle) ?? "Default effort") {
                Picker("Effort", selection: $effort) {
                    Text(efforts.defaultLevel.map { "Default (\(ModelOption.effortTitle($0)))" } ?? "Default").tag(String?.none)
                    ForEach(efforts.levels, id: \.self) { Text(ModelOption.effortTitle($0)).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            }
        }
    }
}

private struct BaseRefField: View {
    @Binding var baseRef: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("from").font(.btCallout).foregroundStyle(Color.btTextTertiary).fixedSize()
            TextField("HEAD", text: $baseRef)
                .textFieldStyle(.plain)
                .font(.btMono)
                .foregroundStyle(Color.btTextSecondary)
                .focused($focused)
                .frame(width: max(36, CGFloat(baseRef.count) * 7.4))
                .padding(.horizontal, 8)
                .frame(height: Field.compactHeight)
                .btFieldChrome(focused: focused)
        }
        .padding(.leading, 6)
        .help("Branch the new worktree from this ref")
    }
}

/// The shared input chrome, when `active`.
private struct OptionalFieldChrome: ViewModifier {
    let active: Bool
    let focused: Bool
    func body(content: Content) -> some View {
        if active { content.btFieldChrome(focused: focused) } else { content }
    }
}

extension ProviderRegistry {
    /// The provider's mark at menu size. Menus draw images at their natural
    /// size, and the vector assets are 24pt, which made menu rows too tall.
    @MainActor static func menuImage(_ id: String, size: CGFloat = 14) -> NSImage? {
        guard let asset = provider(id)?.logoAsset, let source = NSImage(named: asset) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = asset == "ProviderOpenAI"
        return image
    }
}

struct NewChatSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialProjectId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Chat").font(.btHeadline)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.icon)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }
            if model.projects.isEmpty && model.project(initialProjectId) == nil && !model.remote.links.values.contains(where: {
                $0.state == .online && ($0.snapshot?.projects.contains { $0.archivedAt == nil } ?? false)
            }) {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Chats live inside a project. Add a git repository first.").font(.btBody).foregroundStyle(Color.btTextSecondary)
                    Button("Add Project…") { dismiss(); model.isAddingProject = true }.buttonStyle(.btPrimary)
                }
            } else {
                TaskLauncher(initialProjectId: initialProjectId, embedded: true, onStarted: { dismiss() })
            }
        }
        .padding(Space.xl)
        .frame(width: 760)
        .background(Color.btCanvas)
    }
}

/// Lays its children out left to right and wraps to a new line when the next
/// one doesn't fit, like words in a paragraph. Each child keeps its size.
struct FlowRow: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
