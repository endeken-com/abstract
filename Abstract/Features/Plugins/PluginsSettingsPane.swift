import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// Settings → Plugins: what's installed, what each may see, and the switches
/// that turn one on, off, or remove it (ABS-84 §5).
struct PluginsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingInstall?
    @State private var enabling: InstalledPlugin?
    @State private var removing: InstalledPlugin?
    @State private var pickedProblem: String?
    /// A usable plugin whose own Settings page is showing (ABS-96).
    @State private var settingsPageFor: InstalledPlugin?

    struct PendingInstall: Identifiable {
        let id = UUID()
        var folder: URL
        var inspection: PluginPackage.Inspection
        var cleanup: URL?
        var source: PluginSource
    }

    var body: some View {
        Form {
            Section {
                if model.plugins.installed.isEmpty && model.plugins.orphans.isEmpty {
                    Text("No plugins are installed yet.")
                        .foregroundStyle(Color.btTextSecondary)
                }
                ForEach(model.plugins.installed) { plugin in
                    row(plugin)
                }
                ForEach(model.plugins.orphans, id: \.name) { orphan in
                    LabeledContent {
                        Text(orphan.problem).foregroundStyle(Color.btTextSecondary)
                    } label: {
                        Text(orphan.name)
                        Text("Not installed")
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                SettingsCaption("Plugins run on this Mac. They don't run on your phone. A plugin sees only what you granted it below, and turning it off takes that away and removes its screen, tabs, menu items and commands.")
            }

            Section {
                LabeledContent {
                    Button("Install…") { pickPackage() }
                } label: {
                    Text("Install a plugin")
                    Text("Choose a plugin folder, or a zip of one.")
                }
                ForEach(model.plugins.bundledFolders, id: \.path) { folder in
                    if let inspection = try? PluginPackage.inspect(folder: folder),
                       model.plugins.plugin(inspection.manifest.id) == nil {
                        LabeledContent {
                            Button("Install") {
                                pending = PendingInstall(folder: folder, inspection: inspection, cleanup: nil, source: .bundled)
                            }
                        } label: {
                            Text(inspection.manifest.name)
                            Text("With Abstract · version \(inspection.manifest.version)")
                        }
                    }
                }
                if let pickedProblem {
                    Text(pickedProblem).foregroundStyle(Color.btRemoved)
                }
            } header: {
                Text("Add")
            }
        }
        .settingsPane()
        .sheet(item: $pending) { item in
            PluginReviewSheet(
                title: "Install \(item.inspection.manifest.name)?",
                manifest: item.inspection.manifest,
                source: item.source,
                primaryLabel: "Install and Enable",
                secondaryLabel: "Install Only",
                projectChoices: model.pluginProjectChoices(),
                initialProjectKeys: []
            ) { enable, transcriptProjectKeys in
                do {
                    let record = try model.plugins.install(from: item.folder, sourceKind: item.source, enable: enable,
                                                           transcriptProjectKeys: transcriptProjectKeys)
                    model.flash(enable ? "\(record.name) is installed and on" : "\(record.name) is installed")
                } catch let error as PluginValidationError {
                    pickedProblem = error.description
                } catch {
                    pickedProblem = "This plugin isn't a valid Abstract plugin."
                }
                if let cleanup = item.cleanup { try? FileManager.default.removeItem(at: cleanup) }
                pending = nil
            } cancel: {
                if let cleanup = item.cleanup { try? FileManager.default.removeItem(at: cleanup) }
                pending = nil
            }
        }
        .sheet(item: $settingsPageFor) { plugin in
            if let page = plugin.manifest?.contributes.settingsPage {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        Text(page.title).font(.btHeadline).foregroundStyle(Color.btText)
                        Spacer()
                        Button("Done") { settingsPageFor = nil }.buttonStyle(.btPrimary)
                    }
                    PluginHostView(pluginId: plugin.id, viewId: page.id,
                                   placement: PluginPlacement(place: .settings, contributionId: page.id))
                        .frame(height: 420)
                }
                .padding(Space.xl)
                .frame(width: 560)
            }
        }
        .sheet(item: $enabling) { plugin in
            PluginReviewSheet(
                title: "Turn on \(plugin.record.name)?",
                manifest: plugin.manifest ?? PluginManifest(
                    id: plugin.record.id, name: plugin.record.name, version: plugin.record.version,
                    capabilities: plugin.record.grantedCapabilities.map(\.rawValue),
                    views: [PluginManifest.View(id: "main", title: plugin.record.name)]),
                source: plugin.record.source,
                primaryLabel: "Enable",
                secondaryLabel: nil,
                projectChoices: model.pluginProjectChoices(),
                initialProjectKeys: plugin.record.transcriptProjectKeys
            ) { _, transcriptProjectKeys in
                model.setPluginEnabled(plugin.id, true, transcriptProjectKeys: transcriptProjectKeys)
                model.plugins.noteError(plugin.id, nil)
                enabling = nil
            } cancel: {
                enabling = nil
            }
        }
        .confirmationDialog(
            "Remove \(removing?.record.name ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let plugin = removing { model.removePlugin(plugin.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its files, its saved settings and any secrets you entered for it are deleted from this Mac. Your chats and projects aren't affected.")
        }
    }

    @ViewBuilder
    private func row(_ plugin: InstalledPlugin) -> some View {
        let record = plugin.record
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { plugin.isUsable },
                set: { on in
                    if on { enabling = plugin } else { model.setPluginEnabled(plugin.id, false) }
                }
            )) {
                Text(record.name)
                Text("Version \(record.version) · \(record.source.plainWords)")
            }
            .disabled(plugin.manifest == nil)

            if let manifest = plugin.manifest, !manifest.grantedCapabilities.isEmpty {
                // What it actually holds now; before its first review,
                // what it asks for.
                Text((record.grantedCapabilities.isEmpty ? manifest.grantedCapabilities : record.grantedCapabilities).map {
                    $0.plainWords(transcriptProjects: model.pluginProjectNames(record.transcriptProjectKeys))
                }.sorted().joined(separator: " · "))
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextSecondary)
            }
            // Action grants (ABS-92), each revocable on its own. Turning
            // the plugin off and on again reviews the whole list anew.
            ForEach(PluginCapability.actionCases.filter { record.grantedCapabilities.contains($0) },
                    id: \.rawValue) { capability in
                HStack(spacing: Space.sm) {
                    Text(record.alwaysAllowedActions.contains(capability)
                         ? "\(capability.plainWords) — always allowed."
                         : "\(capability.plainWords) — asks first.")
                        .font(.btCaption)
                        .foregroundStyle(Color.btTextSecondary)
                    if record.alwaysAllowedActions.contains(capability) {
                        Button("Ask First") { model.plugins.setAlwaysAllowed(plugin.id, capability, false) }
                    }
                    Button("Revoke") { model.plugins.revokeCapability(plugin.id, capability) }
                }
            }
            if let problem = plugin.problem {
                Text(problem).font(.btCaption).foregroundStyle(Color.btRemoved)
                if plugin.manifest != nil {
                    Button("Review") { model.plugins.reviewChangedPackage(plugin.id) }
                }
            } else if let lastError = record.lastError {
                Text("Last error: \(lastError)").font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
            if let manifest = plugin.manifest, manifest.contributes.views.count < manifest.appearanceSentences.count {
                Text(manifest.appearanceSentences.joined(separator: " "))
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextSecondary)
            }
            if let manifest = plugin.manifest, !manifest.networkHosts.isEmpty {
                Text("Can reach: \(manifest.networkHosts.joined(separator: ", ")).")
                    .font(.btCaption)
                    .foregroundStyle(Color.btTextSecondary)
            }
            if let manifest = plugin.manifest {
                ForEach(manifest.secretDeclarations) { secret in
                    PluginSecretRow(pluginId: plugin.id, secret: secret)
                }
            }
            let activity = model.plugins.networkLogEntries(plugin.id)
            if !activity.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web requests").font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    ForEach(Array(activity.prefix(5)), id: \.at) { entry in
                        Text("\(entry.host) · \(entry.status == 0 ? "refused" : String(entry.status)) · \(entry.at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.btCaption)
                            .foregroundStyle(Color.btTextSecondary)
                    }
                }
            }
            HStack(spacing: Space.sm) {
                if plugin.isUsable, let view = plugin.view {
                    Button("Open") {
                        model.destination = .plugin(plugin.id, view.id)
                        model.isSettingsOpen = false
                    }
                }
                if plugin.isUsable, let page = plugin.manifest?.contributes.settingsPage {
                    Button(page.title) { settingsPageFor = plugin }
                }
                if plugin.isUsable, plugin.manifest?.grantedCapabilities.contains(.transcriptsRead) == true {
                    Button("Choose Projects…") { enabling = plugin }
                }
                Button("Remove", role: .destructive) { removing = plugin }
            }
        }
        .padding(.vertical, 2)
    }

    private func pickPackage() {
        pickedProblem = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.prompt = "Install"
        panel.message = "Choose a plugin folder, or a zip of one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let picked = try model.plugins.inspectPicked(url)
            pending = PendingInstall(folder: picked.folder, inspection: picked.inspection,
                                     cleanup: picked.cleanup, source: .user)
        } catch let error as PluginValidationError {
            pickedProblem = error.description
        } catch {
            pickedProblem = "This plugin isn't a valid Abstract plugin."
        }
    }
}

/// The one review: name, version, where it came from, whether it's signed,
/// and what it may see — in plain words. Grants are all-or-nothing.
private struct PluginReviewSheet: View {
    let title: String
    let manifest: PluginManifest
    let source: PluginSource
    let primaryLabel: String
    let secondaryLabel: String?
    /// Projects a `transcripts.read` grant can be scoped to.
    let projectChoices: [(key: String, name: String)]
    let initialProjectKeys: [String]
    let confirm: (_ enable: Bool, _ transcriptProjectKeys: [String]) -> Void
    let cancel: () -> Void
    @State private var pickedProjects: Set<String> = []

    private var pickedNames: [String] {
        projectChoices.filter { pickedProjects.contains($0.key) }.map(\.name)
    }
    private var pickedKeys: [String] {
        projectChoices.filter { pickedProjects.contains($0.key) }.map(\.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(title).font(.btHeadline).foregroundStyle(Color.btText)
            Text("Version \(manifest.version) · \(source.plainWords)")
                .font(.btBody).foregroundStyle(Color.btTextSecondary)
            if let description = manifest.description, !description.isEmpty {
                Text(description).font(.btBody).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if source == .user {
                Text(manifest.networkHosts.isEmpty
                     ? "It isn't signed. It runs in a locked-down page with no network or file access, and it can only see and do what's listed here."
                     : "It isn't signed. It runs in a locked-down page, and Abstract sends its web requests for it — only to the addresses listed here.")
                    .font(.btBody).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("It will appear:").font(.btBodyMedium).foregroundStyle(Color.btText)
                ForEach(manifest.appearanceSentences, id: \.self) { sentence in
                    Text(sentence).font(.btBody).foregroundStyle(Color.btTextSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("It will be able to:").font(.btBodyMedium).foregroundStyle(Color.btText)
                if manifest.grantedCapabilities.isEmpty {
                    Text("Nothing beyond showing its own screen.")
                        .font(.btBody).foregroundStyle(Color.btTextSecondary)
                }
                ForEach(manifest.grantedCapabilities.map {
                    $0.plainWords(transcriptProjects: pickedNames)
                }.sorted(), id: \.self) { words in
                    Text(words).font(.btBody).foregroundStyle(Color.btTextSecondary)
                }
                if manifest.grantedCapabilities.contains(where: \.isAction) {
                    Text("Before it starts a chat, sends a message, stops or resumes an agent, answers for you, or runs an automation, Abstract will ask you first. You can let it always do one of those, and take any of them back here in Settings.")
                        .font(.btBody).foregroundStyle(Color.btTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !manifest.networkSentences.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On the web, it will be able to:").font(.btBodyMedium).foregroundStyle(Color.btText)
                    ForEach(manifest.networkSentences, id: \.self) { sentence in
                        Text(sentence).font(.btBody).foregroundStyle(Color.btTextSecondary)
                    }
                }
            }
            if manifest.grantedCapabilities.contains(.transcriptsRead) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("It may read messages in:").font(.btBodyMedium).foregroundStyle(Color.btText)
                    if projectChoices.isEmpty {
                        Text("You have no projects yet, so it will read no messages.")
                            .font(.btBody).foregroundStyle(Color.btTextSecondary)
                    }
                    ForEach(projectChoices, id: \.key) { choice in
                        Toggle(choice.name, isOn: Binding(
                            get: { pickedProjects.contains(choice.key) },
                            set: { if $0 { pickedProjects.insert(choice.key) } else { pickedProjects.remove(choice.key) } }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.btBody).foregroundStyle(Color.btTextSecondary)
                    }
                    Text("It sees your messages, the agents' replies, tool names and file names — never file contents or what a tool printed.")
                        .font(.btBody).foregroundStyle(Color.btTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                if let secondaryLabel {
                    Button(secondaryLabel) { confirm(false, pickedKeys) }
                }
                Button(primaryLabel) { confirm(true, pickedKeys) }.buttonStyle(.btPrimary)
            }
            .padding(.top, Space.xs)
        }
        .padding(Space.xl)
        .frame(width: 440)
        .onAppear { pickedProjects = Set(initialProjectKeys) }
    }
}

/// One secret a plugin declared (ABS-94): entered here, kept in the
/// Keychain, and never shown again — the plugin names it in a request
/// header and Abstract fills the value in when it sends the request.
private struct PluginSecretRow: View {
    @Environment(AppModel.self) private var model
    let pluginId: String
    let secret: PluginManifest.Secret
    @State private var draft = ""
    @State private var entered = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(secret.title).font(.btCaption).foregroundStyle(Color.btTextSecondary)
            if entered {
                Text("Entered — kept in your Keychain.")
                    .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                Button("Remove") {
                    model.plugins.setSecret(nil, pluginId: pluginId, name: secret.name)
                    entered = false
                }
            } else {
                SecureField(secret.title, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button("Save") {
                    model.plugins.setSecret(draft, pluginId: pluginId, name: secret.name)
                    draft = ""
                    entered = model.plugins.hasSecret(pluginId: pluginId, name: secret.name)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { entered = model.plugins.hasSecret(pluginId: pluginId, name: secret.name) }
    }
}
