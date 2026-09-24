#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import SwiftUI

// Added for Abstract (not in upstream Textual 0.5.0): a selection that runs
// across separately hosted texts, such as a chat transcript whose rows are
// each their own hosting view. A drag that starts in one text and moves over
// another hands off to the group, which selects from where it began, through
// every text between, to the point under the pointer; Copy takes all of it.

/// Coordinates one selection across many texts. Set with `textSelectionGroup`.
@MainActor
public protocol TextSelectionGroup: AnyObject {
  func register(_ member: any TextSelectionGroupMember)
  func unregister(_ member: any TextSelectionGroupMember)
  /// A click in `member`: other members let go of their selections.
  func selectionBegan(in member: any TextSelectionGroupMember)
  /// A drag from `member` reached `windowPoint`. True when the group took it
  /// (the point is over another member); false leaves it to `member`.
  func selectionDragged(from member: any TextSelectionGroupMember, to windowPoint: CGPoint) -> Bool
  func selectionEnded(in member: any TextSelectionGroupMember)
  /// Whether a selection spans members, so Copy belongs to the group.
  var hasSpanningSelection: Bool { get }
  /// Copies a selection that spans members; false when there's none.
  func copySelection() -> Bool
  /// Select All: every member. False to leave it to the member alone.
  func selectAll() -> Bool
}

/// A text taking part in a group's selection.
@MainActor
public protocol TextSelectionGroupMember: AnyObject {
  /// Where it is, in its window's coordinates.
  var frameInWindow: CGRect { get }
  /// The view drawing it, to find which row of a list it belongs to.
  var memberView: NSView { get }
  func selectAllText()
  func clearSelection()
  /// From where the drag began to this text's end (or its start).
  func selectFromDragStart(toEnd: Bool)
  /// From this text's start to the point (or from the point to its end).
  func select(to windowPoint: CGPoint, fromStart: Bool)
  /// What's selected, as plain text.
  var selectedPlainText: String? { get }
  /// All of it, as plain text.
  var plainText: String { get }
}

extension EnvironmentValues {
  @Entry public var textSelectionGroup: (any TextSelectionGroup)? = nil
}

/// Plain text (no markup) drawn and selected the way Textual's text is, so it
/// takes part in a group's selection with the rest.
public struct SelectableText: View {
  private let content: AttributedString

  public init(_ string: String) {
    content = AttributedString(string)
  }

  public var body: some View {
    TextFragment(content)
      .modifier(TextSelectionInteraction())
      .coordinateSpace(.textContainer)
      .textual.textSelection(.enabled)
  }
}

/// Lines drawn one text each (one text of many lines lays out in time that
/// grows much faster than its length) but selected as one block.
public struct SelectableLines: View {
  private let lines: [AttributedString]
  private let spacing: CGFloat

  public init(_ lines: [String], spacing: CGFloat = 0) {
    self.lines = lines.map { AttributedString($0.isEmpty ? " " : $0) }
    self.spacing = spacing
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(lines.indices, id: \.self) { i in
        TextFragment(lines[i]).fixedSize(horizontal: false, vertical: true)
      }
    }
    .modifier(TextSelectionInteraction())
    .coordinateSpace(.textContainer)
    .textual.textSelection(.enabled)
  }
}
#endif
