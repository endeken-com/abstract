import SwiftUI
import AbstractCore

/// Workflows: profiles taking turns on one chat. The list, then the chosen
/// workflow's steps, each a profile, what it's asked, and whether the next
/// step starts by itself.
struct WorkflowsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedId: String?

    private var selected: Workflow? { model.workflow(selectedId) ?? model.workflows.first }

    var body: some View {
        Form {
            Section {
                if model.workflows.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("No workflows yet.").foregroundStyle(Color.btText)
                        Text("Start from one below, or add a blank one and pick its steps.")
                            .font(.btCaption)
                            .foregroundStyle(Color.btTextSecondary)
                    }
                    .padding(.vertical, Space.xs)
                }
                ForEach(model.workflows) { workflow in
                    SettingsListRow(value: workflow.iconValue, context: .workflow,
                                    title: workflow.name.isEmpty ? "Workflow" : workflow.name,
                                    detail: summary(workflow),
                                    selected: selected?.id == workflow.id) { selectedId = workflow.id }
                }
            } header: {
                HStack {
                    Text("Workflows")
                    Spacer()
                    Menu {
                        Button("Blank Workflow") { selectedId = model.addWorkflow().id }
                        Section("Start From") {
                            ForEach(WorkflowTemplate.all) { template in
                                Button {
                                    selectedId = model.addWorkflow(from: template).id
                                } label: {
                                    Text(template.name)
                                    Text(template.detail)
                                }
                            }
                        }
                    } label: {
                        Label("Add Workflow", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bt(.ghost, size: .small))
                    .fixedSize()
                }
            } footer: {
                SettingsCaption("Choose a workflow in the New Chat window, or have an automation follow one. Each step hands the chat to its profile, which picks up where the last step left off; another agent gets a handover first. A step can wait for you before the next one starts.")
            }

            if let selected {
                WorkflowEditor(workflow: selected, onDelete: { delete(selected) })
                    .id(selected.id)
            }
        }
        .settingsPane()
    }

    /// "UI Researcher → Implementer → Reviewer"
    private func summary(_ workflow: Workflow) -> String {
        if let problem = workflow.problem(profiles: model.profiles) { return problem }
        return workflow.steps.map { model.profile($0.profileId)?.name ?? "?" }.joined(separator: " → ")
    }

    private func delete(_ workflow: Workflow) {
        let index = model.workflows.firstIndex { $0.id == workflow.id } ?? 0
        model.deleteWorkflow(workflow.id)
        selectedId = model.workflows.indices.contains(index) ? model.workflows[index].id : model.workflows.last?.id
    }
}

private struct WorkflowEditor: View {
    @Environment(AppModel.self) private var model
    let workflow: Workflow
    let onDelete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: binding(\.name), prompt: Text("e.g. Ship a screen"))
                    .labelsHidden()
                    .fontWeight(Field.weight)
                    .btField()
                    .frame(maxWidth: 360)
            }
            LabeledContent("Icon") {
                SharedIconButton(value: workflow.iconValue, name: workflow.name, context: .workflow,
                                 onChange: { model.setWorkflowIcon(workflow.id, value: $0) },
                                 onUpload: { model.importWorkflowIcon(workflow.id, from: $0) })
            }
        } header: {
            HStack(spacing: Space.sm) {
                IconTile(value: workflow.iconValue, name: workflow.name, context: .workflow, size: 26)
                Text(workflow.name.isEmpty ? "Workflow" : workflow.name).font(.btHeadline).foregroundStyle(Color.btText)
            }
            .padding(.top, Space.md)
            .padding(.bottom, 2)
        }

        Section {
            ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                WorkflowStepRow(workflow: workflow, index: index, step: step, update: update)
            }
            HStack {
                Button {
                    update { $0.steps.append(WorkflowStep(profileId: model.profiles.first?.id ?? "")) }
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
                .disabled(model.profiles.isEmpty)
                Spacer()
                if model.profiles.isEmpty {
                    Text("Add a profile first, in Settings › Profiles.")
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextSecondary)
                }
            }
        } header: {
            Text("Steps")
        } footer: {
            SettingsCaption(stepsCaption)
        }

        Section {
            HStack {
                Text(usage).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                Spacer()
                Button("Delete Workflow…", role: .destructive) { confirmingDelete = true }
            }
            .confirmationDialog("Delete “\(workflow.name)”?", isPresented: $confirmingDelete) {
                Button("Delete Workflow", role: .destructive, action: onDelete)
            } message: {
                Text("Chats running it finish it as they started it. Automations that follow it fail their runs until you choose another.")
            }
        }
    }

    private var stepsCaption: String {
        if let problem = workflow.problem(profiles: model.profiles) { return problem }
        return "The first step's prompt goes ahead of the task you type. A later step with no prompt is asked to carry on as its profile from where the last step left off."
    }

    private var usage: String {
        let count = model.automations.filter { $0.workflowId == workflow.id }.count
        return count == 0 ? "No automation follows it." : "\(count) automation\(count == 1 ? "" : "s") follow\(count == 1 ? "s" : "") it."
    }

    private func binding(_ key: WritableKeyPath<Workflow, String>) -> Binding<String> {
        Binding(get: { model.workflow(workflow.id)?[keyPath: key] ?? "" }, set: { new in update { $0[keyPath: key] = new } })
    }

    /// Edits this workflow as saved now, and saves it.
    private func update(_ change: (inout Workflow) -> Void) {
        guard var edited = model.workflow(workflow.id) else { return }
        let before = edited
        change(&edited)
        if edited != before { model.saveWorkflow(edited) }
    }
}

/// One step: its number, the profile that takes it, what it's asked, and
/// what happens when it's done; moved and removed from its own buttons.
private struct WorkflowStepRow: View {
    @Environment(AppModel.self) private var model
    let workflow: Workflow
    let index: Int
    let step: WorkflowStep
    let update: ((inout Workflow) -> Void) -> Void
    @FocusState private var promptFocused: Bool
    @State private var hovering = false

    private var isLast: Bool { index == workflow.steps.count - 1 }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Text("\(index + 1)")
                .font(BTFont.ui(11.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.btTextSecondary)
                .frame(width: 22, height: 22)
                .background(Color.btHover, in: Circle())
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: Space.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.sm) {
                        profilePicker
                        advanceControl
                        Spacer(minLength: 0)
                        controls
                    }
                    HStack(alignment: .top, spacing: Space.sm) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            profilePicker
                            advanceControl
                        }
                        Spacer(minLength: 0)
                        controls
                    }
                }
                TextField("Prompt", text: field(\.prompt),
                          prompt: Text(index == 0 ? "Optional: asked ahead of the task" : "Optional: what this step should do"),
                          axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...6)
                    .font(.btBody)
                    .focused($promptFocused)
                    .btField()
            }
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: field(\.profileId)) {
            ForEach(model.profiles) { profile in
                Label {
                    Text(profile.name)
                } icon: {
                    IconTile(value: profile.iconValue, name: profile.name, context: .profile, size: 18)
                }.tag(profile.id)
            }
            if model.profile(step.profileId) == nil {
                Text("Deleted profile").tag(step.profileId)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private var advanceControl: some View {
        if isLast {
            Text("Last step")
                .font(.btCaption)
                .foregroundStyle(Color.btTextTertiary)
        } else {
            Picker("Then", selection: field(\.advance)) {
                ForEach(WorkflowAdvance.allCases, id: \.self) { Text("then \($0.title.lowercased())").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help(step.advance.detail)
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button { move(by: -1) } label: { Image(systemName: "arrow.up").font(.system(size: 10.5, weight: .semibold)) }
                .buttonStyle(.icon(size: 22))
                .disabled(index == 0)
                .help("Move up")
            Button { move(by: 1) } label: { Image(systemName: "arrow.down").font(.system(size: 10.5, weight: .semibold)) }
                .buttonStyle(.icon(size: 22))
                .disabled(isLast)
                .help("Move down")
            Button {
                let id = step.id
                update { $0.steps.removeAll { $0.id == id } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.icon(size: 22))
            .help("Remove step")
        }
        .opacity(hovering || promptFocused ? 1 : 0.35)
    }

    private func move(by offset: Int) {
        let id = step.id
        update { w in
            guard let from = w.steps.firstIndex(where: { $0.id == id }), w.steps.indices.contains(from + offset) else { return }
            w.steps.swapAt(from, from + offset)
        }
    }

    private func field<T: Equatable>(_ key: WritableKeyPath<WorkflowStep, T>) -> Binding<T> {
        let id = step.id
        return Binding(get: {
            model.workflow(workflow.id)?.steps.first { $0.id == id }?[keyPath: key] ?? step[keyPath: key]
        }, set: { new in
            update { w in
                guard let i = w.steps.firstIndex(where: { $0.id == id }) else { return }
                w.steps[i][keyPath: key] = new
            }
        })
    }
}
