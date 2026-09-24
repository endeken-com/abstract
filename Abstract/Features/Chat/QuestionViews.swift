import SwiftUI
import AbstractCore

/// The agent's questions (AskUserQuestion), one at a time, in the reply box's
/// place: pick a numbered option (or several, where it allows), or say
/// something else. ↑↓ move, Return or a number picks, Esc skips the question,
/// × skips them all. Choosing the last answer sends them.
struct QuestionPrompt: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let request: PendingPermission

    private enum Focus: Hashable { case options, other }

    @State private var index = 0
    @State private var highlight = 0
    @State private var chosen: [String: [String]] = [:]
    @State private var other: [String: String] = [:]
    @FocusState private var focus: Focus?

    private var questions: [AgentQuestion] { AgentQuestion.parse(request.input) }

    var body: some View {
        let questions = questions
        if let q = questions[safe: index] {
            VStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 0) {
                    header(q, count: questions.count)
                    options(q)
                    otherRow(q, last: index == questions.count - 1)
                }
                .btRaised(radius: Radius.xl)
                hints(q)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.md)
            .frame(maxWidth: Space.readingWidth + 2 * Space.lg)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .options)
            .onAppear { focus = .options }
            .onKeyPress(.upArrow) { move(-1, in: q) }
            .onKeyPress(.downArrow) { move(1, in: q) }
            .onKeyPress(.escape) { skip(); return .handled }
            .onKeyPress(.return) {
                guard focus == .options, let option = q.options[safe: highlight] else { return .ignored }
                pick(option.label, in: q)
                return .handled
            }
            .onKeyPress(characters: .decimalDigits) { press in
                guard focus == .options, let n = Int(press.characters), let option = q.options[safe: n - 1] else { return .ignored }
                highlight = n - 1
                pick(option.label, in: q)
                return .handled
            }
            .id(index)
            .transition(.opacity)
        }
    }

    // MARK: Parts

    private func header(_ q: AgentQuestion, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 3) {
                if let header = q.header {
                    Text(header).font(.btChatCaptionMedium).foregroundStyle(Color.btTextTertiary)
                }
                Text(q.question)
                    .font(BTFont.chat(15, .medium))
                    .foregroundStyle(Color.btText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if count > 1 {
                HStack(spacing: 2) {
                    Button { go(index - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                    Text("\(index + 1) of \(count)").font(.btChatCaption).monospacedDigit().foregroundStyle(Color.btTextTertiary)
                    Button { go(index + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index == count - 1)
                }
                .buttonStyle(.icon(size: 22))
                .font(.system(size: 10, weight: .semibold))
            }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)) }
                .buttonStyle(.icon(size: 22))
                .help("Skip all; the agent carries on without answers")
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md + 2)
        .padding(.bottom, Space.sm)
    }

    private func options(_ q: AgentQuestion) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(q.options.enumerated()), id: \.element.label) { i, option in
                if i > 0 { Divider().overlay(Color.btBorder).padding(.horizontal, Space.lg) }
                QuestionOptionRow(number: i + 1, option: option, multiSelect: q.multiSelect,
                                  selected: chosen[q.question]?.contains(option.label) == true,
                                  highlighted: highlight == i && focus == .options) {
                    highlight = i
                    pick(option.label, in: q)
                }
                .onHover { if $0 { highlight = i } }
            }
        }
        .padding(.horizontal, Space.xs)
    }

    private func otherRow(_ q: AgentQuestion, last: Bool) -> some View {
        let typed = other[q.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = !(chosen[q.question] ?? []).isEmpty
        return HStack(spacing: Space.sm) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.btTextSecondary)
                .frame(width: 22, height: 22)
                .background(Color.btInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            TextField("Something else", text: Binding(get: { other[q.question] ?? "" }, set: { text in
                other[q.question] = text
                // One answer only: your own words stand in for an option.
                if !q.multiSelect, !text.isEmpty { chosen[q.question] = [] }
            }), prompt: Text("Something else").foregroundStyle(Color.btTextTertiary))
                .textFieldStyle(.plain)
                .font(.btChatInput)
                .foregroundStyle(Color.btText)
                .focused($focus, equals: .other)
                .onSubmit { typed.isEmpty ? skip() : advance() }
            if typed.isEmpty, !picked {
                Button("Skip") { skip() }
                    .buttonStyle(.bt(.secondary, size: .small))
                    .help("Skip this question (Esc)")
            } else if !typed.isEmpty || q.multiSelect {
                Button(last ? "Send" : "Next") { advance() }
                    .buttonStyle(.bt(.primary, size: .small))
            }
        }
        .padding(.horizontal, Space.sm + 2)
        .padding(.vertical, Space.sm)
        .background(Color.btInset.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .padding(Space.sm)
    }

    private func hints(_ q: AgentQuestion) -> some View {
        KeyHint("↑↓ to navigate · ", q.multiSelect ? "Enter to choose · " : "Enter to select · ", "Esc to skip")
    }

    // MARK: Actions

    private func move(_ step: Int, in q: AgentQuestion) -> KeyPress.Result {
        guard !q.options.isEmpty else { return .ignored }
        if focus != .options { focus = .options }
        highlight = (highlight + step + q.options.count) % q.options.count
        return .handled
    }

    /// One answer: take it and go on. Several: toggle it.
    private func pick(_ label: String, in q: AgentQuestion) {
        if q.multiSelect {
            var picked = chosen[q.question] ?? []
            if let i = picked.firstIndex(of: label) { picked.remove(at: i) } else { picked.append(label) }
            // In the order they're offered, whatever order they were clicked.
            chosen[q.question] = q.options.map(\.label).filter(picked.contains)
        } else {
            chosen[q.question] = [label]
            other[q.question] = ""
            advance()
        }
    }

    private func skip() {
        guard let q = questions[safe: index] else { return }
        chosen[q.question] = nil
        other[q.question] = nil
        advance()
    }

    private func advance() {
        if index + 1 < questions.count { go(index + 1) } else { send() }
    }

    private func go(_ next: Int) {
        guard questions.indices.contains(next) else { return }
        withAnimation(.snappy(duration: 0.15)) { index = next }
        let options = questions[next].options.map(\.label)
        highlight = chosen[questions[next].question]?.first.flatMap(options.firstIndex(of:)) ?? 0
        focus = .options
    }

    /// Whatever was answered goes back; nothing answered is a skip.
    private func send() {
        let answers = questions.reduce(into: [String: String]()) { out, q in
            out[q.question] = AgentQuestion.answer(chosen: chosen[q.question] ?? [], other: other[q.question] ?? "")
        }
        if answers.isEmpty { dismiss() } else { model.answerQuestion(sessionId, requestId: request.requestId, answers: answers) }
    }

    private func dismiss() {
        model.answerPermission(sessionId, requestId: request.requestId, allow: false)
    }
}

private struct QuestionOptionRow: View {
    let number: Int
    let option: AgentQuestion.Option
    let multiSelect: Bool
    let selected: Bool
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.md) {
                Group {
                    if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                    else { Text("\(number)").font(.btChatCaptionMedium).monospacedDigit() }
                }
                .foregroundStyle(selected ? Color.btOnAccent : Color.btTextSecondary)
                .frame(width: 22, height: 22)
                .background(selected ? Color.btAccent : Color.btInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.btChatBody).foregroundStyle(Color.btText)
                    if let description = option.description {
                        Text(description).font(.btChatCaption).foregroundStyle(Color.btTextTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 9)
            .background(highlighted ? Color.btHover : .clear, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Questions already answered, on the call's row: each with what you said,
/// read back from the tool's result.
struct QuestionAnswers: View {
    let questions: [AgentQuestion]
    let result: ToolResult?

    var body: some View {
        let answers = result.map { AgentQuestion.answers(fromResult: $0.output) } ?? [:]
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.question).font(.btChatTool).foregroundStyle(Color.btTextSecondary)
                    if let answer = answers[q.question] {
                        Text(answer).font(.btChatToolMedium).foregroundStyle(Color.btText)
                    } else if result != nil {
                        Text("Skipped").font(.btChatToolMedium).foregroundStyle(Color.btTextTertiary)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .btLeadingRule()
    }
}
