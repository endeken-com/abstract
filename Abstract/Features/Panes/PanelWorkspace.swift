import SwiftUI
import AbstractCore

/// The chat with its two panels: one to the right, full height, and one
/// under the chat. Each is a row of tabs over the active tab.
struct PanelWorkspace: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Size while a divider is being dragged; committed on release.
    @State private var dragging: [PanelSlot: Double] = [:]

    var body: some View {
        let layout = model.layout(for: session.id)
        GeometryReader { geo in
            // The chat keeps a readable minimum; panels give way to it.
            let side = min(dragging[.side] ?? layout.side.size, max(geo.size.width - 380, PanelSlot.side.sizes.lowerBound))
            let bottom = min(dragging[.bottom] ?? layout.bottom.size, max(geo.size.height - 240, PanelSlot.bottom.sizes.lowerBound))
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // The main pane: the chat, file or changes showing. Its tabs
                    // are in the title band above (see `TitlebarLeading`).
                    MainTabContent(session: session)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .top) { Hairline() }
                        .padding(.top, Chrome.titlebar)
                    if layout.bottom.isOpen {
                        PanelDivider(slot: .bottom, size: bottom, dragging: $dragging) { size in
                            model.updateLayout(session.id) { $0.resize(.bottom, to: size) }
                        }
                        PanelView(slot: .bottom, session: session)
                            .frame(height: bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.mainColumnWidth = $0 }
                .ignoresSafeArea(.container, edges: .top)
                if layout.side.isOpen {
                    // Full height, up through the title band, like the sidebar's edge.
                    PanelDivider(slot: .side, size: side, dragging: $dragging) { size in
                        model.updateLayout(session.id) { $0.resize(.side, to: size) }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    // Its tabs live in the title band, beside the toolbar buttons.
                    PanelView(slot: .side, session: session, showsTabs: false)
                        .frame(width: side)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onChange(of: layout.side.isOpen ? side : 0, initial: true) { _, width in
                if model.sidePanelWidth[session.id] != width { model.sidePanelWidth[session.id] = width }
            }
            // Clip the sides and bottom, never the top: the chat scrolls up
            // under the window title, where macOS blurs it progressively.
            .clipShape(OpenTopRectangle())
        }
    }
}

/// A rectangle that extends far above its frame, so clipping with it keeps
/// content that reaches into the title band.
private struct OpenTopRectangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 200, width: rect.width, height: rect.height + 200))
    }
}

/// One panel: its tabs, then the tab that's showing.
private struct PanelView: View {
    @Environment(AppModel.self) private var model
    let slot: PanelSlot
    let session: Session
    var showsTabs = true

    var body: some View {
        let panel = model.layout(for: session.id)[slot]
        VStack(spacing: 0) {
            if showsTabs {
                PanelTabBar(slot: slot, session: session)
                    .padding(.horizontal, 10)
                    .frame(height: 38)
            }
            Hairline()
            if let item = panel.active {
                PaneContent(item: item, session: session)
                    .id(item.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .background(Color.btCanvas)
    }
}

/// Fixed-width tabs and a + for more, nothing else. The bottom panel shows
/// it above its content; the side panel's sits in the title band, where
/// tabs that run into the toolbar buttons fade out under them.
struct PanelTabBar: View {
    @Environment(AppModel.self) private var model
    let slot: PanelSlot
    let session: Session
    /// In the title band: the + follows the last tab and the row fades out at its end.
    var inTitleBand = false

    var body: some View {
        let panel = model.layout(for: session.id)[slot]
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(panel.tabs) { item in
                        PanelTab(item: item, active: item.id == panel.active?.id, slot: slot, session: session)
                    }
                    if inTitleBand { addMenu }
                }
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if inTitleBand { LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28) }
                }
            }
            if !inTitleBand { addMenu }
        }
    }

    private var addMenu: some View {
        ChromeIconMenu(symbol: "plus", help: "New tab", size: 24) {
            ForEach(PaneKind.allCases.filter { $0.fits(slot) && $0.isAvailable }, id: \.self) { kind in
                Button(kind.title) { model.updateLayout(session.id) { $0.add(kind, to: slot) } }
            }
        }
    }
}

private struct PanelTab: View {
    @Environment(AppModel.self) private var model
    let item: PaneItem
    let active: Bool
    let slot: PanelSlot
    let session: Session
    @State private var hovering = false
    @State private var hoveringClose = false

    /// The side panel is narrow, so its tabs are too.
    private var width: CGFloat { slot == .side ? 108 : 136 }
    /// Tab width less padding, the glyph and its gap.
    private var titleWidth: CGFloat { width - 10 - 6 - 15 - 7 }
    private var showsClose: Bool { hovering || active }

    var body: some View {
        HStack(spacing: 7) {
            PaneGlyph(kind: item.kind)
                .foregroundStyle(active ? Color.btTextSecondary : Color.btTextTertiary)
            PaneTabTitle(item: item, session: session)
                .font(BTFont.ui(12.5, active ? .medium : .regular))
                .foregroundStyle(active ? Color.btText : hovering ? Color.btTextSecondary : Color.btTextTertiary)
                .lineLimit(1)
                .fixedSize()
                // An exact width: inside the tab strip's scroll view a flexible
                // frame would take the whole title and spill out of the tab.
                .frame(width: titleWidth, alignment: .leading)
                // The title fades out instead of ending in "…"; further in when the × is over it.
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                        Color.clear.frame(width: showsClose ? 18 : 0)
                    }
                }
                .clipped()
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: width, height: 28)
        .overlay(alignment: .trailing) {
            Button { model.updateLayout(session.id) { $0.close(item.id) } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hoveringClose ? Color.btText : Color.btTextTertiary)
                    .frame(width: 20, height: 20)
                    .background(hoveringClose ? Color.btSelection : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .padding(.trailing, 4)
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .help("Close tab")
        }
        .background(active ? Color.btHover : hovering ? Color.btHover.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.updateLayout(session.id) { $0.activate(item.id) } }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .contextMenu {
            let other = slot.other
            Button(other == .side ? "Move to Side Panel" : "Move to Bottom Panel") {
                model.updateLayout(session.id) { $0.move(item.id, to: other) }
            }
            .disabled(!item.kind.fits(other))
            Divider()
            Button("Close") { model.updateLayout(session.id) { $0.close(item.id) } }
            Button("Close Others") {
                model.updateLayout(session.id) { l in for t in l[slot].tabs where t.id != item.id { l.close(t.id) } }
            }
        }
    }
}

/// What a tab is called: the running program for a terminal, the open file
/// for Files, and the pane's name otherwise.
private struct PaneTabTitle: View {
    @Environment(AppModel.self) private var model
    let item: PaneItem
    let session: Session

    var body: some View {
        switch item.kind {
        case .terminal:
            // Shells don't announce every change; re-read once a second.
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(TerminalRegistry.shared.existingHost(for: item.id)?.title ?? "Terminal")
            }
        case .files:
            Text("Files")
        case .review:
            Text(verbatim: model.pullRequests[session.id]?.label ?? "Pull Request")
        default:
            Text(item.kind.title)
        }
    }
}

/// A tab's icon, drawn to one size so the row lines up.
struct PaneGlyph: View {
    let kind: PaneKind

    var body: some View {
        Group {
            switch kind {
            case .changes:
                // ± in a rounded square, the review glyph.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(lineWidth: 1.1)
                    .overlay { Image(systemName: "plusminus").font(.system(size: 7.5, weight: .semibold)) }
                    .frame(width: 13, height: 13)
            case .files:
                Image(systemName: "doc.text").font(.system(size: 12, weight: .regular))
            case .terminal:
                Image(systemName: "apple.terminal").font(.system(size: 11.5, weight: .regular))
            case .review:
                PullRequestGlyph(kind: .open).frame(width: 12, height: 12)
            case .chat:
                Image(systemName: kind.symbol).font(.system(size: 11.5, weight: .regular))
            }
        }
        .frame(width: 15, height: 15)
    }
}

/// A hairline between the chat and a panel, with a wider invisible grip.
private struct PanelDivider: View {
    let slot: PanelSlot
    let size: Double
    @Binding var dragging: [PanelSlot: Double]
    let commit: (Double) -> Void
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        let vertical = slot == .side
        Rectangle()
            .fill(hovering || start != nil ? Color.btBorderStrong : Color.btBorder)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: vertical ? 8 : nil, height: vertical ? nil : 8)
                    .contentShape(Rectangle())
                    .pointerStyle(vertical ? .columnResize : .rowResize)
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = start ?? size
                                start = base
                                let delta = vertical ? value.translation.width : value.translation.height
                                dragging[slot] = min(max(base - delta, slot.sizes.lowerBound), slot.sizes.upperBound)
                            }
                            .onEnded { _ in
                                if let final = dragging[slot] { commit(final) }
                                dragging[slot] = nil
                                start = nil
                            }
                    )
            }
            .zIndex(1)
    }
}

/// The window's three regions as one family of outline glyphs: the
/// sidebar, the side panel and the bottom panel. The region fills in while
/// it is showing.
struct RegionGlyph: View {
    enum Region { case sidebar, side, bottom }
    let region: Region
    let open: Bool

    var body: some View {
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.6, dy: 0.6)
            let outline = Path(roundedRect: frame, cornerRadius: 2.6)
            let part: CGRect = switch region {
            case .sidebar: CGRect(x: frame.minX, y: frame.minY, width: frame.width * 0.34, height: frame.height)
            case .side: CGRect(x: frame.maxX - frame.width * 0.38, y: frame.minY, width: frame.width * 0.38, height: frame.height)
            case .bottom: CGRect(x: frame.minX, y: frame.maxY - frame.height * 0.4, width: frame.width, height: frame.height * 0.4)
            }
            if open {
                var inside = context
                inside.clip(to: outline)
                inside.opacity = 0.5
                inside.fill(Path(part), with: .foreground)
            }
            var divider = Path()
            switch region {
            case .sidebar: divider.move(to: CGPoint(x: part.maxX, y: frame.minY)); divider.addLine(to: CGPoint(x: part.maxX, y: frame.maxY))
            case .side: divider.move(to: CGPoint(x: part.minX, y: frame.minY)); divider.addLine(to: CGPoint(x: part.minX, y: frame.maxY))
            case .bottom: divider.move(to: CGPoint(x: frame.minX, y: part.minY)); divider.addLine(to: CGPoint(x: frame.maxX, y: part.minY))
            }
            context.stroke(divider, with: .foreground, lineWidth: 1.1)
            context.stroke(outline, with: .foreground, lineWidth: 1.2)
        }
        .frame(width: 16, height: 13)
    }
}

