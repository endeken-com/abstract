import SwiftUI
import AbstractCore

/// Where issues to attach come from: Linear with an API key. GitHub is a
/// plugin now (ABS-139), with its own page under Settings → Plugins.
struct IntegrationsSettingsPane: View {
    @State private var linear = LinearAccount.shared

    var body: some View {
        Form {
            Section {
                if linear.isConnected {
                    LabeledContent {
                        Button("Disconnect") { linear.disconnect() }
                    } label: {
                        Text(linear.viewer.map { "Connected as \($0)" } ?? "Connected")
                        Text("Link Linear issues in the composer. The API key is kept in your keychain.")
                    }
                } else {
                    LinearConnectForm()
                }
            } header: {
                Text("Linear")
            }
            RevundSettingsSection()
        }
        .settingsPane()
        .task {
            await linear.checkViewer()
        }
    }
}
