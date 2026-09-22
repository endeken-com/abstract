import SwiftUI
import BacktickCore

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: Space.md) {
                    BacktickMark()
                    Text(model.projects.isEmpty ? "Welcome to Backtick" : "What should we build?")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.btText)
                    Text(model.projects.isEmpty
                         ? "Add a git repository to begin. Agents work in their own worktrees, and you review every change before it lands."
                         : "Each chat runs its own agent in an isolated worktree, so several can work at once without stepping on each other.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.btTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 460)
                }
                .padding(.top, 72)
                .padding(.bottom, Space.xxl)

                if model.projects.isEmpty {
                    Button { model.isAddingProject = true } label: { Label("Add a Project", systemImage: "folder.badge.plus") }
                        .buttonStyle(.bt(.primary, size: .large))
                } else {
                    TaskLauncher(autofocus: true)
                        .frame(maxWidth: 680)
                }

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
        .navigationTitle("New")
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

/// The backtick glyph, drawn plainly.
struct BacktickMark: View {
    var size: CGFloat = 44
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: size * 0.16, height: size * 0.56)
            .rotationEffect(.degrees(-32))
            .frame(width: size, height: size)
    }
}
