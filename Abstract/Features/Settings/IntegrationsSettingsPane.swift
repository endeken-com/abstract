import SwiftUI
import AbstractCore

/// Where issues and pull requests to attach come from: GitHub through its
/// CLI, Linear with an API key.
struct IntegrationsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var github: GitHubAccess?
    @State private var linear = LinearAccount.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(githubStatus).foregroundStyle(Color.btTextSecondary)
                } label: {
                    Text("GitHub CLI")
                    Text(github == .ready ? "Issues and pull requests of each project's repository can be linked in the composer."
                         : "Abstract uses your `gh` sign-in; it keeps no GitHub token of its own.")
                }
            } header: {
                Text("GitHub")
            }
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
            github = await GitHub.access(model.executor)
            await linear.checkViewer()
        }
    }

    private var githubStatus: String {
        switch github {
        case nil: "Checking…"
        case .ready: "Signed in"
        case .signedOut: "Run `gh auth login`"
        case .missing: "Not installed"
        }
    }
}
