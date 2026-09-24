import SwiftUI
import AbstractCore

/// Settings › Agents: Ollama and LM Studio, wherever they run.
struct LocalModelsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(LocalModelKind.allCases, id: \.self) { kind in
            LocalModelSection(kind: kind)
        }
        Section {
            Toggle(isOn: Binding(get: { model.shareLocalModels }, set: { model.shareLocalModels = $0 })) {
                Text("Share this Mac's local models with paired Macs")
                Text("They reach them through Abstract, encrypted. The servers can stay listening on this Mac only.")
            }
        } footer: {
            SettingsCaption("A chat on a local model runs Codex (installed on its own) against the server. Your code and prompts stay on your machines.")
        }
    }
}

private struct LocalModelSection: View {
    @Environment(AppModel.self) private var model
    let kind: LocalModelKind
    @State private var address = ""
    @State private var editingAddress = false

    private enum Choice: Hashable { case thisMac, address, paired(String) }

    var body: some View {
        let status = model.localModelStatus[kind]
        let source = model.localModelSource(kind)
        Section {
            LabeledContent("Status") { statusView(status) }
            Picker("Runs on", selection: choiceBinding) {
                Text("This Mac").tag(Choice.thisMac)
                Text("Another computer, by address").tag(Choice.address)
                ForEach(sharingMacs, id: \.id) { device in
                    Text("\(device.peer.name) (paired)").tag(Choice.paired(device.id))
                }
            }
            if editingAddress || { if case .address = source { true } else { false } }() {
                LabeledContent {
                    HStack(spacing: Space.sm) {
                        TextField("Address", text: $address, prompt: Text("192.168.1.30:\(kind.defaultPort)"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit(useAddress)
                        Button("Use", action: useAddress)
                            .buttonStyle(.bt(.secondary, size: .small))
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } label: {
                    Text("Address")
                    Text("Where that computer's server listens.")
                }
            }
            if let status, status.reachable, !status.models.isEmpty {
                LabeledContent {
                    Text(status.models.joined(separator: ", "))
                        .font(.btCallout).foregroundStyle(Color.btTextSecondary)
                        .multilineTextAlignment(.trailing).lineLimit(3)
                        .textSelection(.enabled)
                } label: {
                    Text("Models")
                    Text("Pick one when you start a chat.")
                }
            }
        } header: {
            HStack(spacing: 6) {
                ProviderLogo(providerId: kind.providerId, size: 14)
                Text(kind.name)
            }
        } footer: {
            SettingsCaption(help)
        }
        .onAppear {
            if case .address(let current) = source { address = current }
        }
    }

    @ViewBuilder
    private func statusView(_ status: LocalModelServerStatus?) -> some View {
        let codex = model.providerStatus["codex"]?.available ?? false
        HStack(spacing: 6) {
            Circle().fill(status?.reachable == true ? Color.btAdded : Color.btTextTertiary.opacity(0.5)).frame(width: 7, height: 7)
            if let status, status.reachable {
                Text(status.models.isEmpty ? "Running, no models yet" : "Running · \(status.models.count) model\(status.models.count == 1 ? "" : "s")")
                if !codex { Text("· Codex needed").foregroundStyle(Color.btRemoved) }
            } else {
                Text(status == nil ? "Checking…" : "Not reachable")
            }
        }
        .font(.btCallout)
        .foregroundStyle(Color.btTextSecondary)
        .help(status?.error ?? "")
    }

    /// Paired Macs sharing this server, and the one chosen even while it's away.
    private var sharingMacs: [RemoteService.PairedDevice] {
        model.remote.paired.filter { device in
            if case .pairedMac(device.id) = model.localModelSource(kind) { return true }
            return model.remote.links[device.id]?.snapshot?.localModels?.contains(kind) == true
        }
    }

    private var choiceBinding: Binding<Choice> {
        Binding {
            if editingAddress { return .address }
            return switch model.localModelSource(kind) {
            case .thisMac: .thisMac
            case .address: .address
            case .pairedMac(let id): .paired(id)
            }
        } set: { choice in
            switch choice {
            case .thisMac: editingAddress = false; model.setLocalModelSource(kind, .thisMac)
            case .address: editingAddress = true
            case .paired(let id): editingAddress = false; model.setLocalModelSource(kind, .pairedMac(deviceId: id))
            }
        }
    }

    private func useAddress() {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        editingAddress = false
        model.setLocalModelSource(kind, .address(trimmed))
    }

    private var help: String {
        switch kind {
        case .ollama:
            "From ollama.com. For a server on another computer, start it there with OLLAMA_HOST=0.0.0.0 so it listens on the network, or run Abstract on that Mac, pair it, and choose it here."
        case .lmstudio:
            "Start the server in LM Studio's Developer tab, or with `lms server start`. For another computer, turn on Serve on Local Network there, or run Abstract on that Mac, pair it, and choose it here."
        }
    }
}
