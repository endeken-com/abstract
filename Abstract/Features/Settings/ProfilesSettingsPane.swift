import SwiftUI
import AbstractCore

/// The named setups chats and automations start from (ABS-101): a list
/// of them, and the chosen one's editor below. A running chat keeps what
/// it started with.
struct ProfilesSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedId: String?

    private var selected: AgentProfile? { model.profile(selectedId) ?? model.profiles.first }

    var body: some View {
        Form {
            Section {
                if model.profiles.isEmpty {
                    Text("No profiles yet.").foregroundStyle(Color.btTextSecondary)
                }
                ForEach(model.profiles) { profile in
                    SettingsListRow(symbol: profile.iconSymbol ?? "person.crop.circle",
                                    title: profile.name.isEmpty ? "Profile" : profile.name,
                                    detail: summary(profile),
                                    selected: selected?.id == profile.id) { selectedId = profile.id }
                }
            } header: {
                HStack {
                    Text("Profiles")
                    Spacer()
                    Button {
                        selectedId = model.addProfile().id
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                    }
                    .buttonStyle(.bt(.ghost, size: .small))
                }
            } footer: {
                SettingsCaption("The New Chat window and the automation editor fill a profile in for you, and workflows hand a chat from one profile to the next. Editing one changes later chats, never a chat already running. A project can choose which profiles it offers in its Project Settings.")
            }
            if let selected {
                ProfileSettingsSection(profile: selected, onDuplicate: { selectedId = duplicate(selected).id },
                                       onDelete: { delete(selected) })
                    .id(selected.id)
            }
        }
        .settingsPane()
    }

    /// "Claude · Opus · Edits accepted"
    private func summary(_ profile: AgentProfile) -> String {
        var parts = [ProviderRegistry.name(profile.providerId)]
        if let id = profile.model { parts.append(model.models(for: profile.providerId).option(id)?.label ?? id) }
        if let effort = profile.effort { parts.append(ModelOption.effortTitle(effort)) }
        parts.append(profile.permissionPolicy.title)
        return parts.joined(separator: " · ")
    }

    private func duplicate(_ profile: AgentProfile) -> AgentProfile {
        var copy = profile
        copy.id = UUID().uuidString
        copy.name = "\(profile.name) copy"
        copy.sortOrder = (model.profiles.map(\.sortOrder).max() ?? -1) + 1
        copy.createdAt = Date()
        model.saveProfile(copy)
        return copy
    }

    private func delete(_ profile: AgentProfile) {
        let index = model.profiles.firstIndex { $0.id == profile.id } ?? 0
        model.deleteProfile(profile.id)
        selectedId = model.profiles.indices.contains(index) ? model.profiles[index].id : model.profiles.last?.id
    }
}

/// One row of a settings list: an icon, a name and a line under it; the
/// chosen one is highlighted and its editor shows below the list.
struct SettingsListRow: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.btText : Color.btTextSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.btBodyMedium).foregroundStyle(Color.btText)
                    Text(detail)
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Space.sm)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.btTextSecondary)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(selected ? Color.btSelection : hovering ? Color.btHover : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .padding(.horizontal, -Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ProfileSettingsSection: View {
    @Environment(AppModel.self) private var model
    let profile: AgentProfile
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    @FocusState private var instructionsFocused: Bool
    @State private var confirmingDelete = false

    /// Icons on offer beside a profile's name.
    private static let symbols = ["person.crop.circle", "hammer", "magnifyingglass",
                                  "list.bullet.clipboard", "ladybug", "doc.text.magnifyingglass",
                                  "wrench.and.screwdriver", "lightbulb", "paintpalette", "checkmark.seal",
                                  "testtube.2", "text.book.closed", "shield.lefthalf.filled"]

    var body: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: binding(\.name, default: "Profile"), prompt: Text("e.g. Reviewer"))
                    .labelsHidden()
                    .fontWeight(Field.weight)
                    .btField()
                    .frame(maxWidth: 360)
            }
            LabeledContent("Icon") {
                Picker("Icon", selection: binding(\.iconSymbol)) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Label(symbol, systemImage: symbol).tag(Optional(symbol))
                    }
                    if let custom = profile.iconSymbol, !Self.symbols.contains(custom) {
                        Label(custom, systemImage: custom).tag(Optional(custom))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            LabeledContent("Agent") {
                Picker("Agent", selection: binding(\.providerId, default: "claude")) {
                    ForEach(model.pickableAgents(keeping: profile.providerId), id: \.id) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            LabeledContent("Model") {
                let catalog = model.models(for: profile.providerId)
                Picker("Model", selection: binding(\.model)) {
                    Text("Agent default").tag(String?.none)
                    ForEach(catalog.models) { Text($0.label).tag(Optional($0.id)) }
                    if !catalog.versions.isEmpty {
                        Section("Specific versions") {
                            ForEach(catalog.versions) { Text($0.label).tag(Optional($0.id)) }
                        }
                    }
                    if let custom = profile.model, catalog.option(custom) == nil {
                        Text(custom).tag(Optional(custom))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            if !model.efforts(providerId: profile.providerId, model: profile.model).levels.isEmpty {
                LabeledContent("Effort") {
                    Picker("Effort", selection: binding(\.effort)) {
                        Text("Agent default").tag(String?.none)
                        ForEach(model.efforts(providerId: profile.providerId, model: profile.model).levels, id: \.self) {
                            Text(ModelOption.effortTitle($0)).tag(Optional($0))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }
            }
            LabeledContent {
                Picker("Permissions", selection: binding(\.permissionPolicy, default: .ask)) {
                    ForEach(PermissionPolicy.autonomyCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
            } label: {
                Text("Permissions")
                Text(profile.permissionPolicy.detail)
            }
            LabeledContent {
                TextEditor(text: binding(\.instructions, default: ""))
                    .font(.btBody)
                    // A form row sets its controls flush right; prose reads from the left.
                    .multilineTextAlignment(.leading)
                    .focused($instructionsFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 88, maxHeight: 180)
                    .btFieldChrome(focused: instructionsFocused)
            } label: {
                Text("Instructions")
                Text("Given to the agent every time a chat or run starts from this profile, as Markdown.")
            }
            if !model.librarySkills.isEmpty {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(model.librarySkills) { skill in
                            Toggle(skill.name, isOn: Binding(
                                get: { model.profile(profile.id)?.skills.contains(skill.id) ?? false },
                                set: { on in model.setSkill(skill.id, added: on, profileId: profile.id) }))
                                .help(skill.description ?? skill.name)
                        }
                    }
                } label: {
                    Text("Skills")
                    Text("Added to the project's skills for chats and runs started from this profile.")
                }
            }
            HStack {
                Button("Duplicate", action: onDuplicate)
                Spacer()
                Button("Delete Profile…", role: .destructive) { confirmingDelete = true }
            }
            .confirmationDialog("Delete “\(profile.name)”?", isPresented: $confirmingDelete) {
                Button("Delete Profile", role: .destructive, action: onDelete)
            } message: {
                Text(usage)
            }
        } header: {
            HStack(spacing: Space.sm) {
                Image(systemName: profile.iconSymbol ?? "person.crop.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.btTextSecondary)
                Text(profile.name.isEmpty ? "Profile" : profile.name).font(.btHeadline).foregroundStyle(Color.btText)
            }
            .padding(.top, Space.md)
            .padding(.bottom, 2)
        }
    }

    /// What deleting it leaves behind.
    private var usage: String {
        let workflows = model.workflows.filter { $0.steps.contains { $0.profileId == profile.id } }.map(\.name)
        let automations = model.automations.filter { $0.profileId == profile.id }.count
        var parts = ["Chats started from it keep what they started with."]
        if automations > 0 { parts.append("\(automations) automation\(automations == 1 ? "" : "s") will run on their own settings.") }
        if !workflows.isEmpty { parts.append("Workflows using it stop at its step: \(workflows.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    /// Edits a field of this profile and saves the result.
    private func binding<T: Equatable>(_ key: WritableKeyPath<AgentProfile, T>, default fallback: T) -> Binding<T> {
        Binding(get: { model.profile(profile.id)?[keyPath: key] ?? fallback }, set: { new in
            guard var edited = model.profile(profile.id), edited[keyPath: key] != new else { return }
            edited[keyPath: key] = new
            model.saveProfile(edited)
        })
    }

    private func binding<T>(_ key: WritableKeyPath<AgentProfile, T?>) -> Binding<T?> {
        Binding(get: { model.profile(profile.id)?[keyPath: key] ?? nil }, set: { new in
            guard var edited = model.profile(profile.id) else { return }
            edited[keyPath: key] = new
            model.saveProfile(edited)
        })
    }
}
