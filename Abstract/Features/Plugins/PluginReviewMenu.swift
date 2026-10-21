import SwiftUI
import AbstractCore

/// The Review commands plugins add (ABS-112), in Review's toolbar. A
/// command whose title names `{agent}` is offered once per installed agent
/// other than the chat's own: "Ask Codex to review".
struct PluginReviewMenu: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    /// What the review compares now, handed to the command.
    let scope: String

    var body: some View {
        let commands = model.plugins.contributions(.review)
        if let session = model.session(sessionId), !commands.isEmpty,
           !sessionId.hasPrefix(RemoteService.mirrorPrefix), session.reviewsSessionId == nil {
            let others = model.pickableAgents().filter { $0.id != session.providerId }
            Menu {
                ForEach(commands) { command in
                    if command.contribution.isPerAgent {
                        ForEach(others, id: \.id) { agent in
                            Button(command.contribution.title(agentName: agent.name)) {
                                model.invokePluginReview(command, chatId: sessionId, agentId: agent.id, scope: scope)
                            }
                        }
                    } else {
                        Button(command.contribution.title) {
                            model.invokePluginReview(command, chatId: sessionId, agentId: nil, scope: scope)
                        }
                    }
                }
            } label: {
                Image(systemName: commands.first?.contribution.symbolOrFallback ?? PluginManifest.fallbackSymbol)
            }
            .menuStyle(.button)
            .buttonStyle(.icon(size: 26))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Set(commands.map(\.pluginName)).sorted().joined(separator: ", "))
        }
    }
}
