import AppKit
import SwiftUI
import AbstractCore

/// One section per agent: what was detected, and how to launch it.
struct AgentSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var detecting = false

    var body: some View {
        Form {
            ForEach(ProviderRegistry.all, id: \.id) { provider in
                ProviderSettingsSection(provider: provider, detecting: detecting, detect: detect)
            }
            Section {
                HStack(spacing: Space.md) {
                    SettingsCaption("Abstract looks for each agent on your login shell's PATH when it starts. Detect again after installing or updating one.")
                    Spacer(minLength: Space.md)
                    Button(action: detect) {
                        HStack(spacing: 6) {
                            if detecting { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
                            Text(detecting ? "Detecting…" : "Detect Again")
                        }
                    }
                    .disabled(detecting)
                }
            }
        }
        .settingsPane()
    }

    private func detect() {
        guard !detecting else { return }
        detecting = true
        Task {
            await model.detectProviders()
            detecting = false
        }
    }
}

private struct ProviderSettingsSection: View {
    @Environment(AppModel.self) private var model
    let provider: any ProviderDefinition
    let detecting: Bool
    let detect: () -> Void
    /// Kept as typed; parsed into `extraArgs` on every change so spaces
    /// can be typed without being trimmed away.
    @State private var argsText = ""
    @State private var typingModel = false
    @State private var modelDraft = ""
    @FocusState private var modelFieldFocused: Bool

    var body: some View {
        Section {
            LabeledContent("Detected") { detection }

            LabeledContent("Default model") { defaultModelControl }

            if !model.efforts(providerId: provider.id, model: defaults.model).levels.isEmpty {
                LabeledContent("Default effort") {
                    Picker("Default effort", selection: effortBinding) {
                        Text("Agent default").tag(String?.none)
                        ForEach(model.efforts(providerId: provider.id, model: defaults.model).levels, id: \.self) { level in
                            Text(ModelOption.effortTitle(level)).tag(Optional(level))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }
            }

            LabeledContent {
                HStack(spacing: Space.sm) {
                    TextField("Binary path", text: pathBinding, prompt: Text("\(provider.binary) on PATH"))
                        .labelsHidden()
                        .fontWeight(Field.weight)
                        .multilineTextAlignment(.leading)
                        .font(.btMono)
                        .onSubmit(detect)
                        .btField()
                    Button("Choose…", action: choose)
                }
                .frame(maxWidth: 360)
            } label: {
                Text("Binary path")
                if let path = override.path, !path.isEmpty, !model.executor.fileExists(path) {
                    Text("No file at this path.").foregroundStyle(Color.btWarning)
                } else {
                    Text("Leave empty to find it on PATH.")
                }
            }

            LabeledContent {
                TextField("Extra arguments", text: $argsText, prompt: Text("e.g. --model opus"))
                    .labelsHidden()
                    .fontWeight(Field.weight)
                    .multilineTextAlignment(.leading)
                    .font(.btMono)
                    .btField()
                    .frame(maxWidth: 360)
            } label: {
                Text("Extra arguments")
                Text("Added to every launch, separated by spaces.")
            }
        } header: {
            HStack(spacing: Space.sm) {
                ProviderLogo(providerId: provider.id, size: 20)
                Text(provider.name).font(.btHeadline).foregroundStyle(Color.btText)
            }
            .padding(.bottom, 2)
        }
        .onAppear { argsText = (override.extraArgs ?? []).joined(separator: " ") }
        .onChange(of: argsText) { _, text in
            let args = text.split(whereSeparator: \.isWhitespace).map(String.init)
            update { $0.extraArgs = args.isEmpty ? nil : args }
        }
    }

    @ViewBuilder
    private var detection: some View {
        let status = model.providerStatus[provider.id]
        if detecting || status == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                Text("Looking…").foregroundStyle(Color.btTextSecondary)
            }
        } else if let status, status.available {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.btAdded)
                    Text(status.version ?? "Installed").foregroundStyle(Color.btText)
                }
                if let path = status.path {
                    Text(path)
                        .font(.btMonoSmall)
                        .foregroundStyle(Color.btTextSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            Label(override.path?.isEmpty == false ? "Not found at the path below" : "Not found on this Mac's PATH",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.btWarning)
        }
    }

    private var override: ProviderOverride {
        model.providerOverrides[provider.id] ?? ProviderOverride()
    }

    private var defaults: AgentDefaults {
        model.agentDefaults[provider.id] ?? AgentDefaults()
    }

    @ViewBuilder
    private var defaultModelControl: some View {
        if typingModel {
            HStack(spacing: Space.sm) {
                TextField("Model ID", text: $modelDraft)
                    .font(.btMono)
                    .focused($modelFieldFocused)
                    .onSubmit(commitModel)
                    .onExitCommand { typingModel = false }
                    .btField()
                Button("Set", action: commitModel)
            }
            .frame(maxWidth: 360)
            .onAppear { modelFieldFocused = true }
        } else {
            let catalog = model.models(for: provider.id)
            HStack(spacing: Space.sm) {
                Picker("Default model", selection: modelBinding) {
                    Text("Agent default").tag(String?.none)
                    ForEach(catalog.models) { option in
                        Text(option.label).tag(Optional(option.id))
                    }
                    if !catalog.versions.isEmpty {
                        Section("Specific versions") {
                            ForEach(catalog.versions) { option in
                                Text(option.label).tag(Optional(option.id))
                            }
                        }
                    }
                    if let custom = defaults.model, catalog.option(custom) == nil {
                        Text(custom).tag(Optional(custom))
                    }
                }
                .labelsHidden()
                Button("Other…") {
                    modelDraft = defaults.model ?? ""
                    typingModel = true
                }
            }
            .frame(maxWidth: 360)
        }
    }

    private var modelBinding: Binding<String?> {
        Binding(get: { defaults.model }, set: { selected in
            var value = defaults
            value.model = selected
            let catalog = model.models(for: provider.id)
            let option = if let selected { catalog.option(selected) }
                else { catalog.defaultOption(configured: model.configuredModel(for: provider.id)) }
            if let effort = value.effort, !(option?.efforts.contains(effort) ?? false) { value.effort = nil }
            saveDefaults(value)
        })
    }

    private var effortBinding: Binding<String?> {
        Binding(get: { defaults.effort }, set: { selected in
            var value = defaults
            value.effort = selected
            saveDefaults(value)
        })
    }

    private func commitModel() {
        let name = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        modelBinding.wrappedValue = name.isEmpty ? nil : name
        typingModel = false
    }

    private func saveDefaults(_ value: AgentDefaults) {
        model.agentDefaults[provider.id] = value.model == nil && value.effort == nil ? nil : value
    }

    private var pathBinding: Binding<String> {
        Binding(get: { override.path ?? "" }, set: { new in
            update { $0.path = new.isEmpty ? nil : new }
        })
    }

    /// Writes one provider's override, dropping it entirely when empty.
    private func update(_ change: (inout ProviderOverride) -> Void) {
        var value = override
        change(&value)
        guard value != override else { return }
        let isEmpty = (value.path ?? "").isEmpty && (value.extraArgs ?? []).isEmpty
        model.providerOverrides[provider.id] = isEmpty ? nil : value
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(provider.name) binary"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        let current = override.path ?? model.providerStatus[provider.id]?.path
        panel.directoryURL = current.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: "/usr/local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update { $0.path = url.path }
        detect()
    }
}
