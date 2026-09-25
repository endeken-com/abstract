import SwiftUI
import AppKit
import AbstractCore

/// Every changed file, one after another: each header stays in view (pinned
/// while its lines scroll by) and opens or closes the file's diff. Lines are
/// syntax coloured, and any line takes a comment for the agent.
struct DiffFileSections: View {
    let review: DiffReview
    let context: DiffContext
    let layout: DiffLayout
    let width: CGFloat
    let onDiscard: (ReviewFile) -> Void
    @State private var highlights = DiffHighlights()
    @State private var drafting = CommentDrafting()

    var body: some View {
        let metrics = DiffMetrics(files: review.files, width: width, layout: layout)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(review.orderedFiles) { file in
                        Section {
                            if review.isExpanded(file) {
                                DiffFileBody(review: review, file: file, layout: layout, context: context,
                                             metrics: metrics, highlights: highlights)
                            }
                        } header: {
                            DiffFileHeader(review: review, file: file, context: context, onDiscard: { onDiscard(file) })
                        }
                        .id(file.path)
                    }
                    if !review.commits.isEmpty { ReviewCommits(review: review, context: context) }
                }
                .padding(.bottom, Space.xl)
                .textSelection(.enabled)
            }
            .environment(\.commentDrafting, drafting)
            // "Show in Changes" from a tool row or the Files pane.
            .onChange(of: review.focusToken) {
                guard let path = review.focusPath else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(path, anchor: .top) }
            }
        }
    }
}

// MARK: - File header

private struct DiffFileHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.worktreeIsRemote) private var remote
    let review: DiffReview
    let file: ReviewFile
    let context: DiffContext
    let onDiscard: () -> Void
    @State private var hovering = false

    /// Paseo's file header: the name, its folder quieter, then the counts and
    /// what happened to the file. Actions are on right-click.
    var body: some View {
        let working = review.isWorking(on: "file:\(file.path)")
        let expanded = review.isExpanded(file)
        let comments = model.comments(context.sessionId).count { $0.ref.path == file.path }
        Button { withAnimation(.snappy(duration: 0.2)) { review.toggle(file) } } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.btTextTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                fileName
                Spacer(minLength: Space.sm)
                if comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble")
                        .labelStyle(.titleAndIcon)
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextSecondary)
                        .fixedSize()
                        .help("\(comments) comment\(comments == 1 ? "" : "s") on this file")
                }
                if working {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if review.isAccepted(file) {
                    DiffAcceptedLabel()
                }
                if !file.diff.isBinary {
                    DiffCounts(additions: file.diff.additions, deletions: file.diff.deletions, hideZeros: true, compact: true).fixedSize()
                }
                DiffStatusIcon(status: file.diff.status)
            }
            .padding(.leading, Space.md)
            .padding(.trailing, Space.md)
            .frame(height: 30)
            .background(hovering ? Color.btHover : .clear)
            .background(Color.btCanvas)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Hairline() }
        .onHover { hovering = $0 }
        .help(file.diff.status == .renamed ? "Renamed from \(file.diff.oldPath ?? "")" : file.path)
        .contextMenu {
            Button("Open in Files") { model.openFile(file.path, in: context.sessionId) }
            Button("Copy Path") { copy(DiffReview.join(context.worktree, file.path)) }
            Button("Copy Relative Path") { copy(file.path) }
            if !remote { Button("Reveal in Finder") { reveal() } }
            Divider()
            Button("Apply to \(context.projectName)") { Task { await review.acceptFile(file, context, model: model) } }
                .disabled(review.isAccepted(file) || review.isWorking)
            if review.mode == .uncommitted {
                Button("Discard Changes…", role: .destructive, action: onDiscard)
                    .disabled(review.isWorking)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var fileName: some View {
        HStack(spacing: 4) {
            FileIcon(path: file.path).padding(.trailing, 2)
            Text(file.name)
                .font(BTFont.ui(13))
                .foregroundStyle(Color.btText)
                .layoutPriority(1)
            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(BTFont.ui(12))
                    .foregroundStyle(hovering ? Color.btTextSecondary : Color.btTextTertiary)
                    .truncationMode(.head)
            }
        }
        .lineLimit(1)
    }

    private func reveal() {
        let path = DiffReview.join(context.worktree, file.path)
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: path) ? url : url.deletingLastPathComponent()])
    }
}

// MARK: - File body

private struct DiffFileBody: View {
    let review: DiffReview
    let file: ReviewFile
    let layout: DiffLayout
    let context: DiffContext
    let metrics: DiffMetrics
    let highlights: DiffHighlights

    /// Past this many rows a file waits for a click before it renders.
    private static let largeFileRows = 6_000

    var body: some View {
        if file.diff.isBinary {
            DiffNote(text: "Binary file — review it in Finder.")
        } else if file.hunks.isEmpty {
            DiffNote(text: emptyText)
        } else if file.unified.count > Self.largeFileRows, !review.revealedLargeFiles.contains(file.path) {
            DiffNote(text: "\(file.lineCount.formatted()) lines changed.", action: ("Show Diff", { review.revealedLargeFiles.insert(file.path) }))
        } else {
            ForEach(layout == .split ? file.split : file.unified) { row in
                switch row.content {
                case .hunk(let position):
                    DiffHunkHeader(hunk: file.hunks[position], isFirst: position == 0)
                case .line(let line):
                    DiffUnifiedLine(file: file, line: line, metrics: metrics, sessionId: context.sessionId,
                                    code: highlights.line(file, line), source: review.mode.source)
                case .pair(let left, let right):
                    DiffSplitLine(file: file, left: left, right: right, metrics: metrics, sessionId: context.sessionId,
                                  highlights: highlights, source: review.mode.source)
                }
            }
            Color.clear.frame(height: Space.md)
                .task(id: file.id) { await highlights.load(file) }
        }
    }

    private var emptyText: String {
        switch file.diff.status {
        case .renamed: "Renamed without changes" + (file.diff.oldPath.map { ", from \($0)" } ?? "")
        case .added: "Empty file"
        case .deleted: "Empty file deleted"
        case .modified: "Only file metadata changed"
        }
    }
}

/// A quiet line in place of a diff that can't or needn't be drawn.
private struct DiffNote: View {
    let text: String
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(text).font(.btCallout).foregroundStyle(Color.btTextSecondary)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.bt(.ghost, size: .small))
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}

// MARK: - Lines

/// Measurements shared by every row, from the widest line number.
struct DiffMetrics {
    static let rowHeight: CGFloat = 20
    static let markerWidth: CGFloat = 16
    static let smallCharWidth: CGFloat = measure(size: 11)

    let gutter: CGFloat
    let half: CGFloat

    init(files: [ReviewFile], width: CGFloat, layout: DiffLayout) {
        let digits = files.map(\.numberDigits).max() ?? 3
        gutter = CGFloat(digits) * Self.smallCharWidth + 16
        half = layout == .split ? max(((width - 0.5) / 2).rounded(.down), 200) : 0
    }

    private static func measure(size: CGFloat) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: BTFont.nsMono(size)]).width
    }
}

/// Where a hunk starts, as its enclosing function or section; muted, with
/// no buttons: a hunk is read, not acted on.
private struct DiffHunkHeader: View {
    let hunk: ReviewHunk
    let isFirst: Bool

    var body: some View {
        Text(hunk.section.isEmpty ? hunk.range : hunk.section)
            .font(.btMonoSmall)
            .foregroundStyle(Color.btTextTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Space.md)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(Color.btHover)
            .padding(.top, isFirst ? 0 : Space.xs)
    }
}

extension NumberedLine {
    /// The line a comment on this row is about; nil for notes.
    nonisolated func ref(in file: ReviewFile) -> LineRef? {
        switch kind {
        case .removed: Int(old).map { LineRef(path: file.path, line: $0, side: .old) }
        case .added, .context: Int(new).map { LineRef(path: file.path, line: $0, side: .new) }
        case .note: nil
        }
    }
}

/// One line in one column, as Paseo draws it: a single gutter (the old
/// number for a removed line, the new one otherwise), the line washed green
/// or red, no +/− marks. Hovering the gutter offers a comment.
private struct DiffUnifiedLine: View {
    @Environment(\.commentDrafting) private var drafting
    let file: ReviewFile
    let line: NumberedLine
    let metrics: DiffMetrics
    let sessionId: String
    let code: AttributedString?
    let source: String
    @State private var hovering = false

    var body: some View {
        let ref = line.ref(in: file)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text(line.kind == .removed ? line.old : line.new)
                    .font(.btMonoSmall)
                    .foregroundStyle(DiffStyle.number(line.kind))
                    .frame(width: metrics.gutter - 7, alignment: .trailing)
                    .padding(.trailing, 7)
                    .frame(height: DiffMetrics.rowHeight)
                    .overlay(alignment: .trailing) {
                        if hovering, let ref {
                            AddCommentButton { drafting?.ref = ref }.offset(x: 4)
                        }
                    }
                DiffLineText(line: line, code: code)
                    .padding(.leading, 8)
            }
            .frame(minHeight: DiffMetrics.rowHeight, alignment: .topLeading)
            .background(DiffStyle.wash(line.kind))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            if let ref {
                LineCommentThread(sessionId: sessionId, ref: ref, code: line.text,
                                  context: { file.context(for: ref) }, source: source)
                    .padding(.leading, metrics.gutter)
                RevundInlineFindings(sessionId: sessionId, ref: ref)
                    .padding(.leading, metrics.gutter)
            }
        }
    }
}

private struct DiffSplitLine: View {
    let file: ReviewFile
    let left: NumberedLine?
    let right: NumberedLine?
    let metrics: DiffMetrics
    let sessionId: String
    let highlights: DiffHighlights
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                DiffSplitCell(file: file, line: left, number: left?.old ?? "", metrics: metrics,
                              code: left.flatMap { highlights.line(file, $0) })
                Rectangle().fill(Color.btBorder).frame(width: 0.5).frame(maxHeight: .infinity)
                DiffSplitCell(file: file, line: right, number: right?.new ?? "", metrics: metrics,
                              code: right.flatMap { highlights.line(file, $0) })
            }
            // Both halves take the taller one's height, so washes line up.
            .fixedSize(horizontal: false, vertical: true)
            // An unchanged line shows on both sides; its comments show once.
            ForEach(Array(Set([left, right].compactMap { $0?.ref(in: file) })), id: \.self) { ref in
                LineCommentThread(sessionId: sessionId, ref: ref,
                                  code: (ref.side == .old ? left : right)?.text ?? "",
                                  context: { file.context(for: ref) }, source: source)
                    .padding(.leading, ref.side == .old ? metrics.gutter : metrics.half + metrics.gutter)
                RevundInlineFindings(sessionId: sessionId, ref: ref)
                    .padding(.leading, metrics.half + metrics.gutter)
            }
        }
    }
}

private struct DiffSplitCell: View {
    @Environment(\.commentDrafting) private var drafting
    let file: ReviewFile
    let line: NumberedLine?
    let number: String
    let metrics: DiffMetrics
    let code: AttributedString?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let line {
                Text(number)
                    .font(.btMonoSmall)
                    .foregroundStyle(DiffStyle.number(line.kind))
                    .frame(width: metrics.gutter - 8, height: DiffMetrics.rowHeight, alignment: .trailing)
                    .padding(.trailing, 8)
                    .overlay(alignment: .trailing) {
                        if hovering, let ref = line.ref(in: file) {
                            AddCommentButton { drafting?.ref = ref }.offset(x: 4)
                        }
                    }
                DiffLineText(line: line, code: code).padding(.leading, 8)
            }
        }
        .frame(width: metrics.half, alignment: .topLeading)
        .frame(minHeight: DiffMetrics.rowHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            if let line { DiffStyle.gutter(line.kind).frame(width: metrics.gutter) }
        }
        .background(line.map { DiffStyle.wash($0.kind) } ?? Color.btHover)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A line's content, wrapping inside the pane; its colour says whether it was added or removed. Syntax colour
/// arrives a moment after the line; unchanged lines sit a step back.
private struct DiffLineText: View {
    let line: NumberedLine
    let code: AttributedString?

    var body: some View {
        if line.kind == .note {
            Text(line.text)
                .font(.btCaption)
                .italic()
                .foregroundStyle(Color.btTextTertiary)
                .padding(.leading, DiffMetrics.markerWidth)
                .frame(height: DiffMetrics.rowHeight)
        } else {
            Text(code ?? AttributedString(line.text))
                .font(.btMono)
                .foregroundStyle(line.kind == .context ? Color.btTextSecondary : Color.btText)
                .opacity(line.kind == .context && code != nil ? 0.78 : 1)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1.5)
                .padding(.trailing, Space.md)
        }
    }
}

enum DiffStyle {
    static func wash(_ kind: NumberedLine.Kind) -> Color {
        switch kind {
        case .added: .btAddedWash
        case .removed: .btRemovedWash
        case .context, .note: .clear
        }
    }

    /// The gutter doubles the wash, so changed lines read at a glance.
    static func gutter(_ kind: NumberedLine.Kind) -> Color { wash(kind) }

    static func number(_ kind: NumberedLine.Kind) -> Color {
        switch kind {
        case .added: .btAdded
        case .removed: .btRemoved
        case .context, .note: .btTextTertiary
        }
    }
}

// MARK: - Syntax colour

/// Each file's lines coloured once, a hunk at a time so a comment or string
/// that spans lines reads right. The old side colours removed lines; the new
/// side colours added and unchanged ones.
@Observable
final class DiffHighlights {
    private struct LineKey: Hashable {
        let kind: NumberedLine.Kind
        let old: String
        let new: String
    }

    private var byFile: [String: (signature: [String], lines: [LineKey: AttributedString])] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    func line(_ file: ReviewFile, _ line: NumberedLine) -> AttributedString? {
        byFile[file.path]?.lines[LineKey(kind: line.kind, old: line.old, new: line.new)]
    }

    func load(_ file: ReviewFile) async {
        let signature = file.hunks.map(\.fingerprint)
        guard byFile[file.path]?.signature != signature, !loading.contains(file.path),
              file.lineCount <= 20_000, let language = CodeHighlighter.language(for: file.path) else { return }
        loading.insert(file.path)
        defer { loading.remove(file.path) }

        var lines: [LineKey: AttributedString] = [:]
        var hunk: [NumberedLine] = []
        /// Colours one side of a hunk (its unchanged lines give the grammar
        /// context) and keeps the lines of `kinds`.
        func colour(_ side: [NumberedLine], keeping kinds: Set<NumberedLine.Kind>) async {
            guard side.contains(where: { kinds.contains($0.kind) }),
                  let tokens = await CodeHighlighter.shared.lines(side.map(\.text).joined(separator: "\n"), language: language)
            else { return }
            for (line, tokens) in zip(side, tokens) where kinds.contains(line.kind) {
                lines[LineKey(kind: line.kind, old: line.old, new: line.new)] = SyntaxStyle.attributed(tokens)
            }
        }
        func flush() async {
            await colour(hunk.filter { $0.kind != .added && $0.kind != .note }, keeping: [.removed])
            await colour(hunk.filter { $0.kind != .removed && $0.kind != .note }, keeping: [.context, .added])
            hunk.removeAll()
        }
        for row in file.unified {
            switch row.content {
            case .hunk: await flush()
            case .line(let line): hunk.append(line)
            case .pair: break
            }
        }
        await flush()
        byFile[file.path] = (signature, lines)
    }
}

// MARK: - Commits

/// The branch's commits under the diff, as in Paseo; one click shows a commit's changes.
private struct ReviewCommits: View {
    let review: DiffReview
    let context: DiffContext
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.btTextTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text("Commits").font(BTFont.ui(13)).foregroundStyle(Color.btText)
                    Text("\(review.commits.count)").font(.btCaption).foregroundStyle(Color.btTextTertiary).monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, Space.md)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(review.commits) { commit in
                    Button { Task { await review.show(.commit(commit), context) } } label: {
                        HStack(spacing: Space.sm) {
                            Text(commit.subject).font(BTFont.ui(12.5)).foregroundStyle(Color.btProse).lineLimit(1)
                            Spacer(minLength: Space.sm)
                            Text(commit.shortSha).font(.btMonoSmall).foregroundStyle(Color.btTextTertiary).fixedSize()
                            if let date = commit.date {
                                Text(RelativeTime.short(date)).font(.btCaption).foregroundStyle(Color.btTextTertiary).monospacedDigit().fixedSize()
                            }
                        }
                        .padding(.leading, Space.md + 10 + Space.sm)
                        .padding(.trailing, Space.md)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(commit.author)
                }
            }
        }
        .padding(.top, Space.md)
        .overlay(alignment: .top) { Hairline() }
    }
}

extension ReviewMode {
    /// How a review attachment names what was compared.
    var source: String {
        switch self {
        case .uncommitted: "uncommitted"
        case .committed: "committed"
        case .commit(let c): "commit \(c.shortSha)"
        }
    }
}

extension ReviewFile {
    /// The commented line with up to three lines either side, within its hunk.
    nonisolated func context(for ref: LineRef) -> ReviewLineContext? {
        guard let target = unified.firstIndex(where: { if case .line(let line) = $0.content { line.ref(in: self) == ref } else { false } })
        else { return nil }
        let header = unified[..<target].lastIndex { if case .hunk = $0.content { true } else { false } }
        let hunkStart = header.map { $0 + 1 } ?? 0
        var hunkIndex = 0
        if let header, case .hunk(let position) = unified[header].content { hunkIndex = position }
        var hunkEnd = unified.count
        if let next = unified[(target + 1)...].firstIndex(where: { if case .hunk = $0.content { true } else { false } }) { hunkEnd = next }
        let lo = max(hunkStart, target - 3), hi = min(hunkEnd - 1, target + 3)
        let lines: [ReviewLineContext.Line] = (lo...hi).compactMap { i in
            guard case .line(let line) = unified[i].content, line.kind != .note else { return nil }
            return .init(old: Int(line.old), new: Int(line.new), kind: line.kind, text: line.text, isTarget: i == target)
        }
        guard hunks.indices.contains(hunkIndex) else { return ReviewLineContext(hunkHeader: "", lines: lines) }
        let hunk = hunks[hunkIndex]
        return ReviewLineContext(hunkHeader: hunk.section.isEmpty ? hunk.range : hunk.range + " " + hunk.section, lines: lines)
    }
}
