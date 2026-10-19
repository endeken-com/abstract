import SwiftUI
import AbstractCore

/// What a permission-rule sheet starts from: a request being asked about,
/// a rule being edited, or a blank rule added in Project Settings.
struct PermissionRuleSeed {
    var kind: PermissionRuleKind
    var pattern: String
    var decision: PermissionDecision

    init(kind: PermissionRuleKind = .command, pattern: String = "", decision: PermissionDecision = .allow) {
        self.kind = kind; self.pattern = pattern; self.decision = decision
    }

    init(call: ToolCall, decision: PermissionDecision, root: String?) {
        let suggested = PermissionRule.suggested(toolName: call.name, input: call.input, root: root)
        self.init(kind: suggested.kind, pattern: suggested.pattern, decision: decision)
    }

    init(rule: PermissionRule) {
        self.init(kind: rule.kind, pattern: rule.pattern, decision: rule.decision)
    }
}

/// Writing one remembered permission answer for a project: the pattern
/// (pre-filled from the request, `*` where the rest may differ), which
/// way it answers, and whether it expires.
struct PermissionRuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectId: String
    /// The rule being edited; nil writes a new one.
    var existing: PermissionRule? = nil
    /// Called after the rule is saved (the asking chat answers its request).
    var onSaved: () -> Void = {}

    @State private var kind: PermissionRuleKind
    @State private var pattern: String
    @State private var decision: PermissionDecision
    @State private var expires: Bool
    @State private var expiresAt: Date

    init(projectId: String, existing: PermissionRule? = nil, seed: PermissionRuleSeed, onSaved: @escaping () -> Void = {}) {
        self.projectId = projectId
        self.existing = existing
        self.onSaved = onSaved
        _kind = State(initialValue: seed.kind)
        _pattern = State(initialValue: seed.pattern)
        _decision = State(initialValue: seed.decision)
        _expires = State(initialValue: existing?.expiresAt != nil)
        _expiresAt = State(initialValue: existing?.expiresAt ?? Date().addingTimeInterval(7 * 86_400))
    }

    private var trimmed: String { pattern.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "Remember This Answer" : "Edit Rule").font(.btHeadline)
                Text("Requests matching the pattern are answered for you in every chat of this project. Use * where the rest may differ, like npm test* or src/**. A deny rule beats an allow rule.")
                    .font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.md) {
                GridRow {
                    Text("Answer").gridColumnAlignment(.trailing).foregroundStyle(Color.btTextSecondary)
                    Picker("", selection: $decision) {
                        ForEach(PermissionDecision.allCases, id: \.self) { d in Text(d.title).tag(d) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Matches").foregroundStyle(Color.btTextSecondary)
                    Picker("", selection: $kind) {
                        ForEach(PermissionRuleKind.allCases, id: \.self) { k in Text(k.title).tag(k) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Pattern").foregroundStyle(Color.btTextSecondary)
                    TextField("Pattern", text: $pattern).font(.btMono).btField()
                }
                GridRow {
                    Text("Expires").foregroundStyle(Color.btTextSecondary)
                    HStack(spacing: Space.sm) {
                        Toggle("", isOn: $expires).labelsHidden()
                        if expires {
                            DatePicker("", selection: $expiresAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                        } else {
                            Text("Never").foregroundStyle(Color.btTextTertiary)
                        }
                    }
                }
            }
            .font(.btBody)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.btSecondary).keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Remember" : "Save", action: save)
                    .buttonStyle(.btPrimary).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 540)
        .background(Color.btCanvas)
    }

    private func save() {
        var rule = existing ?? PermissionRule(projectId: projectId, kind: kind, pattern: trimmed, decision: decision)
        rule.kind = kind
        rule.pattern = trimmed
        rule.decision = decision
        rule.expiresAt = expires ? expiresAt : nil
        model.savePermissionRule(rule)
        dismiss()
        onSaved()
    }
}
