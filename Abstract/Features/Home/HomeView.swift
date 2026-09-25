import SwiftUI
import AbstractCore

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var hasAvailableProject: Bool {
        !model.projects.isEmpty || model.remote.links.values.contains { link in
            link.state == .online && link.snapshot?.projects.contains { $0.archivedAt == nil } == true
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: Space.md) {
                    BrandMark()
                    Text(hasAvailableProject ? "What should we build?" : "Welcome to Abstract")
                        .font(BTFont.ui(26, .semibold))
                        .foregroundStyle(Color.btText)
                    Text(hasAvailableProject
                         ? "Each chat runs its own agent in an isolated worktree, so several can work at once without stepping on each other."
                         : "Add a git repository and agents work in their own worktrees, and you review every change before it lands. Or start a standalone chat below.")
                        .font(BTFont.ui(13.5))
                        .foregroundStyle(Color.btTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 460)
                }
                .padding(.top, 72)
                .padding(.bottom, Space.xxl)

                if !hasAvailableProject {
                    Button { model.isAddingProject = true } label: { Label("Add a Project", systemImage: "folder.badge.plus") }
                        .buttonStyle(.bt(.primary, size: .large))
                        .padding(.bottom, Space.xl)
                }
                // With no project yet, it starts a standalone chat.
                TaskLauncher(autofocus: hasAvailableProject)
                    .frame(maxWidth: 680)

                let recent = Array(model.sessions.filter { $0.archivedAt == nil }.prefix(6))
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(title: "Recent")
                            .padding(.horizontal, Space.sm)
                            .padding(.bottom, Space.sm)
                        ForEach(recent) { s in RecentRow(session: s) }
                    }
                    .frame(maxWidth: 680)
                    .padding(.top, 44)
                }

                HStack(spacing: Space.xl) {
                    ShortcutHint(keys: ["⌘", "K"], label: "Jump anywhere")
                    ShortcutHint(keys: ["⌘", "N"], label: "New chat")
                    ShortcutHint(keys: ["⌘", "D"], label: "Review changes")
                }
                .padding(.top, 40)
                .padding(.bottom, Space.xxl)
            }
            .padding(.horizontal, Space.xxl)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct RecentRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        Button { model.open(session.id) } label: {
            HStack(spacing: Space.md) {
                ProviderLogo(providerId: session.providerId, size: 15)
                Text(session.name).font(.btBody).foregroundStyle(Color.btText).lineLimit(1)
                Spacer(minLength: Space.lg)
                StatusDot(status: session.status, size: 6)
                Text([session.status.label, model.project(session.projectId)?.name, RelativeTime.short(session.lastEventAt ?? session.createdAt)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.sm)
            .frame(height: 34)
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { CardBody(configuration: configuration) }
    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(hovering ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.14), value: hovering)
        }
    }
}

private struct ShortcutHint: View {
    let keys: [String]
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyHint($0) } }
            Text(label).font(.btCaption).foregroundStyle(Color.btTextTertiary)
        }
    }
}

/// Abstract's mark, in the text colour of the current theme.
struct BrandMark: View {
    var size: CGFloat = 44
    var body: some View {
        AbstractMark()
            .fill(Color.btText)
            .frame(width: size, height: size)
            .accessibilityLabel("Abstract")
    }
}
