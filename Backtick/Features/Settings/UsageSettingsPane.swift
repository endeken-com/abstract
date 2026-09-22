import Charts
import SwiftUI
import BacktickCore

/// Tokens, cost and time per agent, and a daily trend.
struct UsageSettingsPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("usageRange") private var range: UsageRange = .week
    @State private var metric: UsageMetric = .tokens
    @State private var summaries: [UsageSummary] = []
    @State private var days: [UsageDay] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Period") {
                    Picker("Period", selection: $range) {
                        ForEach(UsageRange.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Section {
                if summaries.isEmpty {
                    Text("No usage recorded \(range.phrase).")
                        .font(.btCallout)
                        .foregroundStyle(Color.btTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Space.lg)
                } else {
                    UsageTable(summaries: summaries)
                }
            } header: {
                Text("By agent")
            } footer: {
                SettingsCaption("Cost is what each agent reports. On a subscription plan it's informational, not what you're billed.")
            }

            Section {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        Text(metric == .tokens ? "Output tokens per day" : "Reported cost per day")
                            .font(.btBodyMedium)
                            .foregroundStyle(Color.btText)
                        Spacer()
                        Picker("Metric", selection: $metric) {
                            Text("Tokens").tag(UsageMetric.tokens)
                            Text("Cost").tag(UsageMetric.cost)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                    }
                    UsageChart(points: points, metric: metric)
                        .frame(height: 150)
                }
                .padding(.vertical, Space.xs)
            }
        }
        .settingsPane()
        .task(id: range) { load() }
        .onChange(of: model.sessions) { _, _ in load() }
    }

    private func load() {
        let since = range.since()
        summaries = (try? model.store.usageSummary(since: since, projectId: nil)) ?? []
        days = (try? model.store.usageByDay(since: since)) ?? []
    }

    /// One point per calendar day in the range, zero-filled, providers summed.
    private var points: [UsagePoint] {
        let calendar = Calendar.current
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd"

        var totals: [Date: (tokens: Int, cost: Double)] = [:]
        for d in days {
            guard let date = parser.date(from: d.day).map({ calendar.startOfDay(for: $0) }) else { continue }
            let t = totals[date] ?? (0, 0)
            totals[date] = (t.tokens + d.outputTokens, t.cost + d.costUsd)
        }
        let today = calendar.startOfDay(for: Date())
        let start = range.since().map { calendar.startOfDay(for: $0) } ?? totals.keys.min() ?? today
        var result: [UsagePoint] = []
        var day = start
        while day <= today {
            let t = totals[day] ?? (0, 0)
            result.append(UsagePoint(day: day, tokens: t.tokens, cost: t.cost))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

enum UsageRange: String, CaseIterable {
    case today, week, month, all

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .all: "All Time"
        }
    }

    var phrase: String {
        switch self {
        case .today: "today"
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        case .all: "yet"
        }
    }

    /// Start of the range: midnight today, or midnight 6 / 29 days ago.
    func since(now: Date = Date()) -> Date? {
        let today = Calendar.current.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return Calendar.current.date(byAdding: .day, value: -6, to: today)
        case .month: return Calendar.current.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

private enum UsageMetric: Hashable { case tokens, cost }

private struct UsagePoint: Identifiable {
    var id: Date { day }
    let day: Date
    let tokens: Int
    let cost: Double
}

private struct UsageTable: View {
    let summaries: [UsageSummary]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: Space.md, verticalSpacing: Space.sm) {
            GridRow {
                header("Agent").gridColumnAlignment(.leading)
                header("Chats")
                header("Turns")
                header("Input")
                header("Output")
                header("Cost")
                header("Time")
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(summaries, id: \.providerId) { s in row(s) }
            if summaries.count > 1 {
                Divider().gridCellUnsizedAxes(.horizontal)
                row(total, isTotal: true)
            }
        }
        .padding(.vertical, Space.xs)
    }

    private var total: UsageSummary {
        summaries.dropFirst().reduce(summaries[0]) { a, b in
            UsageSummary(providerId: "", sessions: a.sessions + b.sessions, turns: a.turns + b.turns, usage: a.usage + b.usage,
                         costUsd: a.costUsd + b.costUsd, durationMs: a.durationMs + b.durationMs)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.btCaptionMedium).foregroundStyle(Color.btTextTertiary)
    }

    private func row(_ s: UsageSummary, isTotal: Bool = false) -> some View {
        let input = s.usage.inputTokens + s.usage.cacheRead + s.usage.cacheWrite
        return GridRow {
            HStack(spacing: 7) {
                if isTotal {
                    Text("Total").font(.btBodyMedium).foregroundStyle(Color.btText)
                } else {
                    ProviderLogo(providerId: s.providerId, size: 16)
                    Text(ProviderRegistry.name(s.providerId)).font(.btBodyMedium).foregroundStyle(Color.btText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridColumnAlignment(.leading)
            cell("\(s.sessions)", isTotal)
            cell("\(s.turns)", isTotal)
            cell(RelativeTime.tokens(input), isTotal)
                .help("\(s.usage.inputTokens.formatted()) fresh · \(s.usage.cacheRead.formatted()) cache read · \(s.usage.cacheWrite.formatted()) cache write")
            cell(RelativeTime.tokens(s.usage.outputTokens), isTotal)
            cell(s.costUsd.formatted(.currency(code: "USD").precision(.fractionLength(2))), isTotal)
            cell(s.durationMs > 0 ? RelativeTime.duration(s.durationMs) : "—", isTotal)
        }
    }

    private func cell(_ text: String, _ emphasised: Bool) -> some View {
        Text(text)
            .font(emphasised ? .btBodyMedium : .btBody)
            .foregroundStyle(emphasised ? Color.btText : Color.btTextSecondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}

private struct UsageChart: View {
    let points: [UsagePoint]
    let metric: UsageMetric

    var body: some View {
        let empty = points.allSatisfy { value($0) == 0 }
        Chart(points) { p in
            BarMark(
                x: .value("Day", p.day, unit: .day),
                y: .value(metric == .tokens ? "Output tokens" : "Cost", value(p)),
                width: points.count <= 2 ? .fixed(28) : .ratio(0.62)
            )
            .foregroundStyle(Color.accentColor)
            .cornerRadius(4, style: .continuous)
        }
        .chartYScale(domain: 0...(max(points.map(value).max() ?? 0, metric == .tokens ? 1000 : 1) * 1.1))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.btBorder)
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text(metric == .tokens ? RelativeTime.tokens(Int(n)) : n.formatted(.currency(code: "USD").precision(.fractionLength(0...2))))
                            .font(.btCaption)
                            .foregroundStyle(Color.btTextTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: points.count <= 8 ? .stride(by: .day) : .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextTertiary)
            }
        }
        .overlay {
            if empty {
                Text("No activity in this range")
                    .font(.btCallout)
                    .foregroundStyle(Color.btTextTertiary)
            }
        }
    }

    private func value(_ p: UsagePoint) -> Double {
        metric == .tokens ? Double(p.tokens) : p.cost
    }
}
