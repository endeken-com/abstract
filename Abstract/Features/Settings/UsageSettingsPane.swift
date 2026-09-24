import Charts
import SwiftUI
import AppKit
import AbstractCore

/// Accounts and their plan limits, then what the agents used: every Claude
/// Code profile and Codex, from their own logs, priced at API rates.
struct UsageSettingsPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("usage.hideEmails") private var hideEmails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                AccountsSection(hideEmails: $hideEmails)
                Hairline()
                TokenUsageSection()
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Limits move as agents work; re-read every few minutes while this is open.
            while !Task.isCancelled {
                await model.accounts.refresh(executor: model.executor)
                await model.usage.load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}

extension Color {
    fileprivate static func provider(_ provider: LocalUsage.Provider?) -> Color {
        provider == .codex ? .btUsageCodex : .btUsageClaude
    }
}

// MARK: - Accounts

private struct AccountsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var hideEmails: Bool
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let accounts = model.accounts
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.md) {
                Text("Accounts").font(.btTitle).foregroundStyle(Color.btText)
                Spacer(minLength: Space.md)
                Text(accounts.refreshedAt.map { "Limits as each agent last reported them, checked \(RelativeTime.short($0)) ago" } ?? "Checking accounts…")
                    .font(.btCaption).foregroundStyle(Color.btTextTertiary)
                Button { hideEmails.toggle() } label: {
                    Label(hideEmails ? "Show emails" : "Hide emails", systemImage: hideEmails ? "eye" : "eye.slash")
                }
                .buttonStyle(.bt(.ghost, size: .small))
                Button { Task { await accounts.refresh(executor: model.executor) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.icon(size: 26))
                    .help("Check again")
            }

            ProviderHeading(providerId: "claude", title: "Claude Code") {
                Button { naming = true } label: { Label("Add account", systemImage: "plus") }
                    .buttonStyle(.bt(.ghost, size: .small))
                    .popover(isPresented: $naming, arrowEdge: .bottom) { addAccount }
            }
            CardGrid {
                ForEach(accounts.claude) { account in
                    ClaudeAccountCard(account: account, hideEmails: hideEmails)
                }
            }

            if accounts.codex != nil || accounts.codexQuota != nil {
                ProviderHeading(providerId: "codex", title: "Codex") { EmptyView() }
                CardGrid { CodexAccountCard(hideEmails: hideEmails) }
            }
        }
    }

    private var addAccount: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("New Claude Code profile").font(.btBodyMedium)
            Text("Each profile signs in to its own account and keeps its own history.")
                .font(.btCallout).foregroundStyle(Color.btTextSecondary).fixedSize(horizontal: false, vertical: true)
            BTTextField("Name", text: $newName, prompt: "e.g. work", onSubmit: create)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }.buttonStyle(.bt(.ghost, size: .small))
                Button("Create", action: create).buttonStyle(.bt(.primary, size: .small))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Space.lg)
        .frame(width: 300)
    }

    private func create() {
        guard let profile = model.accounts.addProfile(named: newName) else { return }
        copy(ClaudeAccounts.loginCommand(profile))
        model.flash("Profile made. Its sign-in command is copied; run it in a terminal.")
        newName = ""
        naming = false
    }
}

private struct ProviderHeading<Accessory: View>: View {
    let providerId: String
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Space.sm) {
            ProviderLogo(providerId: providerId, size: 16)
            Text(title).font(BTFont.ui(15, .medium)).foregroundStyle(Color.btText)
            Spacer(minLength: Space.md)
            accessory
        }
    }
}

private struct CardGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: Space.lg, alignment: .top)], alignment: .leading, spacing: Space.lg) {
            content
        }
    }
}

/// An account as a card: who, which plan, whether its sign-in works, and
/// how much of its limits is used.
private struct AccountCard<Menu: View, Footer: View, Content: View>: View {
    let email: String?
    let plan: String?
    let problem: String?
    let path: String
    let hideEmails: Bool
    @ViewBuilder var menu: Menu
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text(email.map { hideEmails ? Self.masked($0) : $0 } ?? "Not signed in")
                    .font(BTFont.ui(14, .medium)).foregroundStyle(Color.btText).lineLimit(1).truncationMode(.middle)
                if let plan { Tag(text: plan.uppercased()) }
                if let problem { Tag(text: problem.uppercased(), emphasis: true) }
                Spacer(minLength: Space.sm)
                Text((path as NSString).abbreviatingWithTildeInPath).font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1).truncationMode(.head)
                SwiftUI.Menu { menu } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.icon(size: 24)).menuIndicator(.hidden).fixedSize()
            }
            content
            Hairline()
            footer
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.btSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// `w••••@nursa.com`: the domain says which account, the name stays private.
    static func masked(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "••••" }
        return String(email.prefix(1)) + "••••" + email[at...]
    }
}

private struct Tag: View {
    let text: String
    var emphasis = false

    var body: some View {
        Text(text)
            .font(BTFont.ui(10.5, .semibold)).tracking(0.4)
            .foregroundStyle(emphasis ? Color.btText : Color.btTextSecondary)
            .padding(.horizontal, 6).frame(height: 18)
            .background(emphasis ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}

private struct ClaudeAccountCard: View {
    @Environment(AppModel.self) private var model
    let account: AccountsStore.ClaudeAccount
    let hideEmails: Bool

    private var isDefault: Bool { (model.claudeProfile ?? model.accounts.standardProfilePath) == account.id }

    var body: some View {
        AccountCard(email: account.profile.email, plan: account.profile.plan, problem: problem, path: account.profile.path,
                    hideEmails: hideEmails) {
            if !isDefault { Button("Make Default for New Agents", action: makeDefault) }
            Button("Copy Sign-In Command") { copy(ClaudeAccounts.loginCommand(account.profile)) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: account.profile.path)]) }
        } content: {
            switch account.status {
            case .checking:
                QuotaRows(quota: account.quota)
            case .signedIn:
                QuotaRows(quota: account.quota)
            case .expired, .signedOut:
                SignInHint(expired: account.status == .expired, command: ClaudeAccounts.loginCommand(account.profile))
            }
        } footer: {
            DefaultFooter(isDefault: isDefault, makeDefault: makeDefault) { EmptyView() }
        }
    }

    private var problem: String? {
        switch account.status {
        case .expired: "Sign-in expired"
        case .signedOut: "Signed out"
        default: nil
        }
    }

    private func makeDefault() {
        model.claudeProfile = account.profile.isStandard ? nil : account.profile.path
    }
}

private struct CodexAccountCard: View {
    @Environment(AppModel.self) private var model
    let hideEmails: Bool

    var body: some View {
        let accounts = model.accounts
        AccountCard(email: accounts.codex?.email, plan: accounts.codex?.plan, problem: accounts.codex == nil ? "Signed out" : nil,
                    path: NSHomeDirectory() + "/.codex", hideEmails: hideEmails) {
            Button("Copy Sign-In Command") { copy("codex login") }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSHomeDirectory() + "/.codex")]) }
        } content: {
            QuotaRows(quota: accounts.codexQuota)
        } footer: {
            DefaultFooter(isDefault: true, makeDefault: {}) {
                if let credits = accounts.codexQuota?.credits, let value = Double(credits) {
                    Text("\(UsageFormat.cost(value)) credits").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
            }
        }
    }
}

private struct DefaultFooter<Trailing: View>: View {
    let isDefault: Bool
    let makeDefault: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            if isDefault {
                Label("Default for new agents", systemImage: "checkmark.circle")
                    .font(.btCallout).foregroundStyle(Color.btText)
            } else {
                Button("Make Default", action: makeDefault).buttonStyle(.bt(.secondary, size: .small))
            }
            Spacer(minLength: Space.sm)
            trailing
        }
        .frame(minHeight: 26)
    }
}

private struct SignInHint: View {
    let expired: Bool
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(expired ? "Its sign-in expired. Run this in a terminal on this Mac:" : "Not signed in yet. Run this in a terminal on this Mac:")
                .font(.btCallout).foregroundStyle(Color.btTextSecondary)
            HStack(spacing: Space.sm) {
                Text(command).font(.btMonoSmall).foregroundStyle(Color.btText).textSelection(.enabled).lineLimit(2)
                Button { copy(command) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.icon(size: 22)).help("Copy")
            }
        }
    }
}

/// The five-hour and weekly windows as quiet bars, with when each resets.
private struct QuotaRows: View {
    let quota: AccountQuota?

    var body: some View {
        if let quota, quota.session != nil || quota.weekly != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let session = quota.session { QuotaRow(title: "Session (5h)", window: session) }
                if let weekly = quota.weekly { QuotaRow(title: "Weekly", window: weekly) }
                Text("Reported \(RelativeTime.short(quota.observedAt)) ago")
                    .font(.btCaption).foregroundStyle(Color.btTextTertiary)
            }
        } else {
            Text("No limits reported yet. They appear once this account's agent runs.")
                .font(.btCallout).foregroundStyle(Color.btTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct QuotaRow: View {
    let title: String
    let window: AccountQuota.Window

    var body: some View {
        // A window that has reset since the report starts over at zero.
        let reset = window.resetsAt.map { $0 < Date() } ?? false
        let used = reset ? 0 : window.used
        HStack(spacing: Space.md) {
            Text(title).font(.btCallout).foregroundStyle(Color.btTextSecondary).frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.btHover)
                    Capsule().fill(used >= 0.9 ? Color.btRemoved : Color.btTextSecondary)
                        .frame(width: max(3, geo.size.width * min(max(used, 0), 1)))
                }
            }
            .frame(height: 4)
            Text(UsageFormat.percent(used)).font(.btCallout).monospacedDigit().foregroundStyle(Color.btText)
                .frame(width: 40, alignment: .trailing)
            HStack(spacing: 3) {
                if !reset {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                    Text(window.resetsAt.map(Self.until) ?? "").monospacedDigit()
                }
            }
            .font(.btCaption).foregroundStyle(Color.btTextTertiary)
            .frame(width: 58, alignment: .trailing)
            .help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
    }

    /// `5h`, `6d 9h`, `42m`: time until the window resets.
    static func until(_ date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        let (d, h, m) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Token usage

private struct TokenUsageSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("usage.days") private var days = 30
    @AppStorage("usage.metric") private var metric: UsageReport.Metric = .cost
    @State private var allWorkspaces = false
    /// Rebuilt when the ledger reloads or the period changes, not on every redraw.
    @State private var report: UsageReport?

    var body: some View {
        let ledger = model.usage
        let report = self.report ?? UsageReport(records: [], days: days, workspaceName: { $0 })
        VStack(alignment: .leading, spacing: Space.xl) {
            header(report)
            if ledger.records.isEmpty {
                HStack(spacing: Space.sm) {
                    if ledger.loading { ProgressView().controlSize(.small) }
                    Text(ledger.loading ? "Reading the agents' session logs… the first time takes a moment." : "No agent usage found on this Mac yet.")
                        .font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                .padding(.vertical, Space.xl)
            } else {
                overview(report)
                Hairline()
                stats(report)
                Hairline()
                HStack(alignment: .top, spacing: Space.xxl) {
                    ModelTable(report: report)
                    WorkspaceTable(report: report, all: $allWorkspaces)
                }
            }
        }
        .task(id: "\(ledger.loadedAt?.timeIntervalSince1970 ?? 0)-\(days)") {
            self.report = UsageReport(records: ledger.records, days: days, workspaceName: model.workspaceName)
        }
    }

    private func header(_ report: UsageReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text("Token usage").font(.btTitle).foregroundStyle(Color.btText)
            Text("\(report.start.formatted(.dateTime.month(.abbreviated).day())) – \(report.end.formatted(.dateTime.month(.abbreviated).day())), API-rate estimate from local session logs")
                .font(.btCaption).foregroundStyle(Color.btTextTertiary)
            Spacer(minLength: Space.md)
            if model.usage.loading, !model.usage.records.isEmpty { ProgressView().controlSize(.small).scaleEffect(0.7) }
            Picker("Show", selection: $metric) {
                Text("Cost").tag(UsageReport.Metric.cost)
                Text("Tokens").tag(UsageReport.Metric.tokens)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("Period", selection: $days) {
                Text("7d").tag(7)
                Text("30d").tag(30)
                Text("90d").tag(90)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private func overview(_ report: UsageReport) -> some View {
        HStack(alignment: .top, spacing: Space.xxl) {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric == .cost ? UsageFormat.cost(report.cost) + "*" : UsageFormat.tokens(report.tokens.total))
                        .font(BTFont.ui(34, .semibold)).monospacedDigit().foregroundStyle(Color.btText)
                    Text(metric == .cost ? "* if billed at full API rate" : "tokens processed")
                        .font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    if metric == .cost {
                        Text("Cost to you: $0 on your subscriptions").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                            .padding(.top, 2)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.providers) { row in
                        HStack(spacing: Space.sm) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.provider(row.provider)).frame(width: 8, height: 8)
                            ProviderLogo(providerId: row.provider?.rawValue ?? "claude", size: 14)
                            Text(row.name).font(.btBody).foregroundStyle(Color.btText)
                            Spacer(minLength: Space.md)
                            Text(metric == .cost ? UsageFormat.cost(row.cost) : UsageFormat.tokens(row.tokens.total))
                                .font(.btBody).monospacedDigit().foregroundStyle(Color.btText)
                            Text(UsageFormat.percent(share(row, report))).font(.btCallout).monospacedDigit()
                                .foregroundStyle(Color.btTextTertiary).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(width: 280, alignment: .leading)
            UsageChart(report: report, metric: metric)
                .frame(height: 200)
        }
    }

    private func share(_ row: UsageReport.Row, _ report: UsageReport) -> Double {
        metric == .cost ? (report.cost > 0 ? row.cost / report.cost : 0)
            : (report.tokens.total > 0 ? Double(row.tokens.total) / Double(report.tokens.total) : 0)
    }

    private func stats(_ report: UsageReport) -> some View {
        let t = report.tokens
        let input = t.input + t.cacheRead + t.cacheWrite
        return HStack(alignment: .top, spacing: 0) {
            Stat(title: "Processed tokens", value: UsageFormat.tokens(t.total))
            Stat(title: "Cached input", value: UsageFormat.tokens(t.cacheRead),
                 detail: input > 0 ? UsageFormat.percent(Double(t.cacheRead) / Double(input)) : nil)
            Stat(title: "Uncached input", value: UsageFormat.tokens(t.input + t.cacheWrite))
            Stat(title: "Output", value: UsageFormat.tokens(t.output))
            Stat(title: "Cache savings", value: UsageFormat.cost(report.savings),
                 detail: report.cost > 0 ? String(format: "%.1fx", report.savings / report.cost) : nil)
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.btCallout).foregroundStyle(Color.btTextSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(BTFont.ui(20, .medium)).monospacedDigit().foregroundStyle(Color.btText)
                if let detail { Text(detail).font(.btCallout).monospacedDigit().foregroundStyle(Color.btTextTertiary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageChart: View {
    let report: UsageReport
    let metric: UsageReport.Metric

    var body: some View {
        Chart(report.series) { point in
            let value = metric == .cost ? point.cost : Double(point.tokens)
            AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Amount", value),
                     series: .value("Agent", point.provider.rawValue), stacking: .unstacked)
                .foregroundStyle(Color.provider(point.provider).opacity(0.12))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Day", point.day, unit: .day), y: .value("Amount", value),
                     series: .value("Agent", point.provider.rawValue))
                .foregroundStyle(by: .value("Agent", point.provider.rawValue))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
        }
        .chartForegroundStyleScale(["claude": Color.btUsageClaude, "codex": Color.btUsageCodex])
        .chartLegend(.hidden)
        .chartXAxis {
            // First, middle and last day, the ends anchored inward so neither clips.
            AxisMarks(values: [report.start, Date(timeIntervalSince1970: (report.start.timeIntervalSince1970 + report.end.timeIntervalSince1970) / 2), report.end]) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                               anchor: value.index == 0 ? .topLeading : value.index == 2 ? .topTrailing : .top)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.btBorder)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(metric == .cost ? UsageFormat.cost(v) : UsageFormat.tokens(Int(v))) }
                }
            }
        }
    }
}

private struct ModelTable: View {
    let report: UsageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TableHeader(columns: [("Model", .leading), ("Cost", .trailing), ("Share", .trailing), ("Tokens", .trailing)])
            ForEach(report.models) { row in
                TableRow {
                    HStack(spacing: Space.sm) {
                        Circle().fill(Color.provider(row.provider)).frame(width: 7, height: 7)
                        Text(row.name).font(.btBody).foregroundStyle(Color.btText).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(UsageFormat.cost(row.cost) + (row.estimated ? "*" : "")).monospacedDigit().frame(width: 84, alignment: .trailing)
                        .help(row.estimated ? "No published price for this model is known here; estimated at GPT-5 rates." : "")
                    Text(UsageFormat.percent(report.cost > 0 ? row.cost / report.cost : 0)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        .foregroundStyle(Color.btTextSecondary)
                    Text(UsageFormat.tokens(row.tokens.total)).monospacedDigit().frame(width: 84, alignment: .trailing)
                        .foregroundStyle(Color.btTextSecondary)
                }
            }
            TableRow(divider: false) {
                Text("Total").font(.btBodyMedium).frame(maxWidth: .infinity, alignment: .leading)
                Text(UsageFormat.cost(report.cost)).frame(width: 84, alignment: .trailing)
                Text("100%").frame(width: 64, alignment: .trailing).foregroundStyle(Color.btTextSecondary)
                Text(UsageFormat.tokens(report.tokens.total)).frame(width: 84, alignment: .trailing).foregroundStyle(Color.btTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WorkspaceTable: View {
    let report: UsageReport
    @Binding var all: Bool

    var body: some View {
        let top = report.workspaces.first?.cost ?? 0
        let rows = all ? report.workspaces : Array(report.workspaces.prefix(8))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspace").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                Spacer()
                if report.workspaces.count > 8 {
                    Button(all ? "Top 8" : "All \(report.workspaces.count) →") { withAnimation(.snappy) { all.toggle() } }
                        .buttonStyle(.plain).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                Text("Cost").font(.btCallout).foregroundStyle(Color.btTextSecondary).frame(width: 84, alignment: .trailing)
            }
            .frame(height: 30)
            .overlay(alignment: .bottom) { Hairline() }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.name).font(.btBody).foregroundStyle(Color.btText).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.md)
                        Text(UsageFormat.tokens(row.tokens.total)).font(.btBody).monospacedDigit().foregroundStyle(Color.btTextSecondary)
                        Text(UsageFormat.cost(row.cost)).font(.btBody).monospacedDigit().foregroundStyle(Color.btText)
                            .frame(width: 84, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        Capsule().fill(Color.btTextTertiary.opacity(0.5))
                            .frame(width: max(2, geo.size.width * (top > 0 ? row.cost / top : 0)), height: 2)
                    }
                    .frame(height: 2)
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TableHeader: View {
    let columns: [(String, Alignment)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                Text(column.0).font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    .frame(width: index == 0 ? nil : (index == 2 ? 64 : 84), alignment: column.1)
                    .frame(maxWidth: index == 0 ? .infinity : nil, alignment: column.1)
            }
        }
        .frame(height: 30)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

private struct TableRow<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .font(.btBody)
            .frame(height: 36)
            // Rows run without rules; only the total sets itself off.
            .overlay(alignment: .top) { if !divider { Hairline() } }
    }
}
