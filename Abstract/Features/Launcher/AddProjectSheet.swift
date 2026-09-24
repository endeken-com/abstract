import SwiftUI
import AppKit
import AbstractCore

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var probe: AppModel.Probe?
    @State private var name = ""
    @State private var baseRef = "HEAD"
    @State private var providerId = "claude"
    @State private var policy: PermissionPolicy = .ask
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Project").font(.btHeadline)
                Text("Point Abstract at a git repository on this Mac.").font(.btCallout).foregroundStyle(Color.btTextSecondary)
            }

            Button(action: choose) {
                HStack(spacing: Space.md) {
                    Image(systemName: probe == nil ? "folder" : "folder.fill")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(probe == nil ? Color.btTextSecondary : Color.btAccent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(probe?.name ?? (working ? "Reading repository…" : "Choose a Repository…")).font(.btBodyMedium).foregroundStyle(Color.btText)
                        Text(probe?.rootPath ?? "Any folder inside the repository works.")
                            .font(probe == nil ? .btCallout : .btMonoSmall)
                            .foregroundStyle(Color.btTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(probe == nil ? "Browse" : "Change").font(.btCallout).foregroundStyle(Color.btTextSecondary)
                }
                .padding(.vertical, Space.sm)
                .padding(.horizontal, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CardButtonStyle())

            if let probe, !probe.isRoot {
                Notice(text: "That folder sits inside a larger repository, so Abstract uses its root. Worktrees then carry the whole project.")
            }
            if let probe, !probe.nestedRepos.isEmpty {
                Notice(text: "Found \(probe.nestedRepos.count) nested repositor\(probe.nestedRepos.count == 1 ? "y" : "ies") (\(probe.nestedRepos.prefix(3).joined(separator: ", "))). A worktree can't carry them, so changes inside them stay out of review.")
            }

            if probe != nil {
                Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: Space.md) {
                    GridRow {
                        Text("Name").gridColumnAlignment(.trailing).foregroundStyle(Color.btTextSecondary)
                        TextField("Name", text: $name).btField()
                    }
                    GridRow {
                        Text("Branch from").foregroundStyle(Color.btTextSecondary)
                        TextField("HEAD", text: $baseRef).font(.btMono).btField()
                    }
                    GridRow {
                        Text("Default agent").foregroundStyle(Color.btTextSecondary)
                        Picker("", selection: $providerId) {
                            ForEach(ProviderRegistry.all, id: \.id) { p in Text(p.name).tag(p.id) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Permissions").foregroundStyle(Color.btTextSecondary)
                        Picker("", selection: $policy) {
                            ForEach(PermissionPolicy.allCases, id: \.self) { p in Text(p.title).tag(p) }
                        }
                        .labelsHidden()
                    }
                }
                .font(.btBody)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.btCallout).foregroundStyle(Color.btRemoved).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.btSecondary).keyboardShortcut(.cancelAction)
                Button("Add Project", action: save).buttonStyle(.btPrimary).keyboardShortcut(.defaultAction).disabled(probe == nil)
            }
        }
        .padding(Space.xl)
        .frame(width: 540)
        .background(Color.btCanvas)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        error = nil
        Task {
            do {
                let p = try await model.probe(directory: url.path)
                probe = p
                name = p.name
                baseRef = p.defaultBranch
            } catch {
                probe = nil
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func save() {
        guard let probe else { return }
        do {
            try model.addProject(probe, name: name, baseRef: baseRef, providerId: providerId, policy: policy)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct Notice: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.btWarning)
            Text(text).font(.btCallout).foregroundStyle(Color.btTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
