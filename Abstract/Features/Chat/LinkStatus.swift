import SwiftUI
import Observation
import Textual
import AbstractCore

/// How links in chats stand, as plugins' link decorators report them
/// (ABS-126). A link is asked about while a message showing it is on
/// screen, again once its status is old, and its status stays until a
/// newer answer replaces it.
@Observable
@MainActor
final class PluginLinkStatuses {
    private(set) var statuses: [PluginLinks.Match: PluginLinkStatus] = [:]
    @ObservationIgnored private var cache = PluginLinkCache()
    /// Asks the plugin's background script; set by the app.
    @ObservationIgnored var lookUp: (PluginLinks.Match) async -> PluginLinkLookup = { _ in .failed }

    /// The pills for these links, for the parser.
    func pills(_ matches: [PluginLinks.Match], decorators: [ResolvedPluginContribution]) -> LinkPills? {
        let found = matches.reduce(into: [PluginLinks.Match: PluginLinkStatus]()) { out, match in
            out[match] = statuses[match]
        }
        return found.isEmpty ? nil : LinkPills(decorators: decorators, statuses: found)
    }

    /// Keeps these links' statuses fresh for as long as the caller's task runs.
    func follow(_ matches: [PluginLinks.Match]) async {
        guard !matches.isEmpty else { return }
        while !Task.isCancelled {
            let now = Date()
            for match in matches where cache.isDue(match, now: now) {
                cache.asking(match, now: now)
                Task { [weak self] in
                    guard let self else { return }
                    let lookup = await lookUp(match)
                    cache.answered(match, lookup)
                    if statuses[match] != cache.status(match) { statuses[match] = cache.status(match) }
                }
            }
            try? await Task.sleep(for: .seconds(PluginLinks.checkInterval))
        }
    }

    /// A status as if just answered, for the demo's screenshots.
    func seed(_ match: PluginLinks.Match, _ status: PluginLinkStatus) {
        cache.asking(match)
        cache.answered(match, .status(status))
        statuses[match] = status
    }

    /// Forgets the statuses of plugins that can't run any more.
    func keep(pluginIds: Set<String>) {
        cache.forget(pluginIds: pluginIds)
        statuses = statuses.filter { pluginIds.contains($0.key.pluginId) }
    }
}

/// The statuses one text shows, and the decorators that found its links.
struct LinkPills: Hashable {
    let decorators: [ResolvedPluginContribution]
    let statuses: [PluginLinks.Match: PluginLinkStatus]

    func status(for url: URL) -> PluginLinkStatus? {
        PluginLinks.match(url, decorators: decorators).flatMap { statuses[$0] }
    }
}

extension AppModel {
    /// The decorated links in a message, and the pills they have so far.
    func linkPills(in text: String) -> (matches: [PluginLinks.Match], pills: LinkPills?) {
        let decorators = plugins.contributions(.link)
        let matches = PluginLinks.matches(in: text, decorators: decorators)
        return (matches, matches.isEmpty ? nil : pluginLinks.pills(matches, decorators: decorators))
    }
}

/// Markdown parsing that puts each decorated link's status after it.
/// Clicking the pill opens the link, as the link does.
struct LinkPillParser: MarkupParser {
    let base: any MarkupParser
    let pills: LinkPills

    func attributedString(for input: String) throws -> AttributedString {
        PluginLinks.decorate(try base.attributedString(for: input)) { url in
            guard let status = pills.status(for: url) else { return nil }
            var pill = AttributedString("\u{FFFC}")
            pill.textual.attachment = AnyAttachment(LinkPillAttachment(status: status))
            pill.link = url
            return AttributedString(" ") + pill
        }
    }
}

/// A link's status, drawn inline after it: a quiet wash in the state's
/// colour, the way the pull request menu shows state.
struct LinkPillAttachment: Attachment {
    let status: PluginLinkStatus

    private static var font: NSFont { .systemFont(ofSize: 10.5, weight: .medium) }
    private static let height: CGFloat = 16
    private static let padding: CGFloat = 6

    // Copied text keeps the link and leaves its status out.
    var description: String { "" }
    var selectionStyle: AttachmentSelectionStyle { .text }

    var body: some View {
        let ink = Self.ink(status.tone)
        Text(status.label)
            .font(Font(Self.font))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, Self.padding)
            .frame(height: Self.height)
            .background(ink.opacity(0.14), in: Capsule())
            .help(status.label)
    }

    func baselineOffset(in environment: TextEnvironmentValues) -> CGFloat { -4 }

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        let width = (status.label as NSString).size(withAttributes: [.font: Self.font]).width
        return CGSize(width: width.rounded(.up) + Self.padding * 2, height: Self.height)
    }

    static func ink(_ tone: PluginLinkStatus.Tone) -> Color {
        switch tone {
        case .open: .btPullRequestOpenInk
        case .draft: .btPullRequestDraftInk
        case .merged: .btPullRequestMergedInk
        case .closed: .btPullRequestClosedInk
        case .failing: .btRemoved
        case .neutral: .btTextSecondary
        }
    }
}
