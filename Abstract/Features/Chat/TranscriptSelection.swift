import SwiftUI
import Textual
import AbstractCore

/// One selection across a whole transcript, the way a web page selects: a
/// drag that starts in one row and runs into others selects from where it
/// began, through every row between, to the pointer; Copy takes it all, in
/// order, rows scrolled out of view included; Select All takes the chat.
@MainActor
final class TranscriptSelection: TextSelectionGroup {
    private struct Weak { weak var member: (any TextSelectionGroupMember)? }
    private var members: [ObjectIdentifier: Weak] = [:]
    /// The text a drag began in, while it's held.
    private(set) weak var anchor: (any TextSelectionGroupMember)?
    /// The rows a spanning selection covers, first to last, and how it ends in each.
    private var span: (from: Int, to: Int)?
    private var allSelected = false
    /// Which row a member's view is in, by position in the transcript.
    var rowOf: ((NSView) -> Int?)?
    /// A row's text, for the rows between that aren't on screen.
    var textOfRow: ((Int) -> String?)?
    /// Every row's text, for Select All.
    var wholeText: (() -> String)?

    var hasSpanningSelection: Bool { span != nil || allSelected }

    func register(_ member: any TextSelectionGroupMember) {
        members[ObjectIdentifier(member)] = Weak(member: member)
        // A row coming on screen during a spanning selection takes its part.
        if allSelected { member.selectAllText() } else if let span, let row = rowOf?(member.memberView), row > span.from, row < span.to {
            member.selectAllText()
        }
    }

    func unregister(_ member: any TextSelectionGroupMember) {
        members[ObjectIdentifier(member)] = nil
    }

    func selectionBegan(in member: any TextSelectionGroupMember) {
        anchor = member
        span = nil
        allSelected = false
        for other in live where other !== member { other.clearSelection() }
    }

    func selectionEnded(in member: any TextSelectionGroupMember) {
        anchor = nil
    }

    func selectionDragged(from member: any TextSelectionGroupMember, to windowPoint: CGPoint) -> Bool {
        let ordered = self.ordered
        guard let a = ordered.firstIndex(where: { $0 === member }), let t = target(ordered, windowPoint, from: a) else { return false }
        if t == a {
            for other in ordered where other !== member { other.clearSelection() }
            span = nil
            return false
        }
        let down = t > a
        member.selectFromDragStart(toEnd: down)
        ordered[t].select(to: windowPoint, fromStart: down)
        for (i, other) in ordered.enumerated() where i != a && i != t {
            if i > min(a, t) && i < max(a, t) { other.selectAllText() } else { other.clearSelection() }
        }
        if let ra = rowOf?(member.memberView), let rt = rowOf?(ordered[t].memberView) {
            span = (min(ra, rt), max(ra, rt))
        } else {
            span = (0, 0)
        }
        return true
    }

    func copySelection() -> Bool {
        guard let text = selectedText() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// A selection that spans rows, as plain text, in order.
    func selectedText() -> String? {
        guard hasSpanningSelection else { return nil }
        let text: String
        if allSelected {
            text = wholeText?() ?? ordered.map(\.plainText).joined(separator: "\n\n")
        } else {
            // Rows on screen give what's selected in them; the rows between
            // that scrolled away give all their text.
            var byRow: [Int: [String]] = [:]
            for member in ordered {
                guard let piece = member.selectedPlainText, !piece.isEmpty else { continue }
                byRow[rowOf?(member.memberView) ?? -1, default: []].append(piece)
            }
            var parts: [String] = []
            if let span {
                for row in span.from...max(span.from, span.to) {
                    if let pieces = byRow[row] { parts += pieces } else if row > span.from, row < span.to, let whole = textOfRow?(row) { parts.append(whole) }
                }
            }
            if parts.isEmpty { parts = byRow.sorted { $0.key < $1.key }.flatMap(\.value) }
            text = parts.joined(separator: "\n\n")
        }
        return text.isEmpty ? nil : text
    }

    func selectAll() -> Bool {
        allSelected = true
        span = nil
        for member in live { member.selectAllText() }
        return true
    }

    /// The text nearest a point in empty space, where a press there starts selecting.
    func nearestText(to windowPoint: CGPoint) -> NSView? {
        func distance(_ frame: CGRect) -> CGFloat {
            let dx = max(frame.minX - windowPoint.x, 0, windowPoint.x - frame.maxX)
            let dy = max(frame.minY - windowPoint.y, 0, windowPoint.y - frame.maxY)
            // Lines above and below count for more than the side a press is on.
            return dy * 4 + dx
        }
        return ordered.min { distance($0.frameInWindow) < distance($1.frameInWindow) }?.memberView
    }

    /// Lets go of every selection.
    func clear() {
        span = nil
        allSelected = false
        for member in live { member.clearSelection() }
    }

    private var live: [any TextSelectionGroupMember] {
        members = members.filter { $0.value.member != nil }
        return members.values.compactMap(\.member)
    }

    /// Top to bottom, then left to right, as the window shows them.
    private var ordered: [any TextSelectionGroupMember] {
        live.filter { $0.memberView.window != nil }.sorted {
            let a = $0.frameInWindow, b = $1.frameInWindow
            return abs(a.maxY - b.maxY) > 1 ? a.maxY > b.maxY : a.minX < b.minX
        }
    }

    /// The text under the pointer, or the nearest one on the way toward it.
    private func target(_ ordered: [any TextSelectionGroupMember], _ point: CGPoint, from anchor: Int) -> Int? {
        guard !ordered.isEmpty else { return nil }
        let rows = ordered.enumerated().filter { $0.element.frameInWindow.minY <= point.y && point.y <= $0.element.frameInWindow.maxY }
        if let hit = rows.min(by: { abs($0.element.frameInWindow.midX - point.x) < abs($1.element.frameInWindow.midX - point.x) }) {
            return hit.offset
        }
        // Between texts: the last one above the pointer going down, the first below it going up.
        if point.y < ordered[anchor].frameInWindow.minY {
            return ordered.lastIndex { $0.frameInWindow.minY >= point.y } ?? anchor
        }
        return ordered.firstIndex { $0.frameInWindow.maxY <= point.y } ?? anchor
    }
}

/// Empty space in the transcript, beside and between its texts. A press
/// there starts a selection at the nearest text, as on a web page, so a
/// drag from the margin or a gap selects without aiming at a letter.
@MainActor
final class EmptySpacePress {
    private var pressed: NSView?

    /// False when there's no text to start from.
    func down(_ event: NSEvent, in selection: TranscriptSelection?) -> Bool {
        pressed = selection?.nearestText(to: event.locationInWindow)
        pressed?.mouseDown(with: event)
        return pressed != nil
    }

    func dragged(_ event: NSEvent) { pressed?.mouseDragged(with: event) }

    func up(_ event: NSEvent) {
        pressed?.mouseUp(with: event)
        pressed = nil
    }
}

/// Behind a row's content, so its empty space starts a selection too.
struct SelectionSurface: NSViewRepresentable {
    let selection: TranscriptSelection?

    func makeNSView(context: Context) -> SelectionSurfaceView {
        let view = SelectionSurfaceView()
        view.selection = selection
        return view
    }

    func updateNSView(_ view: SelectionSurfaceView, context: Context) {
        view.selection = selection
    }
}

final class SelectionSurfaceView: NSView {
    weak var selection: TranscriptSelection?
    private let press = EmptySpacePress()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !press.down(event, in: selection) { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) { press.dragged(event) }
    override func mouseUp(with event: NSEvent) { press.up(event) }
}
