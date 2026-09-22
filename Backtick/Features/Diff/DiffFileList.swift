import SwiftUI
import BacktickCore

/// Changed files grouped by directory. Up/down arrows move the selection.
struct DiffFileList: View {
    let review: DiffReview
    let projectName: String
    let nestedRepos: [String]
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(review.groups) { group in
                        DiffGroupHeader(title: group.directory.isEmpty ? projectName : group.directory,
                                        isRoot: group.directory.isEmpty)
                            .padding(.top, group.id == review.groups.first?.id ? 0 : Space.sm)
                        ForEach(group.files) { file in
                            DiffFileRow(file: file,
                                        selected: review.selectedPath == file.path,
                                        accepted: review.isAccepted(file),
                                        partlyAccepted: review.isPartlyAccepted(file)) {
                                review.selectedPath = file.path
                                focused = true
                            }
                            .id(file.path)
                        }
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
            }
            .scrollIndicators(.automatic)
            .onChange(of: review.selectedPath) { _, path in
                guard let path else { return }
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(path) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !nestedRepos.isEmpty {
                Notice(text: "\(nestedRepos.count == 1 ? "A nested repository isn't" : "\(nestedRepos.count) nested repositories aren't") included: \(nestedRepos.prefix(3).joined(separator: ", "))\(nestedRepos.count > 3 ? "…" : "").")
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                    .background(Color.btCanvas)
                    .overlay(alignment: .top) { Hairline() }
            }
        }
        .background(Color.btCanvas)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { review.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { review.moveSelection(1); return .handled }
        .onAppear { focused = true }
    }
}

private struct DiffGroupHeader: View {
    let title: String
    let isRoot: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isRoot ? "shippingbox" : "folder")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.btTextTertiary)
                .frame(width: 17)
            Text(title)
                .font(.btCaptionMedium)
                .foregroundStyle(Color.btTextSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(title)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: 26)
    }
}

private struct DiffFileRow: View {
    let file: ReviewFile
    let selected: Bool
    let accepted: Bool
    let partlyAccepted: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.sm) {
                DiffStatusLetter(status: file.diff.status)
                Text(file.name)
                    .font(.btBodyMedium)
                    .foregroundStyle(file.diff.status == .deleted ? Color.btTextSecondary : Color.btText)
                    .strikethrough(file.diff.status == .deleted, color: Color.btTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if accepted || partlyAccepted {
                    Image(systemName: accepted ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.btAdded)
                        .help(accepted ? "Accepted into the main working tree" : "Some changes accepted")
                }
                Spacer(minLength: Space.xs)
                if file.diff.isBinary {
                    Text("bin").font(.btMonoSmall).foregroundStyle(Color.btTextTertiary)
                } else {
                    DiffCounts(additions: file.diff.additions, deletions: file.diff.deletions, hideZeros: true)
                }
            }
            .padding(.leading, Space.lg)
            .padding(.trailing, Space.sm)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected))
        .help(file.path)
    }
}
