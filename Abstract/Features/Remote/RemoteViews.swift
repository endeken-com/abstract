import SwiftUI
import AppKit
import AbstractCore

// MARK: - Settings › Devices

/// This Mac, the Macs paired with it, and the ones nearby to pair.
struct DevicesSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var remote = model.remote
        Form {
            Section {
                LabeledContent {
                    Text(verbatim: remote.identity.peer.fingerprint).font(.btMonoSmall).foregroundStyle(Color.btTextTertiary)
                        .textSelection(.enabled)
                } label: {
                    Text(remote.identity.name)
                    Text("Other Macs see this name. The code beside it identifies this Mac's key.")
                }
                Toggle(isOn: $remote.hosting) {
                    Text("Let paired Macs use this one")
                    Text(remote.hosting
                         ? (remote.listening ? "Paired Macs can see these projects, start chats and answer their agents here." : "Starting…")
                         : "Off: paired Macs can't reach this one, and no new Mac can ask to pair.")
                }
            } header: {
                Text("This Mac")
            } footer: {
                SettingsCaption("A paired Mac can run commands here through the agents, the same as you can. Pair only your own Macs.")
            }

            Section {
                if remote.paired.isEmpty {
                    Text("No paired Macs yet.").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                } else {
                    ForEach(remote.paired) { device in
                        PairedRow(device: device)
                    }
                }
            } header: {
                Text("Paired")
            }

            Section {
                let unpaired = remote.nearby.filter { device in !remote.paired.contains { $0.id == device.id } }
                if unpaired.isEmpty {
                    Text("Looking for Macs with Abstract open and “Let paired Macs use this one” on…")
                        .font(.btCallout).foregroundStyle(Color.btTextSecondary)
                } else {
                    ForEach(unpaired) { device in
                        LabeledContent {
                            Button("Pair") { remote.pair(with: device) }.buttonStyle(.bt(.secondary, size: .small))
                        } label: {
                            Text(device.name)
                        }
                    }
                }
            } header: {
                Text("Nearby")
            } footer: {
                SettingsCaption("Macs on this network only. Pairing shows a code on both Macs; they must match.")
            }
            AdvancedDeviceSettings()
            if let error = remote.lastError {
                Section { Text(error).font(.btCallout).foregroundStyle(Color.btRemoved) }
            }
        }
        .settingsPane()
        .task { remote.startBrowsing() }
    }
}

/// For when finding each other on the network isn't enough: a name of your
/// own, a fixed port, the direct Wi-Fi link, and pairing by address.
/// Folded away; discovery covers most setups.
private struct AdvancedDeviceSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("devices.advanced") private var expanded = false
    @State private var name = ""
    @State private var port = ""
    @State private var address = ""

    var body: some View {
        @Bindable var remote = model.remote
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                LabeledContent {
                    TextField("Name", text: $name, prompt: Text(Host.current().localizedName ?? "Mac"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { remote.customName = name.isEmpty ? nil : name }
                } label: {
                    Text("Name on the network")
                    Text("What other Macs see. Press Return to use it.")
                }
                LabeledContent {
                    TextField("Port", text: $port, prompt: Text("Automatic"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit { remote.fixedPort = UInt16(port) }
                } label: {
                    Text("Port")
                    Text(remote.listeningPort.map { "Listening on \($0). Fix one for firewall rules or pairing by address." }
                         ?? "Fix one for firewall rules or pairing by address.")
                }
                Toggle(isOn: $remote.peerToPeer) {
                    Text("Direct Wi-Fi")
                    Text("Also reach Macs close by with no network between them.")
                }
                LabeledContent {
                    Text(addresses).font(.btMonoSmall).foregroundStyle(Color.btTextSecondary).textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("This Mac's addresses")
                    Text("Give one of these to a Mac that can't find this one.")
                }
                LabeledContent {
                    HStack(spacing: Space.sm) {
                        TextField("Address", text: $address, prompt: Text("192.168.1.20:52000"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit(pairByAddress)
                        Button("Pair", action: pairByAddress)
                            .buttonStyle(.bt(.secondary, size: .small))
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } label: {
                    Text("Pair by address")
                    Text("For a Mac on another network or over a VPN. It must be sharing, on a port you know.")
                }
            } label: {
                Text("Advanced")
            }
        } footer: {
            if expanded { SettingsCaption("Macs found on the network need none of this.") }
        }
        .onAppear {
            name = remote.customName ?? ""
            port = remote.fixedPort.map(String.init) ?? ""
        }
    }

    private var addresses: String {
        let list = model.remote.localAddresses
        guard !list.isEmpty else { return "Not on a network" }
        let port = model.remote.listeningPort.map { ":\($0)" } ?? ""
        return list.map { $0 + port }.joined(separator: "\n")
    }

    private func pairByAddress() {
        model.remote.pair(address: address)
        address = ""
    }
}

private struct PairedRow: View {
    @Environment(AppModel.self) private var model
    let device: RemoteService.PairedDevice
    @State private var confirming = false

    var body: some View {
        let link = model.remote.links[device.id]
        LabeledContent {
            HStack(spacing: Space.sm) {
                Text(status(link)).font(.btCallout).foregroundStyle(link?.state == .online ? Color.btText : Color.btTextTertiary)
                Button("Unpair") { confirming = true }.buttonStyle(.bt(.ghost, size: .small))
            }
        } label: {
            Text(device.peer.name)
            Text(verbatim: [device.address, device.peer.fingerprint].compactMap { $0 }.joined(separator: " · ")).font(.btMonoSmall)
        }
        .confirmationDialog("Unpair \(device.peer.name)?", isPresented: $confirming) {
            Button("Unpair", role: .destructive) { model.remote.unpair(device.id) }
        } message: {
            Text("Neither Mac will reach the other until you pair them again.")
        }
    }

    private func status(_ link: RemoteLink?) -> String {
        if model.remote.hosted[device.id] != nil, link?.state != .online { return "Using this Mac" }
        switch link?.state {
        case .online?: return "Connected"
        case .connecting?: return "Connecting…"
        case .failed(let reason)?: return reason
        default: return device.lastSeen.map { "Last seen \(RelativeTime.short($0)) ago" } ?? "Not seen yet"
        }
    }
}

// MARK: - Pairing

/// The code both Macs show while pairing. The Mac being paired with accepts;
/// the other waits for it.
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: RemoteService.PairingPrompt

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 26, weight: .regular)).foregroundStyle(Color.btTextSecondary)
            VStack(spacing: 6) {
                Text(prompt.incoming ? "Pair with \(prompt.peer.name)?" : "Pairing with \(prompt.peer.name)")
                    .font(BTFont.ui(16, .semibold)).foregroundStyle(Color.btText)
                Text(explanation).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: prompt.code)
                .font(BTFont.mono(30, .medium)).tracking(3).foregroundStyle(prompt.declined ? Color.btTextTertiary : Color.btText)
                .padding(.vertical, Space.sm)
            HStack(spacing: Space.sm) {
                if prompt.incoming {
                    Button("Decline") { model.remote.answerPairing(false) }.buttonStyle(.bt(.ghost))
                    Button("Pair") { model.remote.answerPairing(true) }.buttonStyle(.bt(.primary)).keyboardShortcut(.defaultAction)
                } else {
                    Button(prompt.declined ? "Close" : "Cancel") { model.remote.dismissPrompt() }.buttonStyle(.bt(.ghost))
                }
            }
        }
        .padding(Space.xxl)
        .frame(width: 380)
    }

    private var explanation: String {
        if prompt.declined { return "\(prompt.peer.name) didn't accept, or the connection closed." }
        return prompt.incoming
            ? "Pair only if \(prompt.peer.name) shows this same code. It will be able to use this Mac's agents."
            : "Check \(prompt.peer.name) shows this same code, then accept there."
    }
}

// MARK: - Sidebar

/// Paired Macs connected now, each with its projects and chats.
struct RemoteDevicesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let links = model.remote.paired.compactMap { model.remote.links[$0.id] }.filter { $0.snapshot != nil }
        ForEach(links, id: \.device.id) { link in
            RemoteDeviceGroup(link: link)
        }
    }
}

private struct RemoteDeviceGroup: View {
    @Environment(AppModel.self) private var model
    let link: RemoteLink
    @AppStorage("sidebar.remoteCollapsed") private var collapsedRaw = ""
    @State private var starting: Project?

    var body: some View {
        let snapshot = link.snapshot
        VStack(alignment: .leading, spacing: 0) {
        RailSection(title: link.device.peer.name, collapsed: collapsed) {
            Image(systemName: "laptopcomputer").font(.system(size: 10, weight: .regular))
                .foregroundStyle(link.state == .online ? Color.btTextSecondary : Color.btTextTertiary.opacity(0.5))
                .frame(width: 22, height: 22)
                .help(link.state == .online ? "Connected" : "Not connected")
        }
        if !collapsed.wrappedValue, let snapshot {
            ForEach(snapshot.projects.sorted { $0.sortOrder < $1.sortOrder }) { project in
                let chats = snapshot.sessions.filter { $0.projectId == project.id }
                    .sorted { ($0.lastEventAt ?? $0.createdAt) > ($1.lastEventAt ?? $1.createdAt) }
                RailGroup(title: project.name, trailing: AnyView(
                    Button { starting = project } label: { Image(systemName: "plus") }
                        .buttonStyle(RailIconStyle())
                        .help("New chat in \(project.name) on \(link.device.peer.name)")
                )) {
                    ForEach(chats) { session in
                        if let mirror = model.session(RemoteService.mirrorId(device: link.device.id, session: session.id)) {
                            RailChatRow(session: mirror, backgroundTasks: model.runningBackgroundTasks(mirror.id))
                        }
                    }
                }
            }
        }
        }
        .sheet(item: $starting) { project in
            RemoteNewChat(link: link, project: project) { starting = nil }
        }
    }

    private var collapsed: Binding<Bool> {
        Binding {
            collapsedRaw.split(separator: ",").contains(Substring(link.device.id))
        } set: { value in
            var ids = Set(collapsedRaw.split(separator: ",").map(String.init))
            if value { ids.insert(link.device.id) } else { ids.remove(link.device.id) }
            collapsedRaw = ids.sorted().joined(separator: ",")
        }
    }
}

/// A new chat in a project on another Mac.
private struct RemoteNewChat: View {
    @Environment(AppModel.self) private var model
    let link: RemoteLink
    let project: Project
    let done: () -> Void
    @State private var prompt = ""
    @State private var providerId = ""
    @State private var policy: PermissionPolicy = .ask
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("New chat in \(project.name)").font(BTFont.ui(15, .semibold))
            Text("Runs on \(link.device.peer.name), in a new worktree there.").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            BTTextEditor(text: $prompt, placeholder: "Describe the task", minHeight: 110)
            HStack(spacing: Space.md) {
                Picker("Agent", selection: $providerId) {
                    ForEach(link.snapshot?.providers ?? [], id: \.self) { Text(ProviderRegistry.name($0)).tag($0) }
                }
                .fixedSize()
                Picker("Mode", selection: $policy) {
                    ForEach(PermissionPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
            }
            if let error { Text(error).font(.btCallout).foregroundStyle(Color.btRemoved) }
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(.bt(.ghost))
                Button(working ? "Starting…" : "Start", action: start).buttonStyle(.bt(.primary))
                    .disabled(working || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || providerId.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .onAppear {
            providerId = link.snapshot?.providers.contains(project.defaultProviderId) == true ? project.defaultProviderId : (link.snapshot?.providers.first ?? "")
            policy = project.defaultPermissionPolicy
        }
    }

    private func start() {
        working = true
        Task {
            do {
                let id = try await model.remote.startChat(on: link.device.id, projectId: project.id, providerId: providerId,
                                                          prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), policy: policy)
                done()
                // The chat shows once the other Mac lists it.
                for _ in 0..<20 where model.session(id) == nil { try? await Task.sleep(for: .milliseconds(150)) }
                model.open(id)
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}

// MARK: - A chat on another Mac

struct RemoteChatView: View {
    let sessionId: String

    /// A chat on a Mac that isn't connected now.
    var body: some View {
        EmptyStateView(symbol: "laptopcomputer.slash", title: "That Mac isn't connected",
                       message: "The chat comes back when the Mac it runs on is on this network with Abstract open.")
    }
}

// MARK: - Sidebar: devices

/// At the foot of the sidebar: this Mac and the Macs paired with it, how
/// they stand, and the way to their settings.
struct RailDevicesBar: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let remote = model.remote
        let connected = remote.paired.filter { remote.links[$0.id]?.state == .online || remote.hosted[$0.id] != nil }.count
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 11.5, weight: .regular)).frame(width: Rail.iconColumn)
                Text("Devices").font(BTFont.ui(13))
                Spacer(minLength: 4)
                Text(status(connected: connected)).font(.btCaption).foregroundStyle(Color.btTextTertiary).lineLimit(1)
                if connected > 0 || remote.hosting {
                    Circle().fill(connected > 0 ? Color.btAdded : Color.btTextTertiary).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(Color.btTextSecondary)
            .padding(.horizontal, Rail.rowPadding)
            .frame(height: Rail.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailRowStyle(selected: open))
        .popover(isPresented: $open, arrowEdge: .top) { DevicesPopover(close: { open = false }) }
    }

    private func status(connected: Int) -> String {
        if connected > 0 { return "\(connected) connected" }
        if model.remote.hosting { return "Sharing" }
        return model.remote.paired.isEmpty ? "" : "\(model.remote.paired.count) paired"
    }
}

private struct DevicesPopover: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        @Bindable var remote = model.remote
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Image(systemName: "laptopcomputer").foregroundStyle(Color.btTextSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(remote.identity.name).font(BTFont.ui(13, .medium))
                    Text("This Mac").font(.btCaption).foregroundStyle(Color.btTextTertiary)
                }
                Spacer()
                Toggle("Share", isOn: $remote.hosting).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help(remote.hosting ? "Paired Macs can use this one" : "Let paired Macs use this one")
            }
            if !remote.paired.isEmpty {
                Hairline()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(remote.paired) { device in
                        let online = remote.links[device.id]?.state == .online || remote.hosted[device.id] != nil
                        HStack(spacing: Space.sm) {
                            Circle().fill(online ? Color.btAdded : Color.btTextTertiary.opacity(0.5)).frame(width: 6, height: 6)
                            Text(device.peer.name).font(BTFont.ui(13)).lineLimit(1)
                            Spacer()
                            Text(online ? "Connected" : device.lastSeen.map { "Seen \(RelativeTime.short($0)) ago" } ?? "Offline")
                                .font(.btCaption).foregroundStyle(Color.btTextTertiary)
                        }
                    }
                }
            }
            let nearby = remote.nearby.filter { n in !remote.paired.contains { $0.id == n.id } }
            if !nearby.isEmpty {
                Text("\(nearby.count) Mac\(nearby.count == 1 ? "" : "s") nearby to pair").font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
            Hairline()
            Button("Device Settings…") {
                close()
                UserDefaults.standard.set(SettingsTab.devices.rawValue, forKey: "settingsTab")
                model.isSettingsOpen = true
            }
            .buttonStyle(.bt(.ghost, size: .small))
        }
        .padding(Space.md)
        .frame(width: 300)
        .task { remote.startBrowsing() }
    }
}
