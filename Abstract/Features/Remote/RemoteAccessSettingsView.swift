import SwiftUI
import AppKit
import AbstractCore

/// Settings › Devices › Remote access (ABS-219): reach this Mac's chat feed
/// from assistants anywhere, through mcp.useabstract.app, and the grants
/// you've given them.
struct RemoteAccessSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var revoking: RemoteGrant?

    var body: some View {
        let access = model.remoteAccess
        Section {
            Toggle(isOn: Binding(get: { access.enabled }, set: { access.setEnabled($0) })) {
                Text("Let assistants reach this Mac from anywhere")
                Text(statusLine(access.status))
            }
            LabeledContent {
                HStack(spacing: Space.sm) {
                    Text(verbatim: access.mcpURL).font(.btMonoSmall).foregroundStyle(Color.btTextSecondary).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(access.mcpURL, forType: .string)
                    }.buttonStyle(.bt(.secondary, size: .small))
                }
            } label: {
                Text("Address for assistants")
                Text("Add it in the assistant as a remote MCP server. It asks you to approve it here first.")
            }
        } header: {
            Text("Remote access")
        } footer: {
            SettingsCaption("Read-only, like the chat feed: assistants you approve can list, read and search the open chats of the projects you choose. Code blocks and secrets are always hidden. Abstract's own token never leaves this Mac.")
        }
        .id("devices.remoteAccess")
        .confirmationDialog("Revoke \(revoking?.clientName ?? "this assistant")?", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) {
                if let grant = revoking { access.revoke(grant.id) }
                revoking = nil
            }
        } message: {
            Text("It stops reading this Mac at once, and its tokens stop working. To connect it again, add it in the assistant again.")
        }

        if !access.grants.isEmpty {
            Section {
                ForEach(access.grants) { grant in
                    RemoteGrantRow(grant: grant, projects: projectNames(grant.projects),
                                   onHealth: { access.setHealthRedaction($0, for: grant.id) },
                                   onRevoke: { revoking = grant })
                }
                if access.grants.contains(where: { !$0.isActive }) {
                    Button("Clear revoked") { access.clearRevoked() }.buttonStyle(.bt(.secondary, size: .small))
                }
            } header: {
                Text("Assistants with access")
            }
            .id("devices.remoteAccessGrants")
        }
    }

    private func statusLine(_ status: RemoteAccessService.Status) -> String {
        switch status {
        case .off: "Off. Assistants outside this Mac can't reach it."
        case .registering: "Setting up this Mac…"
        case .connecting: "Connecting…"
        case .connected: "On and connected."
        case .retrying(let at): "Not connected. Trying again \(at.formatted(.relative(presentation: .named)))."
        case .replaced: "Another copy of Abstract with this Mac's identity connected. Trying again shortly."
        case .turningOff: "Turning off: finishes once this Mac is online."
        case .failed(let message): message
        }
    }

    private func projectNames(_ projects: RemoteProjects) -> String {
        switch projects {
        case .all: return "All projects"
        case .only(let ids):
            let names = model.projects.filter { ids.contains($0.id) }.map(\.name).sorted()
            let missing = ids.count - names.count
            return (names + (missing > 0 ? ["\(missing) removed"] : [])).joined(separator: ", ")
        }
    }
}

private struct RemoteGrantRow: View {
    let grant: RemoteGrant
    let projects: String
    let onHealth: (Bool) -> Void
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.sm) {
                        Text(verbatim: grant.clientName).fontWeight(.medium)
                        if let domain = grant.clientDomain {
                            Text(verbatim: domain).font(.btMonoSmall).foregroundStyle(Color.btTextTertiary)
                        }
                    }
                    Text(verbatim: projects).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    Text(detail).font(.btCallout).foregroundStyle(Color.btTextTertiary)
                }
                Spacer()
                if grant.isActive {
                    Button("Revoke", action: onRevoke).buttonStyle(.bt(.secondary, size: .small))
                } else {
                    Text("Revoked").font(.btCallout).foregroundStyle(Color.btTextTertiary)
                }
            }
            if grant.isActive {
                Toggle("Hide health data", isOn: Binding(get: { grant.redactsHealthData }, set: onHealth))
                    .toggleStyle(.checkbox).font(.btCallout)
            }
        }
        .opacity(grant.isActive ? 1 : 0.6)
    }

    private var detail: String {
        let added = "Added \(grant.createdAt.formatted(date: .abbreviated, time: .shortened))"
        guard let used = grant.lastUsedAt else { return added + " · not used yet" }
        return added + " · last read \(used.formatted(.relative(presentation: .named)))"
    }
}
