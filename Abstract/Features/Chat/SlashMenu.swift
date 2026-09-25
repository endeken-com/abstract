import SwiftUI
import AppKit

/// One row of the `/` menu: a command, or one of a command's choices.
struct SlashItem: Identifiable {
    let id: String
    let title: String
    /// What to type after it, for an agent command that takes something.
    var hint: String? = nil
    var detail: String? = nil
    /// Command or Skill, for the agent's own.
    var tag: String? = nil
    /// Choices only: whether it's the current one.
    var checked: Bool? = nil
    let run: () -> Void
}

/// The `/` menu over the composer. The composer owns the draft, the
/// highlighted row and the keys; this draws the rows and takes clicks.
struct SlashMenu: View {
    /// The command whose choices are showing; nil while listing commands.
    let title: String?
    let items: [SlashItem]
    let selected: Int
    let hover: (Int) -> Void
    /// Where the pointer was when a row last took the highlight. Rows that
    /// scroll under a pointer that hasn't moved don't take it from the arrow keys.
    @State private var pointer = NSEvent.mouseLocation

    static let rowHeight: CGFloat = 28
    static let maxRows = 8
    static let titleHeight: CGFloat = 26

    /// Its height for `rows` rows, so the composer can set it just above the box.
    static func height(rows: Int, titled: Bool) -> CGFloat {
        CGFloat(min(rows, maxRows)) * rowHeight + 8 + (titled ? titleHeight : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.btSectionLabel)
                    .foregroundStyle(Color.btTextTertiary)
                    .padding(.horizontal, Space.md)
                    .frame(height: Self.titleHeight, alignment: .bottomLeading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, highlighted: index == selected)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { item.run() }
                                .onHover { inside in
                                    let location = NSEvent.mouseLocation
                                    guard inside, location != pointer else { return }
                                    pointer = location
                                    hover(index)
                                }
                        }
                    }
                    .padding(4)
                }
                // No system scroller: with one always shown, it takes a strip on the right.
                .btThinScrollIndicator()
                .frame(height: CGFloat(min(items.count, Self.maxRows)) * Self.rowHeight + 8)
                .onChange(of: selected) { _, index in proxy.scrollTo(index) }
            }
        }
        .background(Color.btField, in: RoundedRectangle(cornerRadius: Field.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Field.radius, style: .continuous)
                .strokeBorder(Color.btFieldBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func row(_ item: SlashItem, highlighted: Bool) -> some View {
        HStack(spacing: Space.sm) {
            if let checked = item.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.btText)
                    .opacity(checked ? 1 : 0)
            }
            Text(item.title)
                .font(BTFont.chat(13))
                .foregroundStyle(Color.btText)
                .layoutPriority(1)
            if let hint = item.hint {
                Text(hint).font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
            }
            if let detail = item.detail {
                Text(detail).font(.btChatCaption).foregroundStyle(Color.btTextSecondary).truncationMode(.tail)
            }
            Spacer(minLength: Space.sm)
            if let tag = item.tag {
                Text(tag).font(.btChatCaption).foregroundStyle(Color.btTextTertiary).layoutPriority(1)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
