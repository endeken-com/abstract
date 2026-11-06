import Foundation

/// Searchable tasks and controls in Settings. An item opens the section that
/// contains the control, so a match is useful even when it is far down a pane.
struct SettingsSearchItem: Identifiable {
    let id: String
    let tab: SettingsTab
    let title: String
    let detail: String
    let anchor: String?
    let terms: String
    let opensInstalledPlugins: Bool

    init(_ tab: SettingsTab, _ title: String, _ detail: String, anchor: String? = nil, terms: String = "", opensInstalledPlugins: Bool = false) {
        self.id = "\(tab.rawValue).\(title)"
        self.tab = tab
        self.title = title
        self.detail = detail
        self.anchor = anchor
        self.terms = terms
        self.opensInstalledPlugins = opensInstalledPlugins
    }

    func matches(_ query: String) -> Bool {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        let content = "\(title) \(detail) \(tab.title) \(terms)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return words.allSatisfy { content.contains($0) }
    }
}

enum SettingsSearchIndex {
    static let items: [SettingsSearchItem] = [
        .init(.appearance, "Theme", "Choose a light, dark, or system theme.", anchor: "appearance.theme", terms: "appearance dark mode light mode paper graphite ink contrast"),
        .init(.appearance, "Interface font", "Change the font used by the app.", anchor: "appearance.interface-font", terms: "size weight"),
        .init(.appearance, "Editor font", "Change code and editor typography.", anchor: "appearance.editor-font", terms: "ligatures line height"),
        .init(.appearance, "Chat text", "Change the font and size of agent answers.", anchor: "appearance.chat-text"),
        .init(.notifications, "Agent notifications", "Choose when an agent needs you or finishes.", anchor: "notifications.events", terms: "permission question finished alert mute silence"),
        .init(.notifications, "Automation failure notifications", "Choose whether failed runs notify you.", anchor: "notifications.events"),
        .init(.notifications, "Quiet and stalled chats", "Set when a chat shows no output or becomes stalled.", anchor: "notifications.quiet", terms: "minutes threshold"),
        .init(.usage, "Accounts and limits", "See signed-in agent accounts and plan limits.", anchor: "usage.accounts", terms: "claude codex profile quota"),
        .init(.usage, "Token usage", "See usage from agent session logs.", anchor: "usage.tokens", terms: "cost estimate chart"),
        .init(.general, "Transcript", "Choose how much of a chat is shown.", anchor: "general.chat"),
        .init(.general, "Output style", "Choose how agent answers are written.", anchor: "general.chat"),
        .init(.general, "Automation time zone", "Set the default zone for new schedules.", anchor: "general.automations", terms: "timezone"),
        .init(.general, "Command line", "Install or remove the abstract command.", anchor: "general.command-line", terms: "cli path terminal"),
        .init(.general, "Updates", "Check for updates and choose a release channel.", anchor: "general.updates", terms: "nightly automatic download version"),
        .init(.worktrees, "Worktree location", "Choose where new chat worktrees are created.", anchor: "worktrees.naming", terms: "folder path template reset default checkout"),
        .init(.worktrees, "Branch prefix", "Name branches created for new chats.", anchor: "worktrees.naming", terms: "git"),
        .init(.worktrees, "Naming preview", "Preview a worktree path and branch name.", anchor: "worktrees.preview", terms: "tokens"),
        .init(.agents, "Detect agents", "Find installed coding agents again.", anchor: "agents.detect", terms: "binary path claude codex opencode muse"),
        .init(.agents, "Default agent model", "Choose an agent's starting model and effort.", anchor: "agents.providers", terms: "claude codex opencode muse"),
        .init(.agents, "Agent launch arguments", "Set a binary path or extra arguments.", anchor: "agents.providers", terms: "cli flags"),
        .init(.profiles, "Profiles", "Find, add, or edit a saved agent setup.", anchor: "profiles.list", terms: "default profile model permissions instructions skills"),
        .init(.workflows, "Workflows", "Find, add, or edit a sequence of profiles.", anchor: "workflows.list", terms: "steps handover automation"),
        .init(.skills, "Add Skills", "Add a folder or GitHub repository to the library.", terms: "source install"),
        .init(.skills, "Skill library", "Search and update skills from saved sources.", anchor: "skills.library", terms: "folder github repository"),
        .init(.skills, "Project skills", "Browse skills already in project files.", anchor: "skills.projects"),
        .init(.integrations, "Revund", "Connect Revund to review a chat's changes.", anchor: "integrations.revund", terms: "api key"),
        .init(.plugins, "Plugin gallery", "Find and install plugins.", anchor: "plugins.gallery", terms: "github disk catalog extension"),
        .init(.plugins, "Installed plugins", "Review installed plugins and their permissions.", anchor: "plugins.gallery", terms: "enabled update remove", opensInstalledPlugins: true),
        .init(.devices, "Mac and phone pairing", "Pair or manage devices.", anchor: "devices.pairing", terms: "nearby remote"),
        .init(.devices, "Internet access", "Let paired devices connect over the internet.", anchor: "devices.internet", terms: "invitation relay"),
        .init(.devices, "Device hosting", "Let paired devices use this Mac.", anchor: "devices.hosting", terms: "share"),
        .init(.advanced, "Raw agent output", "Show unrecognized output for debugging.", anchor: "advanced.developer", terms: "developer"),
    ]

    static func results(for query: String) -> [SettingsSearchItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let exact = items.filter { $0.matches(query) }
        let otherTabs = SettingsTab.allCases.filter { tab in
            tab.matches(query) && !exact.contains { $0.tab == tab }
        }
        return exact + otherTabs.map { SettingsSearchItem($0, $0.title, $0.subtitle) }
    }
}
