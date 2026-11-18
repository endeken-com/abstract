import SwiftUI
import AbstractCore

/// Project Settings › Clean up (ABS-206): delete the project's chats not
/// active for a while, after a review that lists exactly what goes, what's
/// kept and why.
struct ProjectCleanupSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @AppStorage("projectSettings.cleanupAge") private var age: ChatCleanup.Age = .twoWeeks
    @State private var reviewing = false
    @State private var running: Int?
    @State private var result: String?

    var body: some View {
        PageSection(section: .cleanup) {
            SettingsCard {
                CardRow(title: "Delete chats not active for more than",
                        detail: "Archived ones too, with their worktrees. You see the list first.") {
                    HStack(spacing: Space.sm) {
                        SentenceMenu(title: age.title) {
                            Picker("Age", selection: $age) {
                                ForEach(ChatCleanup.Age.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                        Button("Review…") { reviewing = true }
                            .buttonStyle(.bt(.secondary, size: .small))
                            .disabled(running != nil)
                    }
                }
                if let running {
                    CardRow(title: "Deleting \(running == 1 ? "1 chat" : "\(running) chats")…",
                            detail: "They're gone from Abstract; their files are being cleared.")
                } else if let result {
                    CardRow(title: result)
                }
            }
        }
        .sheet(isPresented: $reviewing) {
            CleanupReviewSheet(project: project, age: age) { ids, sizes in
                running = ids.count
                result = nil
                Task {
                    result = await model.cleanUp(ids, sizes: sizes)
                    running = nil
                }
            }
            .environment(model)
        }
        // The demo's probe opens the review without a click.
        .onChange(of: model.cleanupReviewProject, initial: true) { _, id in
            guard id == project.id else { return }
            model.cleanupReviewProject = nil
            reviewing = true
        }
    }
}

/// The review: every old chat, ticked when it goes, with its last activity,
/// its worktree's size, and why the kept ones stay.
private struct CleanupReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let age: ChatCleanup.Age
    let confirm: ([String], [String: Int64]) -> Void
    @State private var candidates: [ChatCleanup.Candidate]?
    /// Kept chats ticked to go anyway.
    @State private var including: Set<String> = []
    /// Chats that would go, unticked to stay.
    @State private var excluding: Set<String> = []
    @State private var sizes: [String: Int64] = [:]
    /// Chats whose size was asked for, known or not.
    @State private var measured: Set<String> = []

    private var chosen: [String] {
        ChatCleanup.toDelete(candidates ?? [], including: including).filter { !excluding.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up \(project.name)").font(.btHeadline)
                Text("Chats not active for more than \(age.title). The ticked ones are deleted with their worktrees; the rest are kept for the reason shown, unless you tick them.")
                    .font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let candidates {
                    if candidates.isEmpty {
                        Text("No chats here have been quiet for that long.")
                            .font(.btBody).foregroundStyle(Color.btTextTertiary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ScrollView {
                            SettingsCard {
                                ForEach(candidates) { row($0) }
                            }
                        }
                        .frame(maxHeight: 440)
                    }
                } else {
                    HStack(spacing: Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("Looking for old chats…").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            HStack {
                Text(footer).font(.btCallout).foregroundStyle(Color.btTextTertiary).monospacedDigit()
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.btSecondary).keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Delete 1 Chat" : "Delete \(chosen.count) Chats") {
                    let ids = chosen
                    dismiss()
                    confirm(ids, sizes)
                }
                .buttonStyle(.btDanger)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 640)
        .background(Color.btCanvas)
        .onChange(of: model.cleanupProbeConfirm) { _, on in
            guard on else { return }
            model.cleanupProbeConfirm = false
            let ids = chosen
            dismiss()
            confirm(ids, sizes)
        }
        .task {
            let found = await model.cleanupCandidates(project.id, olderThan: age)
            candidates = found
            for candidate in found {
                if let size = await model.cleanupSize(candidate.facts.session) { sizes[candidate.id] = size }
                measured.insert(candidate.id)
            }
        }
    }

    private var footer: String {
        guard let candidates, !candidates.isEmpty else { return "" }
        let ids = chosen
        let known = ids.compactMap { sizes[$0] }.reduce(0, +)
        let measuring = ids.contains { !measured.contains($0) }
        let kept = candidates.count - ids.count
        var parts = ["\(ids.count) of \(candidates.count) to delete"]
        if kept > 0 { parts.append("\(kept) kept") }
        if known > 0 { parts.append((measuring ? "at least " : "") + ByteCountFormatter.string(fromByteCount: known, countStyle: .file) + " to free") }
        return parts.joined(separator: " · ")
    }

    private func row(_ c: ChatCleanup.Candidate) -> some View {
        let s = c.facts.session
        let goes = chosen.contains(c.id)
        return HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Toggle(isOn: Binding(get: { goes }, set: { on in
                if c.reason == nil {
                    if on { excluding.remove(c.id) } else { excluding.insert(c.id) }
                } else {
                    if on { including.insert(c.id) } else { including.remove(c.id) }
                }
            })) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel(goes ? "Delete “\(s.name)”" : "Keep “\(s.name)”")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.name).font(.btBody).foregroundStyle(goes ? Color.btText : Color.btTextSecondary).lineLimit(1)
                    if s.archivedAt != nil {
                        Text("Archived").font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text("Last active \(c.facts.activeAt.formatted(.relative(presentation: .named)))")
                    if let reason = c.reason {
                        Text("·")
                        Text("Kept: \(reason.text)").foregroundStyle(goes ? Color.btTextTertiary : Color.btWarning)
                    }
                }
                .font(.btCallout)
                .foregroundStyle(Color.btTextTertiary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(sizeText(c))
                .font(.btCallout).foregroundStyle(Color.btTextTertiary).monospacedDigit()
        }
        .cardRow()
    }

    private func sizeText(_ c: ChatCleanup.Candidate) -> String {
        if let size = sizes[c.id] { return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        return measured.contains(c.id) || c.facts.session.worktreePath == nil ? "—" : "…"
    }
}
