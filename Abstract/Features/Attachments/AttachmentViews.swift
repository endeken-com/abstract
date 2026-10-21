import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// GitHub's issue octicon (MIT), drawn in the text colour.
enum BrandGlyph {
    static let issue = template(#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M8 9.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Z"/><path d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0ZM1.5 8a6.5 6.5 0 1 0 13 0 6.5 6.5 0 0 0-13 0Z"/></svg>"#)

    private static func template(_ svg: String) -> NSImage {
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// Small image previews, read once per file.
private enum Thumbnails {
    static var images: [String: NSImage] = [:]

    static func image(_ path: String) -> NSImage? {
        if let cached = images[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        images[path] = image
        return image
    }
}

/// What an attachment is, at a glance: the file's own icon, the image
/// itself, or the issue tracker's mark.
struct AttachmentGlyph: View {
    let kind: PromptAttachment.Kind
    var path: String?
    /// Tracker issues: the plugin whose icon it shows.
    var tracker: String?
    var size: CGFloat = 13

    var body: some View {
        switch kind {
        case .file:
            FileIcon(path: path ?? "", isDirectory: path.map { $0.hasSuffix("/") || isFolder($0) } ?? false, size: size)
        case .image:
            if let path, let image = Thumbnails.image(path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "photo").font(.system(size: size * 0.8)).frame(width: size, height: size)
            }
        case .githubIssue:
            Image(nsImage: BrandGlyph.issue).renderingMode(.template).resizable().frame(width: size, height: size)
        case .pullRequest:
            PullRequestGlyph(kind: .open).frame(width: size, height: size)
        case .trackerIssue:
            TrackerGlyph(pluginId: tracker, size: size)
        case .revundReview:
            RevundGlyph(size: size)
        }
    }

    private func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// A tracker plugin's icon, or a plain ticket when it isn't on.
struct TrackerGlyph: View {
    let pluginId: String?
    var size: CGFloat = 13

    var body: some View {
        if let image = TrackerIcons.image(pluginId) {
            Image(nsImage: image).renderingMode(.template).resizable().frame(width: size - 1, height: size - 1)
        } else {
            Image(systemName: "ticket").font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}

// MARK: - Composer

/// The attachments waiting to go with the message, each with a × to take it off.
struct AttachmentTray: View {
    @Binding var attachments: [PromptAttachment]

    var body: some View {
        FlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(attachments) { a in
                AttachmentPill(attachment: a) { attachments.removeAll { $0.id == a.id } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AttachmentPill: View {
    let attachment: PromptAttachment
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            AttachmentGlyph(kind: attachment.kind, path: attachment.path, tracker: attachment.tracker, size: 14)
                .foregroundStyle(Color.btTextSecondary)
            Text(attachment.label)
                .font(BTFont.ui(12))
                .foregroundStyle(Color.btText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? Color.btTextSecondary : Color.btTextTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(Color.btHover, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { AttachmentActions.open(attachment.url ?? attachment.path) }
        .onHover { hovering = $0 }
        .help(attachment.url ?? attachment.path ?? attachment.label)
    }
}

enum AttachmentActions {
    /// A link opens in the browser; a file in its app.
    static func open(_ target: String?) {
        guard let target else { return }
        if target.hasPrefix("/") {
            NSWorkspace.shared.open(URL(fileURLWithPath: target))
        } else if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }

    static func chooseFiles(_ add: @escaping ([PromptAttachment]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = "Files or a folder to send with your message"
        panel.begin { response in
            guard response == .OK else { return }
            add(panel.urls.compactMap { try? AttachmentStore.importFile($0) })
        }
    }
}

/// Issue tracker (while a tracker plugin is on), GitHub issue and pull
/// request buttons, beside Send. `repoRoot` is where `gh` looks for the
/// repository; nil hides GitHub.
struct AttachmentButtons: View {
    @Environment(AppModel.self) private var model
    let repoRoot: String?
    /// The chat, or else the project, whose Mac runs `gh`; neither is this Mac.
    var sessionId: String? = nil
    var projectId: String? = nil
    @Binding var attachments: [PromptAttachment]
    var size: CGFloat = 26
    @State private var picking: AttachSource?

    var body: some View {
        HStack(spacing: 0) {
            let trackers = model.issueTrackers
            if !trackers.isEmpty {
                button(.tracker, help: trackers.count == 1 ? "Link a \(trackers[0].title) issue" : "Link an issue") {
                    TrackerGlyph(pluginId: trackers.count == 1 ? trackers[0].pluginId : nil, size: 13)
                }
            }
            if repoRoot != nil {
                button(.githubIssue, help: "Link a GitHub issue") {
                    Image(nsImage: BrandGlyph.issue).renderingMode(.template).resizable().frame(width: 13, height: 13)
                }
                button(.pullRequest, help: "Link a pull request") {
                    PullRequestGlyph(kind: .open).frame(width: 13, height: 13)
                }
            }
        }
    }

    private func button<Label: View>(_ source: AttachSource, help: String, @ViewBuilder label: () -> Label) -> some View {
        Button { picking = source } label: { label() }
            .buttonStyle(.icon(size: size, active: picking == source))
            .help(help)
            .popover(isPresented: Binding(get: { picking == source }, set: { if !$0 { picking = nil } }), arrowEdge: .top) {
                AttachPicker(source: source, repoRoot: repoRoot, sessionId: sessionId, projectId: projectId, attached: Set(attachments.compactMap(\.url))) { picked in
                    if !attachments.contains(where: { $0.url == picked.url }) { attachments.append(picked) }
                    picking = nil
                }
            }
    }
}

/// The + under the composer: files or a folder to send along.
struct AttachUploadButton: View {
    @Binding var attachments: [PromptAttachment]
    @State private var hovering = false

    var body: some View {
        Button {
            AttachmentActions.chooseFiles { attachments += $0 }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.btText : Color.btTextSecondary)
                .frame(width: 24, height: 24)
                .background(hovering ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Attach files or a folder (or paste or drop them)")
    }
}

enum AttachSource: Hashable {
    /// Every issue tracker plugin that's on (ABS-141).
    case tracker, githubIssue, pullRequest

    func placeholder(_ trackers: [ResolvedIssueTracker]) -> String {
        switch self {
        case .tracker:
            trackers.count == 1
                ? "Search \(trackers[0].title) issues, or paste \(trackers[0].declaration.keyExample)"
                : "Search issues, or paste a key or link"
        case .githubIssue: "Search issues, or #number"
        case .pullRequest: "Search pull requests, or #number"
        }
    }

    var empty: String {
        switch self {
        case .tracker: "No open issues assigned to you."
        case .githubIssue: "No open issues."
        case .pullRequest: "No open pull requests."
        }
    }

    var kind: PromptAttachment.Kind {
        switch self {
        case .tracker: .trackerIssue
        case .githubIssue: .githubIssue
        case .pullRequest: .pullRequest
        }
    }
}

/// Search, arrow to one, Return to attach it.
private struct AttachPicker: View {
    @Environment(AppModel.self) private var model
    let source: AttachSource
    let repoRoot: String?
    let sessionId: String?
    let projectId: String?
    let attached: Set<String>
    let pick: (PromptAttachment) -> Void

    private struct Item: Identifiable {
        var id: String
        var reference: String
        var title: String
        var state: String
        var stateTint: Color? = nil
        var attachment: PromptAttachment
        /// The tracker it came from, named above its first result when
        /// several trackers answer.
        var section: String? = nil
    }

    @State private var query = ""
    @State private var items: [Item] = []
    @State private var selection = 0
    @State private var loading = true
    @State private var problem: String?
    /// Trackers that couldn't be asked, each with what to do.
    @State private var trackerProblems: [String] = []
    /// The newest search; an older one still answering doesn't overwrite it.
    @State private var generation = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AttachmentGlyph(kind: source.kind, tracker: model.issueTrackers.count == 1 ? model.issueTrackers[0].pluginId : nil,
                                size: 13).foregroundStyle(Color.btTextTertiary)
                TextField(source.placeholder(model.issueTrackers), text: $query)
                    .textFieldStyle(.plain)
                    .font(BTFont.ui(13))
                    .focused($focused)
                    .onSubmit { if !loading, items.indices.contains(selection) { choose(items[selection]) } }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Hairline()
            content
        }
        .frame(width: 420)
        .onAppear { focused = true }
        .task(id: query) {
            // Typing settles before searching.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !trackerProblems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(trackerProblems, id: \.self) { line in
                    Text(line).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        if let problem {
            Text(problem)
                .font(.btCallout)
                .foregroundStyle(Color.btTextSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else if items.isEmpty {
            if trackerProblems.isEmpty || loading {
                Text(loading ? " " : query.isEmpty ? source.empty : "Nothing matches.")
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if let section = item.section {
                                Text(section)
                                    .font(BTFont.ui(11, .medium))
                                    .foregroundStyle(Color.btTextTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 4 : 10)
                                    .padding(.bottom, 4)
                            }
                            row(item, selected: index == selection).id(index)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
        }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        Button { choose(item) } label: {
            HStack(spacing: 10) {
                Text(item.reference)
                    .font(BTFont.mono(11.5))
                    .foregroundStyle(Color.btTextTertiary)
                    .frame(minWidth: 40, alignment: .leading)
                Text(item.title)
                    .font(BTFont.ui(12.5))
                    .foregroundStyle(Color.btText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if attached.contains(item.attachment.url ?? "") {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.btTextSecondary)
                } else {
                    Text(item.state).font(BTFont.ui(11))
                        .foregroundStyle(item.stateTint ?? Color.btTextTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .buttonStyle(RowButtonStyle(selected: selected, cornerRadius: 6))
        .help(item.attachment.url ?? "")
    }

    private func choose(_ item: Item) {
        guard item.attachment.kind == .trackerIssue else { pick(item.attachment); return }
        Task {
            loading = true
            pick(await model.completeTrackerIssue(item.attachment))
            loading = false
        }
    }

    private func load() async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            switch source {
            case .tracker:
                let groups = await model.searchIssueTrackers(query)
                guard mine == generation, !Task.isCancelled else { return }
                let named = groups.filter { !$0.issues.isEmpty }.count > 1
                items = groups.flatMap { group in
                    group.issues.enumerated().map { index, issue in
                        Item(id: "\(group.tracker.pluginId):\(issue.key)", reference: issue.key, title: issue.title,
                             state: issue.state ?? "",
                             attachment: issue.attachment(trackerId: group.tracker.pluginId, trackerName: group.tracker.title),
                             section: named && index == 0 ? group.tracker.title : nil)
                    }
                }
                trackerProblems = groups.compactMap(\.problem)
            case .githubIssue, .pullRequest:
                guard let repoRoot else { return }
                let executor = sessionId != nil ? model.executor(for: sessionId) : model.executor(forProject: projectId)
                switch await GitHub.access(executor) {
                case .missing: problem = "Linking GitHub needs the GitHub CLI. Install it with `brew install gh`."; return
                case .signedOut: problem = "The GitHub CLI isn't signed in. Run `gh auth login` in a terminal, then try again."; return
                case .ready: break
                }
                let found = source == .pullRequest
                    ? try await GitHub.searchPullRequests(executor, repo: repoRoot, query: query)
                    : try await GitHub.searchIssues(executor, repo: repoRoot, query: query)
                items = found.map {
                    Item(id: $0.id, reference: "#\($0.number)", title: $0.title,
                         state: $0.isDraft ? "Draft" : $0.state.capitalized,
                         stateTint: source == .pullRequest ? prStateTint($0.state, isDraft: $0.isDraft) : nil,
                         attachment: $0.attachment)
                }
            }
            problem = nil
            selection = 0
        } catch {
            items = []
            problem = error.localizedDescription
        }
    }

    private func prStateTint(_ state: String, isDraft: Bool) -> Color {
        if isDraft { return .btPullRequestDraftInk }
        switch state.uppercased() {
        case "OPEN": return .btPullRequestOpenInk
        case "MERGED": return .btPullRequestMergedInk
        case "CLOSED": return .btPullRequestClosedInk
        default: return .btTextTertiary
        }
    }
}

// MARK: - Paste and drop

extension View {
    /// Files and images dropped on the view, or pasted while `focused`, join `attachments`.
    func attachmentInput(_ attachments: Binding<[PromptAttachment]>, focused: Bool) -> some View {
        modifier(AttachmentInput(attachments: attachments, focused: focused))
    }
}

private struct AttachmentInput: ViewModifier {
    @Binding var attachments: [PromptAttachment]
    let focused: Bool
    @State private var monitor: Any?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                drop(providers)
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: Field.radius, style: .continuous)
                        .strokeBorder(Color.btFieldBorderFocused, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: focused, initial: true) { _, on in on ? install() : uninstall() }
            .onDisappear(perform: uninstall)
    }

    /// ⌘V with files or an image on the pasteboard attaches them; with text it pastes as usual.
    private func install() {
        guard monitor == nil else { return }
        let attachments = $attachments
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let pasted = AttachmentStore.importPasteboard(.general) else { return event }
            attachments.wrappedValue += pasted
            return nil
        }
    }

    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func drop(_ providers: [NSItemProvider]) {
        let attachments = $attachments
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let a = try? AttachmentStore.importFile(url) { attachments.wrappedValue.append(a) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let name = provider.suggestedName ?? "Dropped image"
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        if let a = try? AttachmentStore.importImage(data, named: name) { attachments.wrappedValue.append(a) }
                    }
                }
            }
        }
    }
}

// MARK: - Transcript

/// What went with a message you sent, under its bubble.
struct AttachmentChips: View {
    let chips: [PromptAttachments.Chip]

    var body: some View {
        FlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Button { AttachmentActions.open(chip.target) } label: {
                    HStack(spacing: 6) {
                        AttachmentGlyph(kind: chip.kind, path: chip.target?.hasPrefix("/") == true ? chip.target : nil,
                                        tracker: chip.tracker, size: 13)
                            .foregroundStyle(Color.btTextSecondary)
                        Text(chip.label)
                            .font(.btChatCaption)
                            .foregroundStyle(Color.btTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.btSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(chip.target ?? chip.label)
            }
        }
    }
}
