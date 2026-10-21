import SwiftUI
import AbstractCore

/// Where issues and pull requests to attach come from: GitHub through its
/// CLI. Issue trackers such as Linear are plugins (ABS-141), set up in
/// Settings → Plugins.
struct IntegrationsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var github: GitHubAccess?

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
            RevundSettingsSection()
        }
        .settingsPane()
        .task {
            github = await GitHub.access(model.executor)
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
