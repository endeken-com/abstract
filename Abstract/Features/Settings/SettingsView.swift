import SwiftUI
import AbstractCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance, notifications, usage
    case general, worktrees, agents, integrations
    case devices, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .usage: "Usage"
        case .general: "General"
        case .worktrees: "Git & Worktrees"
        case .agents: "Agents"
        case .integrations: "Integrations"
        case .devices: "Devices"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .notifications: "bell"
        case .usage: "chart.bar.xaxis"
        case .general: "gearshape"
        case .worktrees: "arrow.triangle.branch"
        case .agents: "terminal"
        case .integrations: "link"
        case .devices: "laptopcomputer.and.iphone"
        case .advanced: "flask"
        }
    }

    /// The sidebar's groups, in order.
    static let groups: [(title: String, tabs: [SettingsTab])] = [
        ("Personal", [.appearance, .notifications, .usage]),
        ("Workflow", [.general, .worktrees, .agents, .integrations]),
        ("System", [.devices, .advanced]),
    ]
}

/// Settings as a panel over the window (⌘,), like ⌘K: sections on the left,
/// the section on the right. Esc or a click outside closes it.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsTab") private var tab: SettingsTab = .general

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Settings")
                            .font(BTFont.ui(13, .semibold))
                            .foregroundStyle(Color.btText)
                            .padding(.horizontal, Rail.rowPadding)
                            .padding(.bottom, Space.sm)
                        ForEach(SettingsTab.groups, id: \.title) { group in
                            Text(group.title.uppercased())
                                .font(BTFont.ui(10.5, .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Color.btTextTertiary)
                                .padding(.horizontal, Rail.rowPadding)
                                .padding(.top, Space.md)
                                .padding(.bottom, 2)
                            ForEach(group.tabs) { item in
                                Button { tab = item } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: item.symbol)
                                            .font(.system(size: 12, weight: .medium))
                                            .frame(width: Rail.iconColumn)
                                        Text(item.title).font(BTFont.ui(13))
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(tab == item ? Color.btText : Color.btTextSecondary)
                                    .padding(.horizontal, Rail.rowPadding)
                                    .frame(height: Rail.rowHeight)
                                }
                                .buttonStyle(RailRowStyle(selected: tab == item))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Space.md)
                    .padding(.top, Space.xs)
                    .frame(width: 190)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.btSidebar)

                    Rectangle().fill(Color.btBorder).frame(width: 1)

                    ScrollView {
                        pane
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .btThinScrollIndicator()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.btCanvas)
                }
                // Nearly the whole window: settings are read, not glanced at.
                .frame(width: max(geo.size.width - 64, 0), height: max(geo.size.height - 64, 0))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .btRaised(radius: 14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onKeyPress(.escape) { close(); return .handled }
        .focusable()
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .appearance: AppearanceSettingsPane()
        case .notifications: NotificationSettingsPane()
        case .advanced: AdvancedSettingsPane()
        case .general: GeneralSettingsPane()
        case .worktrees: WorktreeSettingsPane()
        case .agents: AgentSettingsPane()
        case .integrations: IntegrationsSettingsPane()
        case .devices: DevicesSettingsPane()
        case .usage: UsageSettingsPane()
        }
    }

    private func close() { model.isSettingsOpen = false }
}

extension View {
    /// A grouped settings form that sizes to its content; the Settings panel
    /// scrolls around it.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
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

private struct AppearanceSettingsPane: View {
    @AppStorage("theme") private var theme: ThemeChoice = .graphite
    @AppStorage("chat.font") private var chatFont: ChatFont = .inter
    @AppStorage("chat.textSize") private var chatSize: ChatTextSize = .medium

    var body: some View {
        Form {
            Section {
                HStack(spacing: Space.md) {
                    ForEach([ThemeChoice.graphite, .paper, .system]) { choice in
                        ThemeCard(choice: choice, selected: theme == choice) { theme = choice }
                    }
                }
                .padding(.vertical, Space.xs)
            } header: {
                Text("Theme")
            }
            InterfaceFontSection()
            EditorFontSection()
            Section {
                Picker(selection: $chatFont) {
                    ForEach(ChatFont.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Chat font")
                    Text("How the agent's answers are set.")
                }
                Picker("Chat text size", selection: $chatSize) {
                    ForEach(ChatTextSize.allCases) { Text($0.title).tag($0) }
                }
                ChatTextSample(style: ProseStyle(font: chatFont, size: chatSize))
            } header: {
                Text("Chat text")
            }
        }
        .settingsPane()
    }
}

private struct NotificationSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
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
                Text("Notify me")
            }
        }
        .settingsPane()
    }
}

private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("chat.transcript") private var transcript: TranscriptMode = .normal

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(selection: $transcript) {
                    ForEach(TranscriptMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Transcript")
                    Text(transcript.detail)
                }
                Picker(selection: $model.outputStyle) {
                    ForEach(OutputStyle.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Output style")
                    Text(model.outputStyle.detail)
                }
            } header: {
                Text("Chat")
            } footer: {
                SettingsCaption("A new output style applies to running chats from their next message.")
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
                SettingsCaption("Closing the window keeps Abstract running in the background so automations fire on time. Quitting Abstract (⌘Q) stops them until you open it again.")
            }

            UpdatesSection()
        }
        .settingsPane()
    }
}

private struct UpdatesSection: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section {
            Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                Text("Check for updates automatically")
                Text("Abstract looks for a new version once a day.")
            }
            Toggle(isOn: $updater.automaticallyDownloadsUpdates) {
                Text("Download and install automatically")
                Text("Updates install when you quit Abstract.")
            }
            .disabled(!updater.automaticallyChecksForUpdates)
            Picker(selection: $updater.channel) {
                ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
            } label: {
                Text("Channel")
                Text(updater.channel.detail)
            }
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } label: {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                Text(lastChecked)
            }
        } header: {
            Text("Updates")
        } footer: {
            SettingsCaption(updater.isEnabled
                ? "Nightly builds come from main every day and may be unstable. Switching back to Stable takes effect once a stable release newer than your nightly comes out."
                : "Updates are off in development and demo builds.")
        }
        .disabled(!updater.isEnabled)
        .onAppear { updater.refreshSettings() }
    }

    private var lastChecked: String {
        guard let date = updater.lastUpdateCheckDate else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct AdvancedSettingsPane: View {
    @AppStorage("showRawAgentOutput") private var showRawAgentOutput = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showRawAgentOutput) {
                    Text("Show raw agent output")
                    Text("Include lines the agent printed that Abstract doesn't recognise. Useful when debugging a provider.")
                }
            } header: {
                Text("Developer")
            }
        }
        .settingsPane()
    }
}

/// A line of prose in the chosen chat font and size.
private struct ChatTextSample: View {
    let style: ProseStyle
    var body: some View {
        Text("Rows now derive their status from the process, so a chat whose agent stopped shows Error rather than a stale Working.")
            .font(style.body)
            .lineSpacing(style.lineSpacing)
            .foregroundStyle(Color.btProse)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Space.xs)
            .animation(.snappy(duration: 0.15), value: style)
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
                            .strokeBorder(selected ? Color.btAccent : .clear, lineWidth: 1.5)
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
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.btTextTertiary.opacity(0.6)).frame(width: 5, height: 5) }
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
                    Capsule().fill(Color.btAccent).frame(width: 22, height: 7)
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
