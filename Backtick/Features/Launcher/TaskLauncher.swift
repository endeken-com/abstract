import AppKit
import SwiftUI
import BacktickCore

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
    @State private var projectId: String?
    @State private var providerId = "claude"
    @State private var modelId: String?
    @State private var baseRef = "HEAD"
    @State private var policy: PermissionPolicy = .ask
    @State private var starting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Describe the task. Be as specific as you would with a colleague.", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineSpacing(3)
                .lineLimit(3...14)
                .focused($focused)
                .padding(.horizontal, embedded ? 0 : Space.lg)
                .padding(.top, embedded ? 0 : 14)
                .padding(.bottom, Space.md)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    start()
                    return .handled
                }

            if embedded { Hairline().padding(.bottom, Space.sm) }

            HStack(spacing: 0) {
                CompactMenu(title: model.project(projectId)?.name ?? "Project") {
                    Picker("Project", selection: projectBinding) {
                        ForEach(model.projects) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Add Project…") { model.isAddingProject = true }
                }
                Dot()
                CompactMenu(title: ProviderRegistry.name(providerId), logo: providerId) {
                    Picker("Agent", selection: providerBinding) {
                        ForEach(ProviderRegistry.all, id: \.id) { p in
                            Label {
                                Text(p.name + (model.providerStatus[p.id]?.available == false ? " — not installed" : ""))
                            } icon: {
                                if let icon = ProviderRegistry.menuImage(p.id) { Image(nsImage: icon) }
                            }
                            .tag(p.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Dot()
                ModelMenu(providerId: providerId, modelId: $modelId)
                Dot()
                CompactMenu(title: policy.title) {
                    Picker("Permissions", selection: $policy) {
                        ForEach(PermissionPolicy.allCases, id: \.self) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Text(policy.detail)
                }
                Dot()
                BaseRefField(baseRef: $baseRef)

                Spacer(minLength: Space.md)
                Button(action: start) {
                    HStack(spacing: 6) {
                        if starting { ProgressView().controlSize(.small).tint(.white) }
                        Text(starting ? "Starting" : "Start")
                        if !starting { Text("⌘↩").font(.btCallout).opacity(0.7) }
                    }
                }
                .buttonStyle(.btPrimary)
                .disabled(!canStart)
            }
            .padding(.horizontal, embedded ? 0 : Space.md)
            .padding(.bottom, Space.md)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.btCallout)
                    .foregroundStyle(Color.btRemoved)
                    .padding(.horizontal, embedded ? 0 : Space.lg)
                    .padding(.bottom, Space.md)
                    .textSelection(.enabled)
            } else if let status = model.providerStatus[providerId], !status.available {
                Label("\(ProviderRegistry.name(providerId)) wasn't found on this Mac. Set its path in Settings › Agents.", systemImage: "exclamationmark.triangle")
                    .font(.btCallout)
                    .foregroundStyle(Color.btWarning)
                    .padding(.horizontal, embedded ? 0 : Space.lg)
                    .padding(.bottom, Space.md)
            }
        }
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.btSurfaceRaised)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.btBorderStrong, lineWidth: focused ? 1 : 0.5)
            }
        }
        .animation(.snappy(duration: 0.15), value: focused)
        .onAppear {
            select(initialProjectId ?? model.selectedSession?.projectId ?? model.projects.first?.id)
            if autofocus { focused = true }
        }
        .onChange(of: model.focusLauncherToken) { focused = true }
    }

    private var projectBinding: Binding<String?> {
        Binding(get: { projectId }, set: { select($0) })
    }

    private var providerBinding: Binding<String> {
        Binding(get: { providerId }, set: { new in
            if new != providerId { modelId = nil }
            providerId = new
        })
    }

    private var canStart: Bool {
        !starting && projectId != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func select(_ id: String?) {
        projectId = id
        guard let p = model.project(id) else { return }
        if p.defaultProviderId != providerId { modelId = nil }
        providerId = p.defaultProviderId
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
                try await model.startChat(projectId: projectId, providerId: providerId, prompt: text, baseRef: baseRef,
                                          policy: policy, model: modelId)
                prompt = ""
                onStarted()
            } catch {
                self.error = error.localizedDescription
            }
            starting = false
        }
    }
}

/// A small middle dot between controls.
private struct Dot: View {
    var body: some View {
        Text("·").font(.btCallout).foregroundStyle(Color.btTextTertiary).padding(.horizontal, 1)
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

/// Default model, the agent's suggestions, or any name typed in.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let providerId: String
    @Binding var modelId: String?
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
                .padding(.horizontal, 6)
        } else {
            CompactMenu(title: label) {
                Picker("Model", selection: $modelId) {
                    Text(model.defaultModel(for: providerId).map { "Default (\($0))" } ?? "Default").tag(String?.none)
                    ForEach(ProviderRegistry.provider(providerId)?.models ?? []) { m in Text(m.label).tag(Optional(m.id)) }
                    if let custom = modelId, !(ProviderRegistry.provider(providerId)?.models.contains { $0.id == custom } ?? false) {
                        Text(custom).tag(Optional(custom))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Other Model…") { draft = modelId ?? ""; typing = true }
            }
        }
    }

    private var label: String {
        guard let modelId else { return model.defaultModel(for: providerId) ?? "Default model" }
        return ProviderRegistry.provider(providerId)?.models.first { $0.id == modelId }?.label ?? modelId
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        modelId = name.isEmpty ? nil : name
        typing = false
    }
}

private struct BaseRefField: View {
    @Binding var baseRef: String

    var body: some View {
        HStack(spacing: 4) {
            Text("from").font(.btCallout).foregroundStyle(Color.btTextTertiary).fixedSize()
            TextField("HEAD", text: $baseRef)
                .textFieldStyle(.plain)
                .font(.btMono)
                .foregroundStyle(Color.btTextSecondary)
                .frame(width: max(36, CGFloat(baseRef.count) * 7.4))
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .help("Branch the new worktree from this ref")
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
                    Text("The agent gets its own worktree and branch.").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.icon)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }
            if model.projects.isEmpty {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Chats live inside a project. Add a git repository first.").font(.btBody).foregroundStyle(Color.btTextSecondary)
                    Button("Add Project…") { dismiss(); model.isAddingProject = true }.buttonStyle(.btPrimary)
                }
            } else {
                TaskLauncher(initialProjectId: initialProjectId, embedded: true, onStarted: { dismiss() })
            }
        }
        .padding(Space.xl)
        .frame(width: 680)
        .background(Color.btCanvas)
    }
}
