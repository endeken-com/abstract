import SwiftUI
import BacktickCore

enum SettingsTab: String, CaseIterable {
    case general, worktrees, agents, usage
}

/// The native Settings window (⌘,).
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            WorktreeSettingsPane()
                .tabItem { Label("Worktrees", systemImage: "arrow.triangle.branch") }
                .tag(SettingsTab.worktrees)
            AgentSettingsPane()
                .tabItem { Label("Agents", systemImage: "terminal") }
                .tag(SettingsTab.agents)
            UsageSettingsPane()
                .tabItem { Label("Usage", systemImage: "chart.bar.xaxis") }
                .tag(SettingsTab.usage)
        }
        .frame(width: 640)
    }
}

extension View {
    /// A grouped settings form that sizes to its content instead of
    /// scrolling, so the Settings window fits each pane.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 640)
    }
}

/// A caption under a settings row or section.
struct SettingsCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.btCaption)
            .foregroundStyle(Color.btTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("theme") private var theme: ThemeChoice = .graphite

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: Space.md) {
                    ForEach([ThemeChoice.graphite, .paper, .system]) { choice in
                        ThemeCard(choice: choice, selected: theme == choice) { theme = choice }
                    }
                }
                .padding(.vertical, Space.xs)
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle(isOn: $model.notifyAttention) {
                    Text("When an agent needs you")
                    Text("A permission prompt or a question is waiting in a chat.")
                }
                Toggle(isOn: $model.notifyFinished) {
                    Text("When an agent finishes")
                    Text("Its turn is over and it's ready for your review or a follow-up.")
                }
                Toggle(isOn: $model.notifyAutomationFailed) {
                    Text("When an automation fails")
                    Text("A scheduled run couldn't create its workspace or start its agent.")
                }
            } header: {
                Text("Notifications")
            }

            Section {
                LabeledContent {
                    TimeZoneField(identifier: $model.defaultTimezone)
                } label: {
                    Text("Default time zone")
                    Text("New automations are scheduled in this zone.")
                }
            } header: {
                Text("Automations")
            } footer: {
                SettingsCaption("Closing the window keeps Backtick running in the background so automations fire on time. Quitting Backtick (⌘Q) stops them until you open it again.")
            }
        }
        .settingsPane()
    }
}

/// A theme choice as a tiny mock of the window drawn in that theme. The
/// selected one gets a thin accent outline; nothing else frames it.
private struct ThemeCard: View {
    let choice: ThemeChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.sm) {
                preview
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.btBorderStrong, lineWidth: 0.5))
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md + 3, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                Text(choice.title)
                    .font(selected ? .btBodyMedium : .btBody)
                    .foregroundStyle(selected ? Color.btText : Color.btTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: selected)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        switch choice {
        case .graphite:
            WindowMock().environment(\.colorScheme, .dark)
        case .paper:
            WindowMock().environment(\.colorScheme, .light)
        case .system:
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    WindowMock().environment(\.colorScheme, .light)
                    WindowMock().environment(\.colorScheme, .dark)
                        .mask(alignment: .trailing) { Rectangle().frame(width: geo.size.width / 2) }
                }
            }
        }
    }
}

/// Sidebar, a heading, a few lines and an accent button, in theme colours.
private struct WindowMock: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Circle().fill(Color.btRemoved).frame(width: 5, height: 5)
                    Circle().fill(Color.btWarning).frame(width: 5, height: 5)
                    Circle().fill(Color.btAdded).frame(width: 5, height: 5)
                }
                .padding(.bottom, 4)
                bar(Color.btTextTertiary.opacity(0.5), width: 30)
                bar(Color.btText.opacity(0.55), width: 38)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 3)
                    .background(Color.btSelection, in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                    .padding(.horizontal, -3)
                bar(Color.btTextTertiary.opacity(0.5), width: 26)
                bar(Color.btTextTertiary.opacity(0.5), width: 34)
            }
            .padding(7)
            .frame(width: 58, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.btSidebar)

            Rectangle().fill(Color.btBorder).frame(width: 0.5)

            VStack(alignment: .leading, spacing: 5) {
                bar(Color.btText.opacity(0.8), width: 48, height: 4.5)
                bar(Color.btTextSecondary.opacity(0.45), width: 70)
                Rectangle().fill(Color.btBorder).frame(height: 0.5).padding(.vertical, 2)
                bar(Color.btTextSecondary.opacity(0.5), width: 58)
                bar(Color.btTextTertiary.opacity(0.45), width: 44)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Capsule().fill(Color.accentColor).frame(width: 22, height: 7)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.btCanvas)
        }
    }

    private func bar(_ color: Color, width: CGFloat, height: CGFloat = 3.5) -> some View {
        Capsule().fill(color).frame(width: width, height: height)
    }
}
