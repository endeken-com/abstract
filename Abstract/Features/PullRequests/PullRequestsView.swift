import SwiftUI
import AppKit
import AbstractCore

/// Pull requests across every project with a code host: the ones chats
/// opened, yours, or everything open. A chat's pull request opens in that chat.
struct PullRequestsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("pullRequests.filter") private var filter: Filter = .chats
    @State private var refreshing = false

    enum Filter: String, CaseIterable, Identifiable {
        case chats, mine, open
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chats: "From Chats"
            case .mine: "Mine"
            case .open: "All Open"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                content
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.xl)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.btCanvas)
        .task { await refresh(force: false) }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: Space.md)
            if refreshing { ProgressView().controlSize(.small).scaleEffect(0.8) }
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.icon)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(refreshing)
                .help("Refresh (⌘R)")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let blocked {
            VStack(spacing: Space.md) {
                EmptyStateView(symbol: PullRequestGlyph.symbol, title: blocked.0, message: blocked.1)
                Button("Check again") { Task { await refresh() } }
            }
        } else {
            ForEach(model.projects.filter { model.projectPullRequestErrors[$0.id] != nil }) { project in
                if let reason = model.projectPullRequestErrors[project.id] {
                    Label("\(project.name): \(reason)", systemImage: "exclamationmark.triangle.fill")
                        .font(.btCallout).foregroundStyle(Color.btTextSecondary).textSelection(.enabled)
                }
            }
            let sections = model.projects.compactMap { project -> (Project, [PullRequest])? in
                let prs = shown(model.projectPullRequests[project.id] ?? [], in: project)
                return prs.isEmpty ? nil : (project, prs)
            }
            if sections.isEmpty && model.projectPullRequestErrors.isEmpty {
                EmptyStateView(symbol: PullRequestGlyph.symbol, title: emptyTitle, message: emptyMessage)
                    .padding(.top, Space.xxl)
            } else {
                ForEach(sections, id: \.0.id) { project, prs in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                            .padding(.bottom, Space.xs)
                        // With several repositories in the project, each row names its own.
                        let namesRepos = model.namesPullRequestRepos(project.id)
                        ForEach(prs) { pr in PullRequestRow(pr: pr, project: project, showRepo: namesRepos) }
                    }
                }
            }
        }
    }

    /// Why there is nothing to list: no code host plugin is on (ABS-139),
    /// or none of them is installed and signed in.
    private var blocked: (String, String)? {
        let hosts = model.plugins.usable.compactMap { plugin in plugin.manifest?.contributes.codeHost.map { (plugin.id, $0.title) } }
        guard !hosts.isEmpty else { return ("No code host", CodeHosts.needsPlugin("your code host")) }
        let states = hosts.compactMap { id, title in model.codeHostAccess[id].map { ($0.access, title) } }
        guard let first = states.first, states.allSatisfy({ $0.0.blocks }) else { return nil }
        let title = first.1
        switch first.0 {
        case .ready, .unavailable: return nil
        case .missing(let install):
            return ("\(title) CLI needed", install.map { "Install it with `\($0)`, then sign in." } ?? "Install it, then sign in.")
        case .signedOut(let hint):
            return ("Sign in to \(title)", hint.map { "Run `\($0)` in a terminal, then refresh." } ?? "Sign in, then refresh.")
        }
    }

    private func shown(_ prs: [PullRequest], in project: Project) -> [PullRequest] {
        switch filter {
        case .chats: prs.filter { model.chat(for: $0, in: project.id) != nil }
        case .mine: prs.filter { $0.state == .open && model.codeHostViewers.contains($0.author ?? "") }
        case .open: prs.filter { $0.state == .open }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .chats: "No pull requests from chats"
        case .mine: "No open pull requests of yours"
        case .open: "No open pull requests"
        }
    }

    private var emptyMessage: String {
        filter == .chats ? "Open one from a chat's Pull Request tab once its work is ready." : "Across your projects."
    }

    private func refresh(force: Bool = true) async {
        refreshing = true
        await model.refreshCodeHostAccess(fresh: true)
        await model.refreshPullRequests(force: force)
        refreshing = false
    }
}

private struct PullRequestRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let project: Project
    var showRepo = false
    @State private var hovering = false

    var body: some View {
        let chat = model.chat(for: pr, in: project.id)
        Button { open(chat) } label: {
            HStack(alignment: .top, spacing: Space.md) {
                PullRequestMark(pr: pr, size: 15).frame(width: 18, height: 22)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(pr.title).font(.btBodyMedium).foregroundStyle(Color.btText).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: pr.label).font(.btCaptionMedium).foregroundStyle(pr.stateTint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(pr.stateTint.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                            .fixedSize()
                    }
                    HStack(spacing: Space.sm) {
                        if showRepo, let repo = pr.repoName {
                            Text(repo).lineLimit(1)
                            Text("·")
                        }
                        if let chat {
                            // The chat's name, unless it's the pull request's title too.
                            Image(systemName: "text.bubble").help("Opened from \(chat.name)")
                            if chat.name != pr.title { Text(chat.name).lineLimit(1) }
                        } else if let author = pr.author {
                            GitHubAvatar(login: author, size: 14, hostTitle: pr.hostTitle)
                            Text(author).lineLimit(1)
                        }
                        Text(pr.head).font(.btMonoSmall).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.xs)
                        if let updated = pr.updatedAt {
                            Text(RelativeTime.short(updated)).fixedSize()
                        }
                    }
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
                    if pr.standing != nil { PullRequestStanding(pr: pr) }
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 9)
            .background(hovering ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(chat == nil ? "Open on \(pr.hostTitle)" : "Open in \(chat!.name)")
        .contextMenu {
            if let url = pr.url {
                Button("Open on \(pr.hostTitle)") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if let chat { Button("Open Chat") { open(chat) } }
        }
    }

    private func open(_ chat: Session?) {
        guard let chat else {
            if let url = pr.url { NSWorkspace.shared.open(url) }
            return
        }
        model.pullRequests[chat.id] = pr
        model.open(chat.id)
        model.showPane(.review, in: chat.id)
    }
}
