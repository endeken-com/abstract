import SwiftUI
import AppKit
import BacktickCore

/// The selected file: a header with file-level actions, then its hunks.
struct DiffFilePane: View {
    let review: DiffReview
    let file: ReviewFile
    let layout: DiffLayout
    let context: DiffContext

    /// Past this many rows a file waits for a click before it renders.
    private static let largeFileRows = 6_000

    var body: some View {
        VStack(spacing: 0) {
            DiffFileHeader(review: review, file: file, context: context)
            if file.diff.isBinary {
                EmptyStateView(symbol: "doc.zipper", title: "Binary file",
                               message: "Backtick can't show a diff for this one — review it in Finder.",
                               action: ("Reveal in Finder", reveal))
            } else if file.hunks.isEmpty {
                EmptyStateView(symbol: file.diff.status == .renamed ? "arrow.right.doc.on.clipboard" : "doc",
                               title: emptyTitle, message: emptyMessage)
            } else if file.unified.count > Self.largeFileRows, !review.revealedLargeFiles.contains(file.path) {
                EmptyStateView(symbol: "text.alignleft", title: "Large diff",
                               message: "\(file.lineCount.formatted()) lines changed in this file.",
                               action: ("Show Diff", { review.revealedLargeFiles.insert(file.path) }))
            } else {
                DiffLinesView(review: review, file: file, layout: layout, context: context)
                    .id("\(file.path)|\(layout.rawValue)")
            }
        }
        .background(Color.btCanvas)
    }

    private var emptyTitle: String {
        switch file.diff.status {
        case .renamed: "Renamed without changes"
        case .added: "Empty file"
        case .deleted: "Empty file deleted"
        case .modified: "Only file metadata changed"
        }
    }

    private var emptyMessage: String {
        if file.diff.status == .renamed, let old = file.diff.oldPath { return "\(old) → \(file.path)" }
        return "There are no lines to show for \(file.name)."
    }

    private func reveal() {
        let path = DiffReview.join(context.worktree, file.path)
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}

// MARK: - File header

private struct DiffFileHeader: View {
    @Environment(AppModel.self) private var model
    let review: DiffReview
    let file: ReviewFile
    let context: DiffContext

    var body: some View {
        let working = review.isWorking(on: "file:\(file.path)")
        HStack(spacing: Space.sm) {
            DiffStatusLetter(status: file.diff.status, size: 12)
            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory + "/")
                        .foregroundStyle(Color.btTextTertiary)
                        .truncationMode(.head)
                }
                Text(file.name)
                    .foregroundStyle(Color.btText)
                    .layoutPriority(1)
            }
            .font(.btMono)
            .lineLimit(1)
            .textSelection(.enabled)
            .help(file.path)
            Text(statusText)
                .font(.btCaption)
                .foregroundStyle(Color.btTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.md)
            if working {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else if review.isAccepted(file) {
                DiffAcceptedLabel()
            } else if review.isPartlyAccepted(file) {
                DiffAcceptedLabel(partly: true)
            }
            if !file.diff.isBinary {
                DiffCounts(additions: file.diff.additions, deletions: file.diff.deletions)
                    .padding(.horizontal, Space.xs)
            }
            Button("Reject") { Task { await review.rejectFile(file, context, model: model) } }
                .buttonStyle(.bt(.danger, size: .small))
                .help(rejectHelp)
            Button(review.isAccepted(file) ? "Accepted" : "Accept") {
                Task { await review.acceptFile(file, context, model: model) }
            }
            .buttonStyle(.bt(.primary, size: .small))
            .disabled(review.isAccepted(file))
            .help("Apply this file's changes to \(context.projectName)'s main working tree")
        }
        .disabled(review.isWorking)
        .padding(.leading, Space.lg)
        .padding(.trailing, Space.md)
        .frame(height: 44)
        .background(Color.btCanvas)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var statusText: String {
        if file.diff.status == .renamed, let old = file.diff.oldPath { return "Renamed from \(old)" }
        return file.diff.status.word
    }

    private var rejectHelp: String {
        switch file.diff.status {
        case .added: "Delete this new file from the agent's worktree"
        case .deleted: "Restore this file in the agent's worktree"
        default: "Undo the agent's changes to this file in its worktree"
        }
    }
}

// MARK: - Lines

/// Measurements shared by every row of one file, computed once per layout pass.
struct DiffMetrics {
    static let rowHeight: CGFloat = 20
    static let markerWidth: CGFloat = 18
    static let charWidth: CGFloat = measure(size: 12)
    static let smallCharWidth: CGFloat = measure(size: 11)

    let gutter: CGFloat
    let viewport: CGFloat
    let contentWidth: CGFloat
    let half: CGFloat

    init(file: ReviewFile, viewport: CGFloat, layout: DiffLayout) {
        self.viewport = viewport
        gutter = CGFloat(file.numberDigits) * Self.smallCharWidth + 18
        let text = CGFloat(file.maxColumns) * Self.charWidth + 40
        switch layout {
        case .unified:
            half = 0
            contentWidth = max(viewport, gutter * 2 + Self.markerWidth + text)
        case .split:
            // Split fits the pane and wraps long lines; scrolling both
            // halves sideways together would push the new side off-screen.
            half = max(((viewport - 0.5) / 2).rounded(.down), gutter + Self.markerWidth + 120)
            contentWidth = half * 2 + 0.5
        }
    }

    private static func measure(size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }
}

private struct DiffLinesView: View {
    let review: DiffReview
    let file: ReviewFile
    let layout: DiffLayout
    let context: DiffContext

    var body: some View {
        GeometryReader { geo in
            let metrics = DiffMetrics(file: file, viewport: geo.size.width, layout: layout)
            ScrollView(layout == .split ? .vertical : [.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(layout == .split ? file.split : file.unified) { row in
                        switch row.content {
                        case .hunk(let position):
                            DiffHunkHeader(review: review, file: file, hunk: file.hunks[position], context: context,
                                           metrics: metrics, isFirst: position == 0)
                        case .line(let line):
                            DiffUnifiedLine(line: line, metrics: metrics)
                        case .pair(let left, let right):
                            DiffSplitLine(left: left, right: right, metrics: metrics)
                        }
                    }
                }
                .frame(width: metrics.contentWidth, alignment: .leading)
                .padding(.bottom, Space.xl)
                // A short diff sits at the top instead of floating mid-pane.
                .frame(minHeight: geo.size.height, alignment: .top)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading)
        }
    }
}

private struct DiffHunkHeader: View {
    @Environment(AppModel.self) private var model
    let review: DiffReview
    let file: ReviewFile
    let hunk: ReviewHunk
    let context: DiffContext
    let metrics: DiffMetrics
    let isFirst: Bool
    @State private var hovering = false

    var body: some View {
        let accepted = review.isAccepted(hunk)
        let working = review.isWorking(on: "hunk:\(hunk.fingerprint)")
        HStack(spacing: Space.sm) {
            Text(hunk.range)
                .foregroundStyle(Color.btTextTertiary)
            if !hunk.section.isEmpty {
                Text(hunk.section)
                    .foregroundStyle(Color.btTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Space.md)
            if working {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else if accepted {
                DiffAcceptedLabel()
            }
            if file.allowsHunkActions {
                HStack(spacing: 6) {
                    Button("Reject") { Task { await review.rejectHunk(hunk, in: file, context, model: model) } }
                        .buttonStyle(.bt(.danger, size: .small))
                        .help("Undo this change in the agent's worktree")
                    Button("Accept") { Task { await review.acceptHunk(hunk, in: file, context, model: model) } }
                        .buttonStyle(.bt(.secondary, size: .small))
                        .disabled(accepted)
                        .help("Apply just this change to the main working tree")
                }
                .font(.btCallout)
                .disabled(review.isWorking)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
        .font(.btMonoSmall)
        .padding(.leading, Space.md)
        .padding(.trailing, Space.md)
        .frame(width: metrics.viewport, height: 34)
        .frame(width: metrics.contentWidth, alignment: .leading)
        .overlay(alignment: .top) { if !isFirst { Hairline() } }
        .padding(.top, isFirst ? Space.xs : Space.lg)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
    }
}

private struct DiffUnifiedLine: View {
    let line: NumberedLine
    let metrics: DiffMetrics

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(line.old).frame(width: metrics.gutter - 8, alignment: .trailing).padding(.trailing, 8)
                Text(line.new).frame(width: metrics.gutter - 8, alignment: .trailing).padding(.trailing, 8)
            }
            .font(.btMonoSmall)
            .foregroundStyle(line.kind == .context ? Color.btTextTertiary : DiffStyle.number(line.kind))
            .background(DiffStyle.gutter(line.kind))
            DiffLineText(line: line)
        }
        .frame(width: metrics.contentWidth, height: DiffMetrics.rowHeight, alignment: .leading)
        .background(DiffStyle.wash(line.kind))
    }
}

private struct DiffSplitLine: View {
    let left: NumberedLine?
    let right: NumberedLine?
    let metrics: DiffMetrics

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DiffSplitCell(line: left, number: left?.old ?? "", metrics: metrics)
            Rectangle().fill(Color.btBorder).frame(width: 0.5).frame(maxHeight: .infinity)
            DiffSplitCell(line: right, number: right?.new ?? "", metrics: metrics)
        }
        // Both halves take the taller one's height, so washes line up.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: metrics.contentWidth, alignment: .leading)
    }
}

private struct DiffSplitCell: View {
    let line: NumberedLine?
    let number: String
    let metrics: DiffMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let line {
                Text(number)
                    .font(.btMonoSmall)
                    .foregroundStyle(line.kind == .context ? Color.btTextTertiary : DiffStyle.number(line.kind))
                    .frame(width: metrics.gutter - 8, alignment: .trailing)
                    .padding(.trailing, 8)
                DiffLineText(line: line, wraps: true)
            }
        }
        .padding(.vertical, 2.5)
        .frame(width: metrics.half, alignment: .topLeading)
        .frame(minHeight: DiffMetrics.rowHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .leading) {
            if let line { DiffStyle.gutter(line.kind).frame(width: metrics.gutter) }
        }
        .background(line.map { DiffStyle.wash($0.kind) } ?? Color.btHover)
    }
}

/// Marker and content of one line. Unified lines stay on one line and scroll
/// sideways; split lines wrap inside their half.
private struct DiffLineText: View {
    let line: NumberedLine
    var wraps = false

    var body: some View {
        if line.kind == .note {
            Text(line.text)
                .font(.btCaption)
                .italic()
                .foregroundStyle(Color.btTextTertiary)
                .padding(.leading, DiffMetrics.markerWidth)
                .fixedSize()
        } else {
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : "")
                .font(.btMono)
                .foregroundStyle(line.kind == .added ? Color.btAdded : Color.btRemoved)
                .frame(width: DiffMetrics.markerWidth)
            if wraps {
                Text(line.text)
                    .font(.btMono)
                    .foregroundStyle(line.kind == .context ? Color.btTextSecondary : Color.btText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, Space.md)
            } else {
                Text(line.text)
                    .font(.btMono)
                    .foregroundStyle(line.kind == .context ? Color.btTextSecondary : Color.btText)
                    .fixedSize()
            }
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
