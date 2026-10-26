import SwiftUI
import AbstractCore

/// The switches plugins add to a chat's Pull Request tab (ABS-109), such
/// as Follow. Each is on or off for this chat; flipping one tells the
/// plugin's background script. Only for an open pull request of a chat on
/// this Mac: a paired Mac's chats keep their pull requests there.
struct PluginPullRequestSwitches: View {
    @Environment(AppModel.self) private var model
    let sessionId: String

    var body: some View {
        let switches = model.plugins.contributions(.pullRequest)
        if !switches.isEmpty, !sessionId.hasPrefix(RemoteService.mirrorPrefix) {
            HStack(spacing: Space.lg) {
                ForEach(switches) { item in
                    Toggle(item.contribution.title, isOn: Binding(
                        get: { model.plugins.isSwitchOn(item, chatId: sessionId) },
                        set: { model.setPluginSwitch(item, chatId: sessionId, on: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextSecondary)
                        .fixedSize()
                        .help(model.plugins.plugin(item.pluginId)?.manifest?.description ?? item.pluginName)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
