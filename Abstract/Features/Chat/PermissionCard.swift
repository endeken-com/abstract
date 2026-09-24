import SwiftUI
import AbstractCore

/// An approval that has no tool row of its own to sit on (Claude usually
/// sends the call first; when it doesn't, this stands in). It reads exactly
/// like a tool row: what it wants to do, the diff or command, Skip / Continue.
struct PermissionCard: View {
    let sessionId: String
    let request: PendingPermission

    var body: some View {
        ToolCallView(
            sessionId: sessionId,
            call: ToolCall(id: request.requestId, name: request.toolName, input: request.input,
                           edit: EditPreview.fromToolInput(name: request.toolName, input: request.input)),
            approval: request
        )
    }
}
