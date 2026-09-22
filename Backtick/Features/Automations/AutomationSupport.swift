import SwiftUI
import BacktickCore

// MARK: - Actions

extension AppModel {
    /// Persist an automation: stamps `updatedAt`, recomputes `nextRunAt`
    /// (cleared while paused), reloads and wakes the scheduler.
    @discardableResult
    func saveAutomation(_ automation: Automation) throws -> Automation {
        var a = automation
        a.updatedAt = Date()
        a.nextRunAt = a.enabled
            ? try Schedule.nextOccurrence(rrule: a.rrule, timezone: a.timezone, dtstart: a.dtstart, after: Date())
            : nil
        try store.save(a)
        reload()
        scheduler?.poke()
        return a
    }

    /// Pausing clears the next fire; resuming computes it from now.
    func setAutomationEnabled(_ id: String, _ enabled: Bool) {
        guard var a = automations.first(where: { $0.id == id }), a.enabled != enabled else { return }
        a.enabled = enabled
        do {
            try saveAutomation(a)
        } catch {
            flash(error.localizedDescription, isError: true)
        }
    }

    /// Removes the automation and its run history. Chats and worktrees it
    /// created stay.
    func deleteAutomation(_ id: String) {
        do {
            try store.deleteAutomation(id)
        } catch {
            flash(error.localizedDescription, isError: true)
            return
        }
        reload()
        scheduler?.poke()
    }

    func runAutomationNow(_ a: Automation) async -> AutomationRun? {
        guard let scheduler else {
            flash("Automations aren't running yet. Try again in a moment.", isError: true)
            return nil
        }
        let run = await scheduler.fire(a, trigger: .manual)
        if run.status == .failed {
            flash("“\(a.name)” failed: \(run.error ?? "unknown error")", isError: true)
        } else {
            flash("“\(a.name)” started")
        }
        return run
    }

    func automationRuns(_ automationId: String, limit: Int = 50) -> [AutomationRun] {
        (try? store.runs(automationId: automationId, limit: limit)) ?? []
    }
}

// MARK: - Presentation

extension RunStatus {
    var label: String {
        switch self {
        case .creating: "Creating"
        case .created: "Created"
        case .failed: "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .creating: .accentColor
        case .created: .btAdded
        case .failed: .btRemoved
        }
    }

    var symbol: String {
        switch self {
        case .creating: "circle.dotted"
        case .created: "checkmark.circle.fill"
        case .failed: "exclamationmark.octagon.fill"
        }
    }
}

extension RunTrigger {
    var label: String {
        switch self {
        case .schedule: "Scheduled"
        case .manual: "Manual"
        }
    }
}

extension SchedulePreset {
    var title: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .custom: "Custom"
        }
    }
}

enum AutomationText {
    /// 24-hour wall-clock time, matching `Schedule.describe` ("09:00").
    static func time(_ date: Date, in timeZone: TimeZone = .current) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: timeZone, calendar: Calendar(identifier: .gregorian)))
    }

    /// "Today", "Tomorrow" or "Thu, Sep 24", in the given time zone.
    static func day(_ date: Date, in timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "today", "tomorrow" or "on Thu, Sep 24", to follow a verb.
    static func dayPhrase(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let day = day(date, in: timeZone)
        return ["Today", "Tomorrow", "Yesterday"].contains(day) ? day.lowercased() : "on \(day)"
    }

    /// "in 3h", "Paused", or "No upcoming runs".
    static func next(_ a: Automation, now: Date = Date()) -> String {
        guard a.enabled else { return "Paused" }
        guard let next = a.nextRunAt else { return "No upcoming runs" }
        return next <= now ? "Due now" : RelativeTime.short(next, now: now)
    }

    /// The schedule in words, with the time zone when it isn't this Mac's.
    static func schedule(_ a: Automation) -> String {
        let text = Schedule.describe(rrule: a.rrule)
        return a.timezone == TimeZone.current.identifier ? text : "\(text) · \(TimeZoneField.city(a.timezone))"
    }
}

/// A run's outcome as a dot and a word. Failures read in red; the rest is calm.
struct RunStatusLabel: View {
    let status: RunStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.tint).frame(width: 6, height: 6)
            Text(status.label)
        }
        .font(.btCaptionMedium)
        .foregroundStyle(status == .failed ? status.tint : Color.btTextSecondary)
    }
}

// MARK: - Form chrome

/// One row of a left-labelled form laid out in a `Grid`: the label sits in
/// the trailing-aligned first column, the control and its caption in the
/// second.
struct AutoFormRow<Content: View>: View {
    let label: String
    var caption: String? = nil
    var captionTint: Color = .btTextTertiary
    @ViewBuilder var content: () -> Content

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.btBody)
                .foregroundStyle(Color.btTextSecondary)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 6) {
                content()
                if let caption {
                    Text(caption)
                        .font(.btCaption)
                        .foregroundStyle(captionTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A section heading spanning the whole form grid, preceded by a hairline.
struct AutoFormSection: View {
    let title: String
    var first = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if !first { Hairline().padding(.top, Space.sm) }
            Text(title)
                .font(.btBodyMedium.weight(.semibold))
                .foregroundStyle(Color.btText)
        }
        .gridCellUnsizedAxes(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Time zone picker

/// A pop-up style button that opens a searchable list of every known time zone.
struct TimeZoneField: View {
    @Binding var identifier: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(Self.city(identifier)).foregroundStyle(Color.btText)
                Text(Self.offset(identifier)).foregroundStyle(Color.btTextSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.btTextSecondary)
            }
            .lineLimit(1)
        }
        .fixedSize()
        .help(identifier)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TimeZoneList(selection: $identifier) { open = false }
        }
    }

    /// "New York" for "America/New_York".
    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// "America" for "America/New_York"; empty for "UTC".
    static func region(_ identifier: String) -> String {
        let parts = identifier.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: " › ").replacingOccurrences(of: "_", with: " ") : ""
    }

    /// "GMT+1", "GMT−5:30", "GMT".
    static func offset(_ identifier: String, at date: Date = Date()) -> String {
        guard let tz = TimeZone(identifier: identifier) else { return "" }
        let seconds = tz.secondsFromGMT(for: date)
        if seconds == 0 { return "GMT" }
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        return "GMT" + (seconds < 0 ? "−" : "+") + (minutes == 0 ? "\(hours)" : String(format: "%d:%02d", hours, minutes))
    }
}

private struct TimeZoneList: View {
    @Binding var selection: String
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let all = TimeZone.knownTimeZoneIdentifiers.sorted()

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Self.all }
        let spaced = q.replacingOccurrences(of: " ", with: "_")
        return Self.all.filter {
            $0.localizedCaseInsensitiveContains(q) || $0.localizedCaseInsensitiveContains(spaced)
                || (TimeZone(identifier: $0)?.abbreviation()?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.btTextTertiary)
                TextField("Search time zones", text: $query)
                    .textFieldStyle(.plain)
                    .font(.btBody)
                    .focused($searchFocused)
                    .onSubmit { if let first = matches.first { pick(first) } }
            }
            .padding(.horizontal, Space.md)
            .frame(height: 38)
            Hairline()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if query.isEmpty, TimeZone.current.identifier != selection {
                            row(TimeZone.current.identifier, note: "This Mac")
                            Hairline().padding(.vertical, 4)
                        }
                        ForEach(matches, id: \.self) { id in row(id).id(id) }
                        if matches.isEmpty {
                            Text("No time zone matches “\(query)”")
                                .font(.btCallout)
                                .foregroundStyle(Color.btTextTertiary)
                                .padding(.vertical, Space.xl)
                        }
                    }
                    .padding(6)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 320, height: 360)
        .background(Color.btSurfaceRaised)
        .onAppear { searchFocused = true }
    }

    private func row(_ id: String, note: String? = nil) -> some View {
        Button { pick(id) } label: {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(TimeZoneField.city(id)).font(.btBody).foregroundStyle(Color.btText)
                    let region = [note, TimeZoneField.region(id)].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                    if !region.isEmpty {
                        Text(region).font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    }
                }
                Spacer(minLength: Space.sm)
                Text(TimeZoneField.offset(id)).font(.btMonoSmall).foregroundStyle(Color.btTextSecondary)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(id == selection ? 1 : 0)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 5)
        }
        .buttonStyle(RowButtonStyle(selected: id == selection))
    }

    private func pick(_ id: String) {
        selection = id
        dismiss()
    }
}
