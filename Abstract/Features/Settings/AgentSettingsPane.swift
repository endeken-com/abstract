import AppKit
import SwiftUI
import AbstractCore

/// One section per agent: what was detected, and how to launch it.
struct AgentSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var detecting = false

    var body: some View {
        Form {
            ForEach(ProviderRegistry.all.filter { !($0 is LocalModelProvider) }, id: \.id) { provider in
                ProviderSettingsSection(provider: provider, detecting: detecting, detect: detect)
            }
            LocalModelsSettings()
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

    var body: some View {
        Section {
            LabeledContent("Detected") { detection }

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
