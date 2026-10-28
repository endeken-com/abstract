import SwiftUI
import AppKit
import Textual
import AbstractCore

/// What every row of a transcript needs from the chat around it.
struct TranscriptContext: Equatable {
    var sessionId: String
    var working: Bool
    var approvals: [String: PendingPermission]
    var latestTodoCallId: String?
    var prose: ProseStyle
    var transcript: TranscriptMode
}

/// A chat's transcript as an AppKit list of SwiftUI rows. Each row has its
/// own hosting view, so a row that changes (the reply streaming in, a tool
/// call finishing, a row you expand) lays out alone instead of the whole
/// transcript re-measuring with it; only rows near the visible part exist;
/// and heights are measured once and kept. The list follows the end while
/// you're there and stays put while you read further up.
///
/// The approach is Paseo's virtualized agent stream (Apache-2.0, Copyright
/// (c) 2025-present Mohamed Boudra), built on AppKit.
struct TranscriptList<Footer: View>: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let feed: ChatFeed
    let context: TranscriptContext
    /// Asks the list to go to the end and follow it; changes on each request.
    let jump: Int
    @Binding var atBottom: Bool
    @ViewBuilder let footer: () -> Footer

    func makeCoordinator() -> TranscriptController { TranscriptController(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onBottomChange = { near in if atBottom != near { atBottom = near } }
        c.update(feed: feed, context: self.context, footer: AnyView(footer()), jump: jump)
    }
}

/// Runs a `TranscriptList`: which rows exist, where they sit, and the scroll.
///
/// Heights are exact and known before a row is drawn: a row is measured
/// where it's placed, from its content, and anything that changes a row's
/// size is a change the list hears of (new content, or something opened or
/// closed through the chat's `TranscriptExpansion`), so it re-measures and
/// places the rows again in the same pass: nothing overlaps, nothing leaves
/// a gap. Rows not yet shown are measured in idle moments, nearest first,
/// and heights are kept with the chat, so opening it again is instant and
/// the scroll never jumps. A chat opens out of sight until its first layout
/// settles, then fades in.
@MainActor
final class TranscriptController: NSObject {
    struct Item: Hashable {
        let row: ChatRow
        let gap: CGFloat
        let live: Bool
        /// Approvals waiting on this row's calls, and whether it holds the newest
        /// checklist: what it takes from the chat, so a change elsewhere leaves it be.
        let approvals: [String: PendingPermission]
        let latestTodo: Bool
        /// Bumped whenever something in it opens or closes.
        let version: Int
        var id: Int { row.id }
    }

    let scrollView = NSScrollView()
    private let document = TranscriptDocumentView()
    private let model: AppModel
    private weak var feed: ChatFeed?
    private var context: TranscriptContext?
    private var items: [Item] = []
    private var index: [Int: Int] = [:]
    private var historyRevision = -1
    /// Measured heights at `measuredWidth`, by row id.
    private var heights: [Int: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var versions: [Int: Int] = [:]
    private var mounted: [Int: RowHost] = [:]
    /// Rows scrolled out of range, kept a while so scrolling back is instant.
    private var parked: [Int: RowHost] = [:]
    private var parkedOrder: [Int] = []
    private let footerHost: RowHost
    /// Measures rows that aren't shown, off screen.
    private let measurer: RowHost
    private var footerView = AnyView(EmptyView())
    private var jump = 0
    /// Whether the list follows its end: only the reader's scrolling changes it.
    private var follow = TranscriptFollow()
    private var scrollingByCode = false
    /// While laying out, the view may be clamped or scrolled by the list
    /// itself: bounds changes then are not the reader scrolling.
    private var layingOut = false
    /// The view's top at the last bounds change, so a change that only
    /// resizes the view doesn't read as the reader scrolling.
    private var lastOriginY: CGFloat = 0
    private var didInitialScroll = false
    private var relayoutScheduled = false
    /// The rows around the view at the last layout, by position.
    private var shownRange = 0..<0
    // Opening: out of sight until the layout stops changing.
    private var revealed = false
    private var revealStarted: Date?
    private var settleScheduled = false
    private var changedSinceCheck = false
    private var premeasuring: Task<Void, Never>?
    private var premeasureRange = 0..<0
    private var premeasureCount = -1
    private var premeasureAbove = -1
    private var premeasureBelow = 0
    private var premeasureAboveNext = true
    /// One selection across every row, as a web page has.
    let selection = TranscriptSelection()
    /// When the view last scrolled: work ahead waits for a pause.
    private var lastScroll: CFTimeInterval = 0
    /// Where ⌘F's current match is drawn.
    private var findPlace: FindPlace?
    /// A match to take the view to at the next layout: its row, and how far down it.
    private var pendingReveal: (id: Int, fraction: CGFloat)?
    var onBottomChange: ((Bool) -> Void)?

    private static let top = Space.xl
    private static let bottom = Space.lg
    private static let sides = Space.xxl
    private static let parkLimit = 128

    init(model: AppModel) {
        self.model = model
        let empty = TranscriptRowView(content: AnyView(EmptyView()), environment: .empty, width: 0, model: model)
        footerHost = RowHost(root: empty)
        measurer = RowHost(root: empty)
        super.init()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.alphaValue = 0
        document.controller = self
        document.addSubview(footerHost.view)
        selection.rowOf = { [weak self] view in
            guard let self else { return nil }
            for (id, host) in self.mounted where view.isDescendant(of: host.view) { return self.index[id] }
            return nil
        }
        selection.textOfRow = { [weak self] i in
            guard let self, self.items.indices.contains(i) else { return nil }
            return TranscriptRows.plainText(self.items[i].row.block)
        }
        selection.wholeText = { [weak self] in
            (self?.items ?? []).map { TranscriptRows.plainText($0.row.block) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        footerHost.onHeightChange = { [weak self] in self?.relayoutSoon() }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scrollView)
    }

    isolated deinit { premeasuring?.cancel() }

    // MARK: Updates

    func update(feed: ChatFeed, context: TranscriptContext, footer: AnyView, jump: Int) {
        // Only what every row reads redraws them all; the rest is per row.
        let global = context.sessionId != self.context?.sessionId || context.prose != self.context?.prose
            || context.transcript != self.context?.transcript
        self.context = context
        footerView = footer
        footerHost.update(TranscriptRowView(content: footer, environment: environment(nil), width: rowWidth, model: model))
        if self.feed !== feed {
            self.feed = feed
            feed.expansion.onChange = { [weak self] row in self?.rowToggled(row) }
            observe(feed)
            attach(feed.find)
        }
        feed.find.includesThinking = context.transcript.showsThinking
        feed.find.root = model.session(context.sessionId)?.worktreePath
        if jump != self.jump {
            self.jump = jump
            follow.jump()
            scrollToEnd(animated: true)
        }
        rebuild(force: global)
    }

    private func observe(_ feed: ChatFeed) {
        withObservationTracking {
            _ = feed.historyRevision
            _ = feed.head.row
        } onChange: { [weak self, weak feed] in
            Task { @MainActor in
                guard let self, let feed, feed === self.feed else { return }
                if self.historyRevision != feed.historyRevision || !self.rebuildHead() {
                    self.rebuild(force: false)
                }
                self.observe(feed)
                feed.find.chatChanged()
            }
        }
    }

    /// Streaming usually changes only the existing last row.
    private func rebuildHead() -> Bool {
        guard let feed, let context, let row = feed.head.row,
              TranscriptRows.shows(row, context.transcript),
              let last = items.last, last.id == row.id else { return false }
        let updated = Item(row: row, gap: last.gap, live: context.working,
                           approvals: last.approvals, latestTodo: last.latestTodo, version: last.version)
        guard updated != last else { return true }
        items[items.count - 1] = updated
        if let host = mounted[row.id] {
            host.update(root(for: updated))
            record(updated, host.measure(width: rowWidth))
        } else {
            heights[row.id] = nil
            dropParked(row.id)
            premeasureCount = -1
        }
        document.needsLayout = true
        return true
    }

    /// Lays the feed's rows out as items, and redraws and re-measures the rows that changed.
    private func rebuild(force: Bool) {
        guard let feed, let context else { return }
        historyRevision = feed.historyRevision
        let rows = feed.rows.filter { TranscriptRows.shows($0, context.transcript) }
        var next: [Item] = []
        next.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            var approvals: [String: PendingPermission] = [:]
            var latestTodo = false
            if case let .tools(_, calls) = row.block {
                if !context.approvals.isEmpty { approvals = context.approvals.filter { key, _ in calls.contains { $0.id == key } } }
                if let todo = context.latestTodoCallId { latestTodo = calls.contains { $0.id == todo } }
            }
            next.append(Item(row: row, gap: i == 0 ? 0 : TranscriptRows.gap(rows[i - 1], row), live: i == rows.count - 1 && context.working,
                             approvals: approvals, latestTodo: latestTodo, version: versions[row.id] ?? 0))
        }
        let old = index
        let oldItems = items
        items = next
        index = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($1.id, $0) })
        findPlace = feed.find.state.currentMatch.flatMap(locate)
        for item in next {
            let changed = old[item.id].map { oldItems[$0] != item } ?? true
            // A row whose find marks changed draws them; its height stays.
            if !changed, !force, let host = mounted[item.id], host.find != rowFind(item) { host.update(root(for: item)) }
            guard changed || force else { continue }
            if let host = mounted[item.id] {
                host.update(root(for: item))
                record(item, host.measure(width: rowWidth))
            } else if changed {
                // Measured again when it's next near the view, or in an idle moment.
                heights[item.id] = nil
                dropParked(item.id)
                premeasureCount = -1
            }
        }
        for id in mounted.keys where index[id] == nil { unmount(id, park: false) }
        document.needsLayout = true
    }

    /// Something in a row opened or closed: redraw it, measure it and place
    /// every row again now, before anything is drawn. What you clicked stays
    /// where it is, unless it's the last row, which grows up from the end.
    private func rowToggled(_ id: Int) {
        guard index[id] != nil else { return }
        versions[id, default: 0] += 1
        if id != items.last?.id { follow.hold() }
        rebuild(force: false)
        layoutRows()
    }

    private func environment(_ item: Item?) -> TranscriptRowEnvironment {
        TranscriptRowEnvironment(approvals: item?.approvals ?? [:],
                                 latestTodoCallId: item?.latestTodo == true ? context?.latestTodoCallId : nil,
                                 prose: context?.prose ?? ProseStyle(font: .inter, size: .medium),
                                 transcript: context?.transcript ?? .normal,
                                 expansion: feed?.expansion,
                                 row: item.map { TranscriptRowKey(id: $0.id, version: $0.version) },
                                 selection: selection,
                                 find: rowFind(item))
    }

    private func root(for item: Item) -> TranscriptRowView {
        TranscriptRowView(content: AnyView(
            BlockView(block: item.row.block, sessionId: context?.sessionId ?? "", live: item.live)
                .padding(.top, item.gap)
        ), environment: environment(item), width: rowWidth, model: model)
    }

    /// Keeps a row's height, here and with the chat for next time.
    private func record(_ item: Item, _ height: CGFloat) {
        if heights[item.id] != height { changedSinceCheck = true }
        heights[item.id] = height
        feed?.measured[item.id] = MeasuredRow(signature: item.hashValue, width: measuredWidth, height: height)
    }

    /// Heights measured the last time the chat was open, where the rows are the same.
    private func seedFromCache() {
        guard let feed, !feed.measured.isEmpty else { return }
        for item in items where heights[item.id] == nil {
            if let known = feed.measured[item.id], known.width == measuredWidth, known.signature == item.hashValue {
                heights[item.id] = known.height
            }
        }
    }

    // MARK: Layout

    /// A row changed height on its own (a reply still revealing), often while
    /// the list is laying out; asking for layout then would be dropped, so ask after.
    private func relayoutSoon() {
        changedSinceCheck = true
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            self.document.needsLayout = true
        }
    }

    private var rowWidth: CGFloat {
        let available = scrollView.contentSize.width - 2 * Self.sides
        return max(200, min(Space.readingWidth, available)).rounded()
    }

    /// Places every row, shows the ones near view, and keeps the scroll where
    /// it belongs: at the end while following, otherwise on what you're reading.
    func layoutRows() {
        let wasLayingOut = layingOut
        layingOut = true
        defer { layingOut = wasLayingOut }
        let width = rowWidth
        if width != measuredWidth {
            measuredWidth = width
            heights = [:]
            premeasureCount = -1
            seedFromCache()
            for (id, host) in mounted {
                guard let i = index[id] else { continue }
                host.update(root(for: items[i]))
                record(items[i], host.measure(width: width))
            }
            for id in parked.keys { dropParked(id) }
            footerHost.update(TranscriptRowView(content: footerView, environment: environment(nil), width: width, model: model))
        }
        let clip = scrollView.contentView
        let reveal = pendingReveal
        pendingReveal = nil
        let anchor = follow.following || reveal != nil ? nil : readingAnchor()

        let x = ((scrollView.contentSize.width - width) / 2).rounded()
        // Rows keep their heights current as they report them.
        for (id, host) in mounted {
            let h = host.measure(width: width)
            if heights[id] != h, let i = index[id] { record(items[i], h) }
        }
        let footerHeight = footerHost.measure(width: width)
        var tops: [CGFloat] = []
        var end = Self.top
        // Place, scroll to where the view belongs, then build the rows seen
        // from there. New rows' real heights can move things again, so repeat
        // until nothing changes: the rows at the end after a big change (the
        // Verbose transcript opening everything) are built in this pass, not later.
        for _ in 0..<4 {
            tops = positions(width: width)
            end = (tops.last ?? Self.top) + (items.last.map { heights[$0.id] ?? estimate($0, width: width) } ?? 0)
            let docHeight = max(end + footerHeight + Self.bottom, clip.bounds.height)
            if document.frame.size != NSSize(width: scrollView.contentSize.width, height: docHeight) {
                document.setFrameSize(NSSize(width: scrollView.contentSize.width, height: docHeight))
            }
            if let reveal, let i = index[reveal.id] {
                // A match: a third of the way down the view, where the eye finds it.
                let h = heights[reveal.id] ?? estimate(items[i], width: width)
                let view = clip.bounds.height
                let y = h <= view * 0.6 ? tops[i] : tops[i] + h * reveal.fraction
                let target = min(max(0, y - view / 3), max(0, docHeight - view))
                if abs(clip.bounds.minY - target) > 0.5 { scroll(to: target) }
            } else if follow.following || !didInitialScroll {
                didInitialScroll = true
                scrollToEnd(animated: false)
            } else if let anchor, let i = index[anchor.id],
                      let target = TranscriptAnchor.target(.init(row: i, offset: Double(anchor.offset)), tops: tops.map(Double.init)) {
                if abs(clip.bounds.minY - CGFloat(target)) > 0.5 { scroll(to: CGFloat(target)) }
            }
            if !mountVisible(tops: tops, width: width) { break }
        }
        footerHost.view.frame = NSRect(x: x, y: end, width: width, height: footerHeight)
        for (id, host) in mounted {
            guard let i = index[id] else { continue }
            let frame = NSRect(x: x, y: tops[i], width: width, height: heights[id] ?? 0)
            if host.view.frame != frame { host.view.frame = frame }
        }
        reportBottom()
        if !revealed { scheduleReveal() }
    }

    /// Builds the rows within a screen of the view and lets go of the rest.
    /// True when a row turned out a different height than guessed.
    private func mountVisible(tops: [CGFloat], width: CGFloat) -> Bool {
        let visible = scrollView.contentView.bounds
        let range = (visible.minY - visible.height)...(visible.maxY + visible.height)
        var wanted = Set<Int>()
        var first = Int.max, last = -1
        for (i, item) in items.enumerated() {
            let h = heights[item.id] ?? estimate(item, width: width)
            if tops[i] + h >= range.lowerBound, tops[i] <= range.upperBound {
                wanted.insert(item.id)
                first = min(first, i); last = max(last, i)
            }
        }
        shownRange = first <= last ? first..<(last + 1) : 0..<0
        // The row a selection drag began in stays while the drag lasts, wherever it scrolls.
        let held = selection.anchor?.memberView
        for (id, host) in mounted where !wanted.contains(id) {
            if let held, held.isDescendant(of: host.view) { continue }
            unmount(id, park: true)
        }
        var changed = false
        for id in wanted where mounted[id] == nil {
            guard let i = index[id] else { continue }
            let h = mount(items[i]).measure(width: width)
            if heights[id] != h { record(items[i], h); changed = true }
        }
        return changed
    }

    /// Each row's top, from the heights known (and guesses for the rest).
    private func positions(width: CGFloat) -> [CGFloat] {
        var y = Self.top
        var tops: [CGFloat] = []
        tops.reserveCapacity(items.count)
        for item in items {
            tops.append(y)
            y += heights[item.id] ?? estimate(item, width: width)
        }
        return tops
    }

    /// The first row at the top of the view, and how far above the view's top
    /// it starts. From every row's place, not only the mounted rows' frames:
    /// mid-scroll the mounted rows lag the view, and anchoring to one below
    /// the top lets rows sizing above it move the view.
    private func readingAnchor() -> (id: Int, offset: CGFloat)? {
        let tops = positions(width: measuredWidth)
        let rowHeights = items.map { heights[$0.id] ?? estimate($0, width: measuredWidth) }
        guard let anchor = TranscriptAnchor.anchor(tops: tops.map(Double.init), heights: rowHeights.map(Double.init),
                                                   viewportTop: Double(scrollView.contentView.bounds.minY)) else { return nil }
        return (items[anchor.row].id, CGFloat(anchor.offset))
    }

    /// A height for a row not measured yet, close enough that the scroll barely moves when it is.
    private func estimate(_ item: Item, width: CGFloat) -> CGFloat {
        let perLine = max(20, width / 7.6)
        let body: CGFloat
        switch item.row.block {
        case let .assistant(_, text, _, _):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, Int((CGFloat($1.count) / perLine).rounded(.up))) }
            body = CGFloat(lines) * (text.hasPrefix("```") ? 19 : 25) + (text.hasPrefix("```") ? 26 : 0)
        case let .user(_, text): body = CGFloat(max(1, Int((CGFloat(text.count) / (perLine * 0.8)).rounded(.up)))) * 22 + 22
        case let .tools(_, calls): body = calls.count > 1 ? 26 : 28
        case .thinking: body = 44
        case .turn: body = 24
        default: body = 32
        }
        return body + item.gap
    }

    private func mount(_ item: Item) -> RowHost {
        let host: RowHost
        if let parkedHost = parked.removeValue(forKey: item.id) {
            parkedOrder.removeAll { $0 == item.id }
            host = parkedHost
            if host.find != rowFind(item) { host.update(root(for: item)) }
        } else {
            host = RowHost(root: root(for: item))
        }
        host.onHeightChange = { [weak self] in self?.relayoutSoon() }
        mounted[item.id] = host
        document.addSubview(host.view)
        return host
    }

    private func unmount(_ id: Int, park: Bool) {
        guard let host = mounted.removeValue(forKey: id) else { return }
        host.view.removeFromSuperview()
        host.onHeightChange = nil
        guard park else { return }
        self.park(id, host)
    }

    private func park(_ id: Int, _ host: RowHost) {
        parked[id] = host
        parkedOrder.removeAll { $0 == id }
        parkedOrder.append(id)
        while parkedOrder.count > Self.parkLimit { parked[parkedOrder.removeFirst()] = nil }
    }

    private func dropParked(_ id: Int) {
        guard parked.removeValue(forKey: id) != nil else { return }
        parkedOrder.removeAll { $0 == id }
    }

    // MARK: Opening

    /// Shows the transcript once two passes in a row changed nothing (or
    /// after a moment at most), so it never appears half-built or shifting.
    private func scheduleReveal() {
        guard !settleScheduled else { return }
        settleScheduled = true
        if revealStarted == nil { revealStarted = Date() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settleScheduled = false
            self.document.layoutSubtreeIfNeeded()
            let settled = !self.changedSinceCheck
            self.changedSinceCheck = false
            if settled || Date().timeIntervalSince(self.revealStarted ?? Date()) > 0.35 {
                self.reveal()
            } else {
                self.scheduleReveal()
            }
        }
    }

    private func reveal() {
        guard !revealed else { return }
        revealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            scrollView.animator().alphaValue = 1
        }
        startPremeasuring()
    }

    // MARK: Measuring ahead

    /// Measures rows not shown yet in idle moments, nearest the view first,
    /// a few milliseconds at a time, so scrolling to them never shifts the view.
    private func startPremeasuring() {
        premeasuring?.cancel()
        premeasuring = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, !Task.isCancelled else { return }
                if !self.premeasureStep() {
                    // All measured; look again after the chat grows.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// One slice of measuring. False when every row is measured and the
    /// rows just past the view are built.
    private func premeasureStep() -> Bool {
        guard revealed, measuredWidth > 0, !items.isEmpty else { return false }
        // Never mid-scroll: a fling gets every frame.
        if CACurrentMediaTime() - lastScroll < 0.25 { return true }
        let lower = min(shownRange.lowerBound, items.count)
        let upper = min(shownRange.upperBound, items.count)
        let range = lower..<max(lower, upper)
        if premeasureRange != range || premeasureCount != items.count {
            premeasureRange = range
            premeasureCount = items.count
            premeasureAbove = lower - 1
            premeasureBelow = upper
            premeasureAboveNext = true
        }
        let deadline = CACurrentMediaTime() + 0.005
        var measuredAny = false
        var left = false
        while premeasureAbove >= 0 || premeasureBelow < items.count {
            let fromAbove = premeasureAbove >= 0 && (premeasureAboveNext || premeasureBelow >= items.count)
            let position = fromAbove ? premeasureAbove : premeasureBelow
            let item = items[position]
            let near = fromAbove ? position >= lower - Self.prebuilt : position < upper + Self.prebuilt
            let build = near && mounted[item.id] == nil && parked[item.id] == nil
            if !build && heights[item.id] != nil {
                if fromAbove { premeasureAbove -= 1 } else { premeasureBelow += 1 }
                premeasureAboveNext = !fromAbove
                continue
            }
            if CACurrentMediaTime() > deadline { left = true; break }
            if fromAbove { premeasureAbove -= 1 } else { premeasureBelow += 1 }
            premeasureAboveNext = !fromAbove
            if build {
                let host = RowHost(root: root(for: item))
                record(item, host.measure(width: measuredWidth))
                park(item.id, host)
            } else {
                measurer.update(root(for: item))
                record(item, measurer.measure(width: measuredWidth))
            }
            measuredAny = true
        }
        if measuredAny { document.needsLayout = true }
        return left
    }

    /// Rows built ahead on each side of the view.
    private static let prebuilt = 32

    /// For the demo's scroll probe: the rows around a point, and how much they hold.
    func describe(around y: CGFloat) -> String {
        let tops = positions(width: measuredWidth)
        return items.indices.filter { abs(tops[$0] - y) < 1200 }.map { i in
            let item = items[i]
            let size: String = switch item.row.block {
            case let .assistant(_, text, _, _): "assistant \(text.count)ch"
            case let .user(_, text): "user \(text.count)ch"
            case let .tools(_, calls): "tools \(calls.count) [" + calls.map { "\($0.name):\(($0.result?.output.count ?? 0))" }.joined(separator: ",") + "]"
            case let .thinking(_, text): "thinking \(text.count)ch"
            default: "other"
            }
            return "#\(i) y\(Int(tops[i])) h\(Int(heights[item.id] ?? -1)) \(mounted[item.id] != nil ? "M" : "-") \(size)"
        }.joined(separator: " | ")
    }

    // MARK: Finding

    private func attach(_ find: ChatFind) {
        find.topBlock = { [weak self] in self?.readingAnchor().map { $0.id / ChatFeed.partsPerBlock } }
        find.reveal = { [weak self] match in self?.reveal(match) }
        observeFind(find)
    }

    private func observeFind(_ find: ChatFind) {
        withObservationTracking {
            _ = find.isOpen
            _ = find.state
        } onChange: { [weak self, weak find] in
            Task { @MainActor in
                guard let self, let find, find === self.feed?.find else { return }
                self.findChanged()
                self.observeFind(find)
            }
        }
    }

    /// What's found, or which match you're on, changed: the rows showing redraw their marks.
    private func findChanged() {
        findPlace = feed?.find.state.currentMatch.flatMap(locate)
        for (id, host) in mounted {
            guard let i = index[id], host.find != rowFind(items[i]) else { continue }
            host.update(root(for: items[i]))
        }
        for (id, host) in parked {
            guard let i = index[id], host.find != rowFind(items[i]) else { continue }
            dropParked(id)
        }
        document.needsLayout = true
    }

    /// What a row marks: the words being found, and the match you're on if it's in this row.
    private func rowFind(_ item: Item?) -> RowFind? {
        guard let item, let find = feed?.find, find.isOpen, !find.state.query.isEmpty else { return nil }
        return RowFind(query: find.state.query, current: findPlace?.row == item.id ? findPlace?.spot : nil)
    }

    /// Takes the view to a match: opens what hides it (a run of calls, a
    /// call's output, a long message) and scrolls it a third of the way down.
    private func reveal(_ match: TranscriptMatch) {
        guard let place = locate(match) else { return }
        follow.hold()
        for key in place.opens { feed?.expansion.set(key, true, row: place.row) }
        pendingReveal = (place.row, place.fraction)
        layoutRows()
    }

    /// Where a match is drawn: its row (a reply's part, a call's row), its
    /// place among that row's texts, and what has to open to show it.
    private func locate(_ match: TranscriptMatch) -> FindPlace? {
        guard let find = feed?.find else { return nil }
        let rows = items.filter { $0.id / ChatFeed.partsPerBlock == match.block }
        guard let first = rows.first else { return nil }
        let query = find.state.query
        let field = FindSpot.field(match.field)
        func share(_ location: Int, of text: String) -> CGFloat {
            CGFloat(location) / CGFloat(max(1, text.utf16.count))
        }
        switch match.field {
        case .user:
            guard case let .user(_, text) = first.row.block else { return nil }
            return FindPlace(row: first.id, spot: FindSpot(field: field, occurrence: match.occurrence), opens: ["user:\(first.id)"],
                             fraction: share(match.location, of: PromptAttachments.split(text).text))
        case .thinking:
            guard case let .thinking(_, text) = first.row.block else { return nil }
            return FindPlace(row: first.id, spot: FindSpot(field: field, occurrence: match.occurrence), opens: [],
                             fraction: share(match.location, of: text))
        case .reply:
            // A reply still streaming, or a very long one, is a row per Markdown block.
            var n = match.occurrence
            for row in rows {
                guard case let .assistant(_, text, _, _) = row.row.block else { continue }
                let ranges = TranscriptSearch.ranges(of: query, in: text)
                if n < ranges.count {
                    return FindPlace(row: row.id, spot: FindSpot(field: field, occurrence: n), opens: [],
                                     fraction: share(ranges[n].lowerBound.utf16Offset(in: text), of: text))
                }
                n -= ranges.count
            }
            return FindPlace(row: rows[rows.count - 1].id, spot: nil, opens: [], fraction: 0)
        case let .toolTitle(id), let .toolOutput(id):
            for row in rows {
                guard case let .tools(_, calls) = row.row.block, let i = calls.firstIndex(where: { $0.id == id }) else { continue }
                var opens: [String] = []
                if calls.count > 1, context?.transcript.opensTools != true { opens.append("run:\(calls[0].id)") }
                var within: CGFloat = 0
                if case .toolOutput = match.field {
                    opens.append("call:\(id)")
                    let text = ChatFind.fields(calls[i], root: find.root).first { $0.0 == match.field }?.1 ?? ""
                    let line = text.utf16.prefix(match.location).count { $0 == 10 }
                    // Past the lines an output shows before Show more.
                    if line >= 14 { opens.append("out:\(id)") }
                    within = CGFloat(line) / CGFloat(max(1, text.utf16.count { $0 == 10 } + 1))
                }
                return FindPlace(row: row.id, spot: FindSpot(field: field, occurrence: match.occurrence), opens: opens,
                                 fraction: (CGFloat(i) + within) / CGFloat(calls.count))
            }
            return nil
        }
    }

    /// For the demo's find probe: where the current match is, whether its
    /// row is on screen, and what it marks.
    func describeFind() -> String {
        guard let place = findPlace, let i = index[place.row] else { return "no match placed" }
        let visible = scrollView.contentView.bounds
        let frame = mounted[place.row]?.view.frame
        let block: String = switch items[i].row.block {
        case let .tools(_, calls): "tools [" + calls.map { "\($0.id) open \(feed?.expansion.value("call:\($0.id)") ?? false) out \(feed?.expansion.value("out:\($0.id)") ?? false)" }.joined(separator: ", ") + "]"
        case let .assistant(_, text, _, _): "reply “\(text.prefix(60))”"
        default: "other"
        }
        return "row #\(i) of \(items.count) \(block), spot \(place.spot.map { "\($0.field)#\($0.occurrence)" } ?? "none"), "
            + (frame.map { String(format: "frame y %.0f–%.0f, view y %.0f–%.0f, in view %d", $0.minY, $0.maxY, visible.minY, visible.maxY,
                                  visible.intersects($0) ? 1 : 0) } ?? "not mounted")
            + ", marks \(mounted[place.row]?.find.map { "\($0.query) current \($0.current.map { "\($0.field)#\($0.occurrence)" } ?? "none")" } ?? "none")"
    }

    // MARK: Scrolling

    private var distanceFromEnd: CGFloat {
        let clip = scrollView.contentView.bounds
        return document.frame.height - clip.maxY
    }

    private func scrollToEnd(animated: Bool) {
        let target = max(0, document.frame.height - scrollView.contentView.bounds.height)
        if animated {
            scrollingByCode = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.scrollingByCode = false
                    self?.scrollView.reflectScrolledClipView(self!.scrollView.contentView)
                }
            }
        } else {
            scroll(to: target)
        }
    }

    private func scroll(to y: CGFloat) {
        scrollingByCode = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollingByCode = false
    }

    @objc private func scrolled() {
        lastScroll = CACurrentMediaTime()
        // Where the view landed decides following, however the reader moved
        // it — wheel, scrollbar, keys, a selection drag. The list's own
        // scrolling, layout clamping the view, and resizes that leave the
        // view's top where it was never count.
        let originY = scrollView.contentView.bounds.minY
        if !scrollingByCode, !layingOut, originY != lastOriginY {
            follow.readerScrolled(distanceFromEnd: Double(distanceFromEnd))
        }
        lastOriginY = originY
        document.needsLayout = true
        reportBottom()
    }

    @objc private func resized() { document.needsLayout = true }

    private func reportBottom() {
        onBottomChange?(distanceFromEnd < 80)
    }
}

/// Where ⌘F's match is drawn in a transcript, and what has to open to show it.
struct FindPlace {
    let row: Int
    let spot: FindSpot?
    /// Expansion keys to open: a run of calls, a call, its output, a long message.
    let opens: [String]
    /// How far down the row, from 0 to 1.
    let fraction: CGFloat
}

final class TranscriptDocumentView: NSView {
    weak var controller: TranscriptController?
    private let press = EmptySpacePress()
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The margins and the gaps between rows start a selection at the nearest text.
    override func mouseDown(with event: NSEvent) {
        if !press.down(event, in: controller?.selection) { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) { press.dragged(event) }
    override func mouseUp(with event: NSEvent) { press.up(event) }

    override func layout() {
        super.layout()
        controller?.layoutRows()
    }
}

/// One row's hosting view, and word when its content changes height: a reply
/// still revealing, a call finishing, a row you expand. The row reports its
/// own height from inside SwiftUI, since a hosting view isn't told when
/// state inside it changes its size.
@MainActor
final class RowHost {
    private let host: RowHostingView
    private let reporter = HeightReporter()
    private var lastWidth: CGFloat = -1
    private var lastHeight: CGFloat = 0
    /// Whether the content changed since it was last measured.
    private(set) var dirty = false
    /// The find marks it draws.
    private(set) var find: RowFind?
    var onHeightChange: (() -> Void)?
    var view: NSView { host }

    init(root: TranscriptRowView) {
        find = root.environment.find
        host = RowHostingView(rootView: root.reporting(to: reporter))
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        reporter.onReport = { [weak self] height in self?.heightChanged(to: height) }
        // Also after each of its layouts: a row that opens (a command's
        // output, a run of calls) must never draw past its frame over the rows below.
        host.onLayout = { [weak self, unowned host] in
            guard let self else { return }
            let height = host.intrinsicContentSize.height.rounded(.up)
            // Its frame is out of date even if the height was heard before:
            // place the rows again either way.
            if height > 0, abs(height - host.frame.height) > 0.5 {
                self.lastHeight = height
                self.onHeightChange?()
            }
        }
    }

    private func heightChanged(to height: CGFloat) {
        guard abs(height - lastHeight) > 0.5 else { return }
        lastHeight = height
        onHeightChange?()
    }

    func update(_ root: TranscriptRowView) {
        host.rootView = root.reporting(to: reporter)
        find = root.environment.find
        dirty = true
    }

    /// The row's height at `width`, measured again when its content or the width changed.
    func measure(width: CGFloat) -> CGFloat {
        if !dirty, width == lastWidth { return lastHeight }
        dirty = false
        lastWidth = width
        lastHeight = host.intrinsicContentSize.height.rounded(.up)
        return lastHeight
    }
}

/// A row's hosting view, calling back after it lays out.
final class RowHostingView: NSHostingView<TranscriptRowView> {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Carries a row's laid-out height out of SwiftUI.
@MainActor
final class HeightReporter {
    var onReport: ((CGFloat) -> Void)?
    func report(_ height: CGFloat) { onReport?(height.rounded(.up)) }
}

/// What a row reads from the chat around it: only its own share, so a
/// change for one row never redraws the others.
struct TranscriptRowEnvironment {
    var approvals: [String: PendingPermission]
    var latestTodoCallId: String?
    var prose: ProseStyle
    var transcript: TranscriptMode
    var expansion: TranscriptExpansion?
    var row: TranscriptRowKey?
    var selection: TranscriptSelection?
    var find: RowFind?

    static let empty = TranscriptRowEnvironment(approvals: [:], latestTodoCallId: nil, prose: ProseStyle(font: .inter, size: .medium),
                                                transcript: .normal, expansion: nil, row: nil, selection: nil, find: nil)
}

/// A row as its hosting view draws it: the content at the row's width, with
/// what the chat's rows read from their environment.
struct TranscriptRowView: View {
    let content: AnyView
    let environment: TranscriptRowEnvironment
    let width: CGFloat
    let model: AppModel
    var reporter: HeightReporter?

    func reporting(to reporter: HeightReporter) -> TranscriptRowView {
        var copy = self
        copy.reporter = reporter
        return copy
    }

    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(SelectionSurface(selection: environment.selection))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reporter?.report($0) }
            .environment(model)
            .environment(\.toolApprovals, environment.approvals)
            .environment(\.latestTodoCallId, environment.latestTodoCallId)
            .environment(\.proseStyle, environment.prose)
            .environment(\.transcriptMode, environment.transcript)
            .environment(\.transcriptExpansion, environment.expansion)
            .environment(\.transcriptRow, environment.row)
            .environment(\.textSelectionGroup, environment.selection)
            .environment(\.transcriptFind, environment.find)
    }
}
