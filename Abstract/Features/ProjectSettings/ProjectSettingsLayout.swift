import SwiftUI

/// Where everything on the project page lines up.
enum ProjectPage {
    /// The column the cards sit in.
    static let width: CGFloat = 720
    static let railWidth: CGFloat = 172
    static let railGap: CGFloat = 40
    /// Narrower than this, the rail gives way to a menu in the header.
    static let railBreakpoint: CGFloat = 900
    static let cardRadius: CGFloat = 10
    /// A row's words start this far inside its card; its dividers too.
    static let rowInset: CGFloat = 14
    static let rowMinHeight: CGFloat = 44
    static let sectionGap: CGFloat = 40
    nonisolated static let scrollSpace = "ProjectSettingsScroll"
}

/// The page's sections, in order. The rail lists them.
enum ProjectSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case chats, permissions, git, context, scripts, danger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: "New chats"
        case .permissions: "Permissions"
        case .git: "Git"
        case .context: "Agent context"
        case .scripts: "Scripts"
        case .danger: "Danger zone"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "plus.bubble"
        case .permissions: "lock.shield"
        case .git: "arrow.triangle.branch"
        case .context: "books.vertical"
        case .scripts: "terminal"
        case .danger: "exclamationmark.triangle"
        }
    }

    /// One sentence under the section's title.
    var subtitle: String? {
        switch self {
        case .chats: "What a chat started in this project begins with. You can still change each one when you start it."
        case .permissions: "How this project's agents are asked for permission, and the answers you've told Abstract to remember."
        case .git: "The repository, and how each chat's worktree and branch are made."
        case .context: "What this project's agents get beside their own setup. A change reaches a chat the next time its agent starts."
        case .scripts: "Commands run for workspace setup, teardown, and the Run button."
        case .danger: nil
        }
    }
}

// MARK: - Following the scroll

/// Which section the page is on: the last one whose title has passed a line
/// a third of the way down, or, once the page can't scroll further, the last
/// one on screen. A click on the rail holds its choice while the page
/// scrolls there.
@Observable
final class SectionSpy {
    var active: ProjectSettingsSection = .chats
    @ObservationIgnored var viewportHeight: CGFloat = 600
    /// The page is scrolled as far down as it goes.
    @ObservationIgnored var atEnd = false { didSet { if atEnd != oldValue { update() } } }
    @ObservationIgnored private var tops: [ProjectSettingsSection: CGFloat] = [:]
    @ObservationIgnored private var heldUntil = Date.distantPast

    func report(_ section: ProjectSettingsSection, top: CGFloat) {
        tops[section] = top
        update()
    }

    private func update() {
        guard Date.now >= heldUntil else { return }
        let line = atEnd ? viewportHeight - 40 : max(120, viewportHeight * 0.35)
        let passed = ProjectSettingsSection.allCases.filter { tops[$0].map { $0 <= line } ?? false }
        let next = passed.last ?? ProjectSettingsSection.allCases.first { tops[$0] != nil } ?? .chats
        if next != active { active = next }
    }

    func hold(_ section: ProjectSettingsSection) {
        active = section
        heldUntil = .now.addingTimeInterval(0.8)
    }
}

// MARK: - Sections and cards

/// A section: its title, a sentence, then its cards.
struct PageSection<Content: View>: View {
    @Environment(SectionSpy.self) private var spy
    let section: ProjectSettingsSection
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.btHeadline)
                    .foregroundStyle(Color.btText)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
            content()
        }
        .padding(.top, ProjectPage.sectionGap)
        .id(section)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(ProjectPage.scrollSpace)).minY } action: { top in
            spy.report(section, top: top)
        }
    }
}

/// A small heading over one card of several in a section.
struct CardGroup<Content: View>: View {
    let title: String
    var info: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title).font(.btBodyMedium).foregroundStyle(Color.btTextSecondary)
                if let info { InfoButton(title: title, text: info) }
            }
            .padding(.leading, 2)
            content()
        }
        .padding(.top, Space.xs)
    }
}

/// Rows on one surface, a hairline between each, the way System Settings
/// groups them.
struct SettingsCard<Content: View>: View {
    enum Tone { case plain, danger }

    var tone: Tone = .plain
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ProjectPage.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Hairline().padding(.leading, ProjectPage.rowInset)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .danger ? Color.btRemovedWash : Color.btSurface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(tone == .danger ? Color.btRemoved.opacity(0.4) : Color.btBorder, lineWidth: 0.5))
    }
}

extension View {
    /// A card row's padding and height.
    func cardRow() -> some View {
        padding(.horizontal, ProjectPage.rowInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: ProjectPage.rowMinHeight, alignment: .leading)
    }
}

/// A setting: its name (and a line on what it does) on the left, its
/// control on the right; a warning under both when there is one.
struct CardRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var info: String? = nil
    var warning: String? = nil
    var error: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.lg) {
                    RowTitle(title: title, detail: detail, info: info)
                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    control()
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    RowTitle(title: title, detail: detail, info: info)
                    control()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let warning { RowNote(text: warning, color: .btWarning, symbol: "exclamationmark.triangle") }
            if let error { RowNote(text: error, color: .btRemoved, symbol: "xmark.octagon") }
        }
        .cardRow()
    }
}

extension CardRow where Control == EmptyView {
    init(title: String, detail: String? = nil, info: String? = nil) {
        self.init(title: title, detail: detail, info: info) { EmptyView() }
    }
}

/// A setting whose editor takes the card's full width, under its name.
struct CardStackedRow<Editor: View>: View {
    let title: String
    var detail: String? = nil
    var info: String? = nil
    @ViewBuilder var editor: () -> Editor

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            RowTitle(title: title, detail: detail, info: info)
            editor()
        }
        .padding(.horizontal, ProjectPage.rowInset)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One thing in a list (a rule, a server): what it is, then its actions
/// behind a … menu.
struct CardItemRow<Leading: View, Actions: View>: View {
    let title: String
    var monoTitle = false
    var subtitle: String? = nil
    var meta: String? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                if monoTitle {
                    Text(title)
                        .font(BTFont.mono(12.5))
                        .foregroundStyle(Color.btText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(title)
                } else {
                    Text(title).font(.btBody).foregroundStyle(Color.btText).lineLimit(1)
                }
                if let subtitle { PathText(text: subtitle) }
                if let meta {
                    Text(meta)
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowActionsMenu(title: title, emphasized: hovering, content: actions)
        }
        .cardRow()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension CardItemRow where Leading == EmptyView {
    init(title: String, monoTitle: Bool = false, subtitle: String? = nil, meta: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, monoTitle: monoTitle, subtitle: subtitle, meta: meta, leading: { EmptyView() }, actions: actions)
    }
}

/// A row's actions: a quiet … that firms up while its row is hovered.
private struct RowActionsMenu<Content: View>: View {
    let title: String
    let emphasized: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering || emphasized ? Color.btText : Color.btTextTertiary)
                .frame(width: 26, height: 24)
                .background(hovering ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Edit or delete")
        .accessibilityLabel("Actions for \(title)")
    }
}

/// The last row of a list card: adds one more.
struct CardAddRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text(title).font(.btBody)
            }
            .foregroundStyle(Color.btTextSecondary)
            .padding(.horizontal, ProjectPage.rowInset)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        }
        .buttonStyle(RowButtonStyle(cornerRadius: 0))
    }
}

/// A list card's only row while it has nothing in it.
struct CardEmptyRow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.btCallout)
            .foregroundStyle(Color.btTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ProjectPage.rowInset)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RowTitle: View {
    let title: String
    let detail: String?
    let info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title).font(.btBody).foregroundStyle(Color.btText)
                if let info { InfoButton(title: title, text: info) }
            }
            if let detail {
                Text(detail)
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RowNote: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.btCallout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The longer explanation of a setting, a click away.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(hovering || open ? Color.btTextSecondary : Color.btTextTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text)
                .font(.btCallout)
                .foregroundStyle(Color.btTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(Space.md)
        }
    }
}

/// A popover's list of switches: as tall as its rows up to `maxHeight`,
/// then scrolling, so a long list never runs off the screen.
struct PopoverList<Content: View>: View {
    var width: CGFloat = 260
    var maxHeight: CGFloat = 360
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) { content() }
                .lineLimit(1)
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: min(height ?? maxHeight, maxHeight))
    }
}

/// A path or remote as it reads: mono, muted, cut in the middle when long.
struct PathText: View {
    let text: String
    var quiet = false

    var body: some View {
        Text(text)
            .font(BTFont.mono(12))
            .foregroundStyle(quiet ? Color.btTextTertiary : Color.btTextSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }
}

// MARK: - Rail

/// The sections down the side; the one on screen is lit.
struct ProjectSettingsRail: View {
    @Environment(SectionSpy.self) private var spy
    let jump: (ProjectSettingsSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(ProjectSettingsSection.allCases) { section in
                if section == .danger {
                    Hairline()
                        .padding(.horizontal, Rail.rowPadding)
                        .padding(.vertical, Space.sm)
                }
                let active = spy.active == section
                Button { jump(section) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: Rail.iconColumn)
                        Text(section.title)
                            .font(BTFont.ui(13, active ? .medium : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(active ? Color.btText : Color.btTextSecondary)
                    .padding(.horizontal, Rail.rowPadding)
                    .frame(height: 30)
                }
                .buttonStyle(RailRowStyle(selected: active))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.15), value: spy.active)
    }
}

/// The rail as one menu, for a window too narrow to show it.
struct ProjectSettingsJumpMenu: View {
    @Environment(SectionSpy.self) private var spy
    let jump: (ProjectSettingsSection) -> Void

    var body: some View {
        SentenceMenu(title: spy.active.title, quiet: true) {
            ForEach(ProjectSettingsSection.allCases) { section in
                Button { jump(section) } label: { Label(section.title, systemImage: section.symbol) }
            }
        }
        .help("Jump to a section")
    }
}

/// "Saved", for a moment after each change is stored.
struct SavedBadge: View {
    let tick: Int
    @State private var visible = false

    var body: some View {
        Label("Saved", systemImage: "checkmark")
            .font(.btCallout)
            .foregroundStyle(Color.btTextTertiary)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .task(id: tick) {
                guard tick > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) { visible = true }
                guard (try? await Task.sleep(for: .seconds(1.6))) != nil else { return }
                withAnimation(.easeOut(duration: 0.5)) { visible = false }
            }
    }
}
