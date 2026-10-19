import SwiftUI
import AbstractCore

/// The named setups chats and automations start from (ABS-101). Each
/// profile is edited in place; a running chat keeps what it started with.
struct ProfilesSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(model.profiles) { profile in
                ProfileSettingsSection(profile: profile)
            }
            Section {
                HStack(spacing: Space.md) {
                    SettingsCaption("A profile is a saved setup — agent, model, effort, permissions and instructions — that the New Chat window and the automation editor fill in for you. Editing one changes later chats, never a chat already running. A project can choose which profiles it offers in its Project Settings.")
                    Spacer(minLength: Space.md)
                    Button("Add Profile") { model.addProfile() }
                }
            }
        }
        .settingsPane()
    }
}

private struct ProfileSettingsSection: View {
    @Environment(AppModel.self) private var model
    let profile: AgentProfile
    @FocusState private var instructionsFocused: Bool

    /// Icons on offer beside a profile's name.
    private static let symbols = ["person.crop.circle", "hammer", "magnifyingglass",
                                  "list.bullet.clipboard", "ladybug", "doc.text.magnifyingglass",
                                  "wrench.and.screwdriver", "lightbulb"]

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
                    ForEach(PermissionPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
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
                    .focused($instructionsFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 88, maxHeight: 180)
                    .btFieldChrome(focused: instructionsFocused)
            } label: {
                Text("Instructions")
                Text("Given to the agent every time a chat or run starts from this profile, as Markdown.")
            }
            LabeledContent("Delete") {
                Button("Delete Profile", role: .destructive) { model.deleteProfile(profile.id) }
            }
        } header: {
            HStack(spacing: Space.sm) {
                Image(systemName: profile.iconSymbol ?? "person.crop.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.btTextSecondary)
                Text(profile.name.isEmpty ? "Profile" : profile.name).font(.btHeadline).foregroundStyle(Color.btText)
            }
            .padding(.bottom, 2)
        }
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
