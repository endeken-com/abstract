import SwiftUI
import AbstractCore

// MARK: - Tools (MCP)

/// The MCP servers this project's chats get (ABS-123): which agents get
/// each one, how to use it, and each tool's access. Agents get them for
/// the chat only; their global settings are never written.
struct ToolsSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var editing: ProjectToolServer?
    @State private var adding = false

    var body: some View {
        PageSection(title: "Tools (MCP)",
                    detail: "MCP servers this project's chats get, beside each agent's own. A change reaches a chat the next time its agent starts.") {
            let servers = model.toolServers(for: project.id)
            if servers.isEmpty {
                Text("No servers yet. Add one by pasting its URL, or the command that starts it.")
                    .font(.btBody).foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(servers) { server in
                HStack(alignment: .top, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(.btBody).foregroundStyle(Color.btText)
                        PathText(text: server.connection.summary)
                        Text(Self.summary(server)).font(.btCallout).foregroundStyle(Color.btTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.md)
                    Button("Edit") { editing = server }.buttonStyle(.bt(.ghost, size: .small))
                    Button("Delete") { model.deleteToolServer(server) }.buttonStyle(.bt(.ghost, size: .small))
                }
            }
            Button("Add a Server…") { adding = true }.buttonStyle(.bt(.ghost, size: .small))
        }
        .sheet(isPresented: $adding) { ToolServerSheet(projectId: project.id) }
        .sheet(item: $editing) { server in ToolServerSheet(projectId: project.id, existing: server) }
    }

    /// "Claude Code, Codex · 12 tools, 3 ask first, 1 off".
    static func summary(_ server: ProjectToolServer) -> String {
        let agents = server.agents.compactMap { id in
            ProviderRegistry.provider(id).flatMap { $0.toolServerSupport == .none ? nil : $0.name }
        }
        let who = agents.isEmpty ? "No agent gets it" : agents.joined(separator: ", ")
        if server.tools.isEmpty {
            return who + (server.listError == nil ? " · tools not listed yet" : " · its tools couldn't be listed")
        }
        let ask = server.tools.filter { server.access($0) == .askFirst }.count
        let off = server.tools.filter { server.access($0) == .off }.count
        var parts = ["\(server.tools.count) \(server.tools.count == 1 ? "tool" : "tools")"]
        if ask > 0 { parts.append("\(ask) ask first") }
        if off > 0 { parts.append("\(off) off") }
        return who + " · " + parts.joined(separator: ", ")
    }
}

/// Adding or editing one server.
struct ToolServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectId: String
    var existing: ProjectToolServer? = nil

    private enum Kind: Hashable { case url, command }

    @State private var kind: Kind
    @State private var address: String
    @State private var pairs: String
    @State private var name: String
    /// The name follows what's pasted until it's typed.
    @State private var nameTyped: Bool
    @State private var agents: Set<String>
    @State private var notes: String
    @State private var tools: [ProjectToolServer.Tool]
    @State private var access: [String: ToolAccess]
    @State private var listError: String?
    @State private var listedAt: Date?
    @State private var listing = false

    init(projectId: String, existing: ProjectToolServer? = nil) {
        self.projectId = projectId
        self.existing = existing
        switch existing?.connection {
        case let .command(argv, env)?:
            _kind = State(initialValue: .command)
            _address = State(initialValue: ShellWords.join(argv))
            _pairs = State(initialValue: ShellWords.lines(env, separator: "="))
        case let .url(url, headers)?:
            _kind = State(initialValue: .url)
            _address = State(initialValue: url)
            _pairs = State(initialValue: ShellWords.lines(headers, separator: ": "))
        case nil:
            _kind = State(initialValue: .url)
            _address = State(initialValue: "")
            _pairs = State(initialValue: "")
        }
        _name = State(initialValue: existing?.name ?? "")
        _nameTyped = State(initialValue: existing != nil)
        _agents = State(initialValue: Set(existing?.agents ?? ProviderRegistry.all.filter { $0.toolServerSupport != .none }.map(\.id)))
        _notes = State(initialValue: existing?.notes ?? "")
        _tools = State(initialValue: existing?.tools ?? [])
        _access = State(initialValue: existing?.access ?? [:])
        _listError = State(initialValue: existing?.listError)
        _listedAt = State(initialValue: existing?.listedAt)
    }

    private var connection: ProjectToolServer.Connection? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch kind {
        case .url: return .url(text, headers: ShellWords.pairs(pairs, separator: ":"))
        case .command:
            let argv = ShellWords.split(text)
            return argv.isEmpty ? nil : .command(argv, env: ShellWords.pairs(pairs, separator: "="))
        }
    }

    private var cleanName: String { ProjectToolServer.cleanName(name) }

    private var nameProblem: String? {
        if cleanName.isEmpty { return "Give it a name." }
        if cleanName.hasPrefix("abstract") { return "Names starting with “abstract” are kept for Abstract's own tools." }
        if model.toolServers(for: projectId).contains(where: { $0.name == cleanName && $0.id != existing?.id }) {
            return "This project already has a server named \(cleanName)."
        }
        return nil
    }

    private var draft: ProjectToolServer? {
        guard let connection else { return nil }
        var server = existing ?? ProjectToolServer(projectId: projectId, name: cleanName, connection: connection)
        server.name = cleanName
        server.connection = connection
        server.agents = ProviderRegistry.all.map(\.id).filter(agents.contains)
        server.notes = String(notes.prefix(ProjectToolServer.notesLimit))
        server.tools = tools
        server.access = access.filter { name, _ in tools.contains { $0.name == name } }
        server.listError = listError
        server.listedAt = listedAt
        return server
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "Add a Tool Server" : "Edit \(existing?.name ?? "")").font(.btHeadline)
                Text("Paste the server's URL, or the command that starts it on this Mac. Each chat's agent gets it through its own settings for that chat; your agents' global settings aren't changed.")
                    .font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    connectionFields
                    nameField
                    agentChoices
                    notesField
                    toolList
                }
                .padding(.trailing, Space.sm)
            }
            .frame(maxHeight: 520)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.btSecondary).keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save", action: save)
                    .buttonStyle(.btPrimary).keyboardShortcut(.defaultAction)
                    .disabled(draft == nil || nameProblem != nil)
            }
        }
        .padding(Space.xl)
        .frame(width: 620)
        .background(Color.btCanvas)
        .onChange(of: address) { _, _ in
            guard !nameTyped, let connection else { return }
            name = ProjectToolServer.suggestedName(for: connection)
        }
    }

    @ViewBuilder private var connectionFields: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Picker("", selection: $kind) {
                Text("URL").tag(Kind.url)
                Text("Command").tag(Kind.command)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            BTTextField(kind == .url ? "URL" : "Command", text: $address,
                        prompt: kind == .url ? "https://mcp.linear.app/mcp" : "npx -y @sentry/mcp-server", mono: true)
            Text(kind == .url ? "Headers, one per line" : "Environment, one per line")
                .font(.btCallout).foregroundStyle(Color.btTextSecondary)
            BTTextEditor(text: $pairs, placeholder: kind == .url ? "Authorization: Bearer …" : "API_KEY=…", mono: true, minHeight: 52)
            Text(kind == .url
                 ? "A server that signs in with OAuth needs no header: the agents sign in themselves where they can. Headers are kept on this Mac and given to the agent privately, never on its command line."
                 : "Values are kept on this Mac and given to the agent privately, never on its command line.")
                .font(.btCallout).foregroundStyle(Color.btTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var nameField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Name").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            BTTextField("Name", text: Binding(get: { name }, set: { name = $0; nameTyped = true }), prompt: "linear", mono: true)
                .frame(maxWidth: 240)
            let problem = connection == nil && cleanName.isEmpty ? nil : nameProblem
            Text(problem ?? (cleanName.isEmpty ? "What agents call the server's tools."
                             : "Agents see its tools under \(cleanName), like mcp__\(cleanName)__create_issue in Claude."))
                .font(.btCallout).foregroundStyle(problem == nil ? Color.btTextTertiary : Color.btWarning)
        }
    }

    @ViewBuilder private var agentChoices: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Agents that get it").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            ForEach(ProviderRegistry.all, id: \.id) { provider in
                if provider.toolServerSupport == .none {
                    Toggle(isOn: .constant(false)) {
                        Text(provider.name)
                        Text("\(provider.name) can't keep a server's tools out or ask first yet, so it doesn't get these servers.")
                    }
                    .disabled(true)
                } else {
                    Toggle(provider.name, isOn: Binding(get: { agents.contains(provider.id) },
                                                        set: { on in if on { agents.insert(provider.id) } else { agents.remove(provider.id) } }))
                }
            }
        }
    }

    @ViewBuilder private var notesField: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Usage notes").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                Spacer()
                Text("\(notes.count.formatted()) / \(ProjectToolServer.notesLimit.formatted())")
                    .font(.btCallout).monospacedDigit()
                    .foregroundStyle(notes.count > ProjectToolServer.notesLimit ? Color.btWarning : Color.btTextTertiary)
            }
            BTTextEditor(text: $notes, placeholder: "File bugs in the ABS team. Never close an issue someone else opened.", minHeight: 60)
            Text("Added to each agent's instructions.").font(.btCallout).foregroundStyle(Color.btTextTertiary)
        }
    }

    @ViewBuilder private var toolList: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Tools").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                Spacer()
                if listing { ProgressView().controlSize(.small) }
                Button(tools.isEmpty ? "List Tools" : "List Again", action: list)
                    .buttonStyle(.bt(.ghost, size: .small)).disabled(connection == nil || listing)
            }
            if let listError {
                Text(listError).font(.btCallout).foregroundStyle(Color.btWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if tools.isEmpty {
                Text("Abstract asks the server which tools it has, so you can choose what each may do. Until then each agent uses all of them under its own rules.")
                    .font(.btCallout).foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tools) { tool in
                HStack(alignment: .top, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.btMono).foregroundStyle(Color.btText)
                        if let detail = tool.detail {
                            Text(detail).font(.btCallout).foregroundStyle(Color.btTextTertiary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: Space.sm)
                    Picker("", selection: Binding(get: { access[tool.name] ?? (tool.readOnly ? .allowed : .askFirst) },
                                                  set: { access[tool.name] = $0 })) {
                        ForEach(ToolAccess.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            if let note = askFirstNote {
                Text(note).font(.btCallout).foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Which chosen agents leave Ask first tools out, when any tool asks first.
    private var askFirstNote: String? {
        guard tools.contains(where: { (access[$0.name] ?? ($0.readOnly ? .allowed : .askFirst)) == .askFirst }) else { return nil }
        let cant = ProviderRegistry.all.filter { agents.contains($0.id) && $0.toolServerSupport == .allowOrOff }.map(\.name)
        let can = ProviderRegistry.all.filter { agents.contains($0.id) && $0.toolServerSupport == .askFirst }.map(\.name)
        var lines: [String] = []
        if !can.isEmpty { lines.append("\(ListFormatter.localizedString(byJoining: can)) shows a card in the chat before an Ask first tool runs.") }
        if !cant.isEmpty {
            lines.append("\(ListFormatter.localizedString(byJoining: cant)) can't stop to ask, so \(cant.count == 1 ? "it doesn't" : "they don't") get Ask first tools.")
        }
        return lines.joined(separator: " ")
    }

    private func list() {
        guard let draft else { return }
        listing = true
        Task {
            let listed = await model.listTools(of: draft)
            tools = listed.tools.isEmpty && listed.listError != nil ? tools : listed.tools
            listError = listed.listError
            listedAt = listed.listedAt
            listing = false
        }
    }

    private func save() {
        guard let server = draft, nameProblem == nil else { return }
        model.saveToolServer(server)
        dismiss()
        // A new server lists its tools on its own, so access can be set.
        guard existing == nil, server.tools.isEmpty, server.listedAt == nil else { return }
        Task { @MainActor in
            let listed = await model.listTools(of: server)
            guard var current = model.toolServers(for: server.projectId).first(where: { $0.id == server.id }) else { return }
            current.tools = listed.tools
            current.listError = listed.listError
            current.listedAt = listed.listedAt
            model.saveToolServer(current)
        }
    }
}
