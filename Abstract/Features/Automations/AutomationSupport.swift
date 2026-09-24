import SwiftUI
import AbstractCore

// MARK: - Actions

extension AppModel {
    /// Persist an automation: checks every trigger, stamps `updatedAt`,
    /// recomputes `nextRunAt` (the earliest next occurrence across its
    /// triggers, cleared while paused), reloads and wakes the scheduler.
    @discardableResult
    func saveAutomation(_ automation: Automation) throws -> Automation {
        var a = automation
        try a.validateTriggers()
        a.updatedAt = Date()
        a.nextRunAt = a.enabled ? a.nextOccurrence(after: Date()) : nil
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

    /// A paused copy, so the two never both fire before you've changed it.
    func duplicateAutomation(_ a: Automation) -> Automation? {
        var copy = a
        copy.id = UUID().uuidString
        copy.name = "\(a.name) copy"
        copy.triggers = a.triggers.map { AutomationTrigger(rrule: $0.rrule, timezone: $0.timezone, dtstart: $0.dtstart) }
        copy.enabled = false
        copy.createdAt = Date()
        do {
            let saved = try saveAutomation(copy)
            flash("Duplicated as “\(saved.name)”, paused")
            return saved
        } catch {
            flash(error.localizedDescription, isError: true)
            return nil
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
        case .creating: .btTextTertiary
        case .created: .btTextSecondary
        case .failed: .btRemoved
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
    /// How the preset starts a trigger's sentence.
    var phrase: String {
        switch self {
        case .hourly: "Every hour"
        case .daily: "Every day"
        case .weekdays: "Every weekday"
        case .weekly: "Every week"
        case .custom: "Custom rule"
        }
    }
}

extension PermissionPolicy {
    /// The policy as it reads inside the scope sentence ("… with edits accepted").
    var phrase: String {
        switch self {
        case .ask: "approval for each action"
        case .autoEdits: "edits accepted"
        case .bypass: "full autonomy"
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

    /// "today, 21:00", "tomorrow, 09:00" or "Thu, Sep 24, 09:00": a moment
    /// that follows other words.
    static func moment(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let day = day(date, in: timeZone)
        let lead = ["Today", "Tomorrow", "Yesterday"].contains(day) ? day.lowercased() : day
        return "\(lead), \(time(date, in: timeZone))"
    }

    /// "in 3h", "Paused", "Manual only" or "No upcoming runs".
    static func next(_ a: Automation, now: Date = Date()) -> String {
        guard a.enabled else { return "Paused" }
        guard !a.triggers.isEmpty else { return "Manual only" }
        guard let next = a.nextRunAt else { return "No upcoming runs" }
        return next <= now ? "Due now" : RelativeTime.short(next, now: now)
    }

    /// The first trigger in words, with its city when it isn't this Mac's
    /// zone, and how many more there are.
    static func schedule(_ a: Automation) -> String {
        guard let first = a.triggers.first else { return "Runs only when started by hand" }
        var text = Schedule.describe(rrule: first.rrule)
        if first.timezone != TimeZone.current.identifier { text += " · \(TimeZoneField.city(first.timezone))" }
        if a.triggers.count > 1 { text += " · +\(a.triggers.count - 1) more" }
        return text
    }
}

/// Where rows and labels line up on an automation page.
enum AutoPage {
    /// The document column.
    static let width: CGFloat = 760
    /// Room for a row's leading glyph; the row's words start here.
    static let gutter: CGFloat = 22
    /// How far a hover wash reaches past the text it sits behind.
    static let hang: CGFloat = 8
}

/// A small section heading on an automation page.
struct AutoSectionLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(title).font(.btSectionLabel).foregroundStyle(Color.btTextTertiary)
            Spacer(minLength: Space.sm)
            trailing()
        }
        .frame(height: 24)
    }
}

extension AutoSectionLabel where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: - Sentence chips

/// A value inside a sentence: the words in full ink, a small chevron, a faint
/// wash on hover. No fill at rest and never a border.
struct ChipLabel: View {
    let title: String
    var logo: String? = nil
    var quiet = false
    var mono = false
    var active = false

    var body: some View {
        HStack(spacing: 5) {
            if let logo { ProviderLogo(providerId: logo, size: 13) }
            Text(title)
                .font(mono ? .btMono : quiet ? .btBody : .btBodyMedium)
                .foregroundStyle(quiet ? Color.btTextSecondary : Color.btText)
                .monospacedDigit()
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Color.btTextTertiary)
        }
        .padding(.horizontal, Chip.inset)
        .frame(height: 24)
        .background(active ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
}

enum Chip {
    /// A chip's text sits this far inside its hover wash. A chip that starts
    /// a line pulls left by as much, so its words meet the line's edge.
    static let inset: CGFloat = 5
}

/// A dropdown chip; the menu is the system's own.
struct SentenceMenu<Content: View>: View {
    let title: String
    var logo: String? = nil
    var quiet = false
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            ChipLabel(title: title, logo: logo, quiet: quiet, active: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// A chip that opens a popover rather than a menu.
struct SentencePopover<Content: View>: View {
    let title: String
    var quiet = false
    var help: String? = nil
    @ViewBuilder var content: (_ dismiss: @escaping () -> Void) -> Content
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            ChipLabel(title: title, quiet: quiet, active: hovering || open)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help ?? "")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            content { open = false }
        }
    }
}

/// A plain word between chips.
struct SentenceWord: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.btBody).foregroundStyle(Color.btTextSecondary).frame(height: 24)
    }
}

// MARK: - Tabs and switch

/// Text tabs; the current one sits on a faint fill. The row pulls left by
/// the tab padding so the first tab's words keep the page's left edge.
struct PageTabs<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                PageTab(title: item.title, active: item.value == selection) { selection = item.value }
            }
        }
        .padding(.leading, -PageTabMetrics.inset)
    }
}

private enum PageTabMetrics { static let inset: CGFloat = 10 }

private struct PageTab: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // One weight for both states, so switching never nudges the row.
            Text(title)
                .font(BTFont.ui(12.5, .medium))
                .foregroundStyle(active ? Color.btText : hovering ? Color.btTextSecondary : Color.btTextTertiary)
                .padding(.horizontal, PageTabMetrics.inset)
                .frame(height: 26)
                .background(active ? Color.btHover : hovering ? Color.btHover.opacity(0.6) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A small switch in the app's own ink. The system switch takes the
/// user's accent colour, which may be blue.
struct QuietSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? Color.btAccent : Color.btBorderStrong)
                    .frame(width: 24, height: 14)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color.btOnAccent : Color.white)
                            .frame(width: 10, height: 10)
                            .shadow(color: .black.opacity(configuration.isOn ? 0 : 0.18), radius: 0.5, y: 0.5)
                            .padding(2)
                    }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.16), value: configuration.isOn)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// MARK: - Time picker

/// "09:00 ▾", or ":15 ▾" for minutes past the hour. Opens a list of common
/// times; any time can be typed.
struct TimeChip: View {
    @Binding var hour: Int
    @Binding var minute: Int
    var minuteOnly = false

    var body: some View {
        SentencePopover(title: minuteOnly ? String(format: ":%02d", minute) : String(format: "%02d:%02d", hour, minute)) { dismiss in
            TimeList(hour: $hour, minute: $minute, minuteOnly: minuteOnly, dismiss: dismiss)
        }
    }
}

private struct TimeList: View {
    @Binding var hour: Int
    @Binding var minute: Int
    let minuteOnly: Bool
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Option: Hashable, Identifiable {
        let hour: Int, minute: Int
        var id: Int { hour * 60 + minute }
    }

    private var options: [Option] {
        minuteOnly
            ? stride(from: 0, to: 60, by: 5).map { Option(hour: hour, minute: $0) }
            : (0..<48).map { Option(hour: $0 / 2, minute: $0 % 2 * 30) }
    }

    private var typed: Option? {
        TimeParse.parse(query, minuteOnly: minuteOnly).map { Option(hour: minuteOnly ? hour : $0.hour, minute: $0.minute) }
    }

    private var current: Option { Option(hour: hour, minute: minute) }

    var body: some View {
        VStack(spacing: 0) {
            TextField(minuteOnly ? "Minute, e.g. 45" : "Type a time, e.g. 9:05", text: $query)
                .textFieldStyle(.plain)
                .font(.btInput)
                .focused($focused)
                .onSubmit { if let typed { pick(typed) } }
                .padding(.horizontal, Space.md)
                .frame(height: 36)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if let typed, !options.contains(typed) {
                            row(typed)
                            Hairline().padding(.vertical, 4)
                        }
                        if !options.contains(current), typed != current {
                            row(current).id(current.id)
                        }
                        ForEach(options) { option in row(option).id(option.id) }
                    }
                    .padding(6)
                }
                .onAppear { proxy.scrollTo(options.contains(current) ? current.id : options.first?.id, anchor: .center) }
            }
        }
        .frame(width: 200, height: minuteOnly ? 250 : 300)
        .background(Color.btSurfaceRaised)
        .onAppear { focused = true }
    }

    private func row(_ option: Option) -> some View {
        Button { pick(option) } label: {
            HStack {
                Text(minuteOnly ? String(format: ":%02d past the hour", option.minute) : String(format: "%02d:%02d", option.hour, option.minute))
                    .font(.btBody)
                    .monospacedDigit()
                    .foregroundStyle(Color.btText)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.btAccent)
                    .opacity(option == current ? 1 : 0)
            }
            .padding(.horizontal, Space.sm)
            .frame(height: 26)
        }
        .buttonStyle(RowButtonStyle(selected: option == typed))
    }

    private func pick(_ option: Option) {
        if !minuteOnly { hour = option.hour }
        minute = option.minute
        dismiss()
    }
}

/// Reads a typed time: "9", "9:05", "0905", "21.30", "9pm", "9:30 am"; for
/// minutes, "15" or ":15".
enum TimeParse {
    static func parse(_ text: String, minuteOnly: Bool) -> (hour: Int, minute: Int)? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if minuteOnly {
            if s.hasPrefix(":") { s.removeFirst() }
            guard let m = Int(s), (0...59).contains(m) else { return nil }
            return (0, m)
        }
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where s.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let parts = s.split(whereSeparator: { ":.h ".contains($0) }).map(String.init)
        var hour: Int, minute: Int
        switch parts.count {
        case 1:
            let digits = parts[0]
            guard digits.allSatisfy(\.isNumber), (1...4).contains(digits.count), let n = Int(digits) else { return nil }
            (hour, minute) = digits.count <= 2 ? (n, 0) : (n / 100, n % 100)
        case 2:
            guard let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            (hour, minute) = (h, m)
        default:
            return nil
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }
}

// MARK: - Time zone picker

/// Opens a searchable list of every known time zone. The full form (city,
/// offset) is a pop-up button for Settings; `compact` is a sentence chip
/// that shows only the offset while the zone is this Mac's.
struct TimeZoneField: View {
    @Binding var identifier: String
    var compact = false
    @State private var open = false

    var body: some View {
        if compact {
            SentencePopover(title: Self.chipTitle(identifier), quiet: true, help: identifier) { dismiss in
                TimeZoneList(selection: $identifier, dismiss: dismiss)
            }
        } else {
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
    }

    /// "GMT−3" in this Mac's zone, "Lisbon GMT+1" elsewhere.
    static func chipTitle(_ identifier: String) -> String {
        identifier == TimeZone.current.identifier ? offset(identifier) : "\(city(identifier)) \(offset(identifier))"
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
                    .font(.btInput)
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
                    .foregroundStyle(Color.btAccent)
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
