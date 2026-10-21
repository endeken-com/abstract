import Foundation
import AbstractCore

/// The MCP servers a project gives its chats' agents (ABS-123), managed in
/// Project Settings → Tools (MCP). A change reaches each chat at its
/// agent's next launch; nothing in the agents' own config is written.
extension AppModel {
    func toolServers(for projectId: String?) -> [ProjectToolServer] {
        projectId.flatMap { toolServers[$0] } ?? []
    }

    func saveToolServer(_ server: ProjectToolServer) {
        do {
            try store.save(server)
            var servers = toolServers(for: server.projectId)
            if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server } else { servers.append(server) }
            toolServers[server.projectId] = servers
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    func deleteToolServer(_ server: ProjectToolServer) {
        do {
            try store.deleteToolServer(server.id)
            toolServers[server.projectId]?.removeAll { $0.id == server.id }
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    /// Asks the server for its tools and keeps the answer, or why it failed.
    /// Access already chosen stays with tools of the same name.
    func listTools(of server: ProjectToolServer) async -> ProjectToolServer {
        var listed = server
        do {
            listed.tools = try await MCPToolList.list(server.connection)
            listed.listError = nil
        } catch {
            listed.listError = error.localizedDescription
        }
        listed.listedAt = Date()
        return listed
    }

    /// Where each chat's launch files go: `agent-config/<chat id>/` beside
    /// the attachments.
    static var agentConfigRoot: String {
        AttachmentStore.root.deletingLastPathComponent().appendingPathComponent("agent-config").path
    }
}
