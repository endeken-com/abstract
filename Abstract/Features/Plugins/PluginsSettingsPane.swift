import SwiftUI
import UniformTypeIdentifiers
import AbstractCore

/// Searchable plugin gallery and the existing permission review controls.
struct PluginsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var pending: PendingInstall?
    @State private var enabling: InstalledPlugin?
    @State private var removing: InstalledPlugin?
    @State private var pickedProblem: String?
    @State private var query = ""
    @State private var selectedView: PluginGalleryItem.ViewFilter = .all
    @State private var selectedCategory: PluginGalleryItem.Category?
    @State private var selectedPluginID: String?
    @State private var catalogBusy: String?
    /// A usable plugin whose own Settings page is showing (ABS-96).
    @State private var settingsPageFor: InstalledPlugin?

    struct PendingInstall: Identifiable {
        let id = UUID()
        var folder: URL
        var inspection: PluginPackage.Inspection
        var cleanup: URL?
        var source: PluginSource
    }

    private var bundled: [(folder: URL, inspection: PluginPackage.Inspection)] {
        model.plugins.bundledFolders.compactMap { folder in
            (try? PluginPackage.inspect(folder: folder)).map { (folder, $0) }
        }
    }

    private var items: [PluginGalleryItem] {
        PluginGalleryItem.items(installed: model.plugins.installed,
                                bundled: bundled.map { $0.inspection.manifest }, catalog: model.plugins.catalog)
    }

    var body: some View {
        let all = items
        let visible = PluginGalleryItem.filter(all, query: query, view: selectedView, category: selectedCategory)
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.btTextSecondary)
                TextField("Search plugins", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search plugins")
            }
            .padding(Space.md)
            .background(Color.btSurface, in: RoundedRectangle(cornerRadius: 10))

            ViewThatFits(in: .horizontal) {
                HStack {
                    viewPicker
                    Spacer(minLength: Space.sm)
                    installFromDiskButton
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    viewPicker
                    installFromDiskButton
                }
            }

            if !all.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        categoryButton("All kinds", category: nil)
                        ForEach(PluginGalleryItem.Category.allCases.filter { kind in
                            all.contains { $0.category == kind }
                        }, id: \.self) { kind in
                            categoryButton(kind.rawValue, category: kind)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            if let problem = model.plugins.catalogProblem {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("The catalog is unavailable. Installed and bundled plugins still work. \(problem)")
                            .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                        Button("Try Again") { Task { await model.plugins.loadCatalog() } }
                    }
                    VStack(alignment: .leading, spacing: Space.sm) {
                    Text("The catalog is unavailable. Installed and bundled plugins still work. \(problem)")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    Button("Try Again") { Task { await model.plugins.loadCatalog() } }
                    }
                }
            } else if model.plugins.catalog.isEmpty {
                ProgressView("Checking the catalog…")
            }
            if let pickedProblem { Text(pickedProblem).foregroundStyle(Color.btRemoved) }

            if visible.isEmpty {
                Text(emptyMessage).foregroundStyle(Color.btTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: Space.md)],
                          alignment: .leading, spacing: Space.md) {
                    ForEach(visible) { item in galleryCard(item) }
                }
            }

            if let selectedPluginID, let item = all.first(where: { $0.id == selectedPluginID }) {
                detail(item)
            }
            if !model.plugins.orphans.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Packages that could not be read").font(.btHeadline)
                    ForEach(model.plugins.orphans, id: \.name) { orphan in
                        Text("\(orphan.name): \(orphan.problem)").font(.btCaption)
                    }
                }
            }
        }
        .padding(.horizontal, SettingsLayout.margin + SettingsLayout.textInset)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: SettingsLayout.rowWidth + 2 * SettingsLayout.margin, alignment: .leading)
        .frame(maxWidth: .infinity)
        .task { await model.plugins.loadCatalog() }
        .sheet(item: $pending) { item in
            PluginReviewSheet(
                title: "\(model.plugins.plugin(item.inspection.manifest.id) == nil ? "Install" : "Update") \(item.inspection.manifest.name)?",
                manifest: item.inspection.manifest,
                source: item.source,
                publisher: try? PluginSignature.publisher(in: item.folder, hash: item.inspection.hash),
                changes: model.plugins.plugin(item.inspection.manifest.id).map {
                    PluginGrantChanges(new: item.inspection.manifest, old: $0.record, previous: $0.manifest)
                },
                primaryLabel: model.plugins.plugin(item.inspection.manifest.id) == nil ? "Install and Enable" : "Update and Enable",
                secondaryLabel: model.plugins.plugin(item.inspection.manifest.id) == nil ? "Install Only" : "Update Only",
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
                    pickedProblem = error.localizedDescription
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
                publisher: plugin.publisher,
                changes: nil,
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

    private var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No plugins match your search and filters."
        }
        switch selectedView {
        case .all: return "No plugins are available yet. Install one from a folder or zip."
        case .installed: return "No installed plugins match these filters."
        case .updates: return "No plugin updates need your attention."
        }
    }

    private var viewPicker: some View {
        Picker("Show", selection: $selectedView) {
            ForEach(PluginGalleryItem.ViewFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
    }

    private var installFromDiskButton: some View {
        Button("Install from folder or zip…") { pickPackage() }
    }

    private func categoryButton(_ title: String, category: PluginGalleryItem.Category?) -> some View {
        Button(title) { selectedCategory = category }
            .buttonStyle(.bt(category == selectedCategory ? .secondary : .ghost, size: .small))
    }

    private func galleryCard(_ item: PluginGalleryItem) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: item.symbol)
                    .font(.system(size: 22))
                    .frame(width: 38, height: 38)
                    .background(Color.btCanvas, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.btBodyMedium).foregroundStyle(Color.btText)
                    Text(item.category.rawValue).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                }
                Spacer(minLength: 0)
            }
            Text(item.summary).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Text("Version \(item.version) · \(item.source.plainWords)")
                .font(.btCaption).foregroundStyle(Color.btTextSecondary)
            Text(item.publisher.map { "Verified publisher: \($0)" } ?? "Publisher unverified")
                .font(.btCaption).foregroundStyle(Color.btTextSecondary)
            HStack {
                Text(stateWords(item)).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                Spacer(minLength: Space.sm)
                primaryAction(item)
            }
        }
        .padding(Space.md)
        .background(Color.btSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
            selectedPluginID == item.id ? Color.btTextSecondary : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { selectedPluginID = item.id }
        .accessibilityElement(children: .contain)
    }

    private func stateWords(_ item: PluginGalleryItem) -> String {
        switch item.state {
        case .available: "Available"
        case .installed: "On"
        case .disabled: "Off"
        case .updateAvailable: "Update available"
        case .needsReview: "Needs review"
        case .problem: "Needs attention"
        }
    }

    @ViewBuilder
    private func primaryAction(_ item: PluginGalleryItem) -> some View {
        switch item.state {
        case .available:
            Button("Install") { install(item) }.disabled(catalogBusy != nil)
        case .updateAvailable:
            Button("Update") { if let entry = item.catalogEntry { download(entry) } }
                .disabled(catalogBusy != nil)
        case .disabled:
            Button("Enable") { enabling = item.installed }
        case .needsReview, .problem:
            Button("Review") { selectedPluginID = item.id }
        case .installed:
            if let plugin = item.installed, let view = plugin.view {
                Button("Open") {
                    model.destination = .plugin(plugin.id, view.id)
                    model.isSettingsOpen = false
                }
            } else {
                Button("Manage") { selectedPluginID = item.id }
            }
        }
    }

    private func install(_ item: PluginGalleryItem) {
        if item.source == .bundled,
           let package = bundled.first(where: { $0.inspection.manifest.id == item.id }) {
            pending = PendingInstall(folder: package.folder, inspection: package.inspection,
                                     cleanup: nil, source: .bundled)
        } else if let entry = item.catalogEntry {
            download(entry)
        }
    }

    private func detail(_ item: PluginGalleryItem) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text(item.name).font(.btHeadline).foregroundStyle(Color.btText)
                Spacer()
                Button { selectedPluginID = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close plugin details")
            }
            Text(item.summary).font(.btBody).foregroundStyle(Color.btTextSecondary)
            Text("Version \(item.version) · \(item.source.plainWords) · \(item.publisher.map { "Verified publisher: \($0)" } ?? "Unverified")")
                .font(.btCaption).foregroundStyle(Color.btTextSecondary)
            if let manifest = item.installed?.manifest ?? bundled.first(where: { $0.inspection.manifest.id == item.id })?.inspection.manifest {
                Text("What it adds").font(.btBodyMedium)
                Text(manifest.appearanceSentences.isEmpty ? "A plugin screen in Abstract." : manifest.appearanceSentences.joined(separator: " "))
                    .font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
            if let plugin = item.installed {
                row(plugin)
            } else {
                primaryAction(item)
                Text("Installing opens a review of what this plugin can access.")
                    .font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.btSurface, in: RoundedRectangle(cornerRadius: 12))
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
                Text("Version \(record.version) · \(record.source.plainWords) · \(plugin.publisher.map { "Verified publisher: \($0)" } ?? "Unverified")")
            }
            .disabled(plugin.manifest == nil || plugin.problem != nil)

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
            ForEach(PluginCapability.askingCases.filter { record.grantedCapabilities.contains($0) },
                    id: \.rawValue) { capability in
                // A CLI asks first for its commands that change things (ABS-139).
                let words = capability == .cli
                    ? "Run \(record.grantedCLI?.binary ?? "its tool")'s commands that change things"
                    : capability.plainWords
                HStack(spacing: Space.sm) {
                    Text(record.alwaysAllowedActions.contains(capability)
                         ? "\(words) — always allowed."
                         : "\(words) — asks first.")
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
                if plugin.manifest != nil && record.source != .catalog {
                    Button("Review") { model.plugins.reviewChangedPackage(plugin.id) }
                }
            } else if let note = model.plugins.backgroundProblems[plugin.id] {
                // Its background script misbehaved (ABS-93); its screen
                // and places still work.
                HStack(spacing: Space.sm) {
                    Text("Its background work stopped working. \(note)")
                        .font(.btCaption).foregroundStyle(Color.btRemoved)
                    Button("Restart") { model.plugins.restartBackground(plugin.id) }
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

    private func download(_ entry: PluginCatalog.Entry) {
        catalogBusy = entry.id
        pickedProblem = nil
        Task {
            defer { catalogBusy = nil }
            do {
                let result = try await model.plugins.inspectCatalog(entry)
                pending = PendingInstall(folder: result.folder, inspection: result.inspection,
                                         cleanup: result.cleanup, source: .catalog)
            } catch {
                pickedProblem = error.localizedDescription
            }
        }
    }
}

/// The one review: name, version, where it came from, whether it's signed,
/// and what it may see — in plain words. Grants are all-or-nothing.
private struct PluginReviewSheet: View {
    let title: String
    let manifest: PluginManifest
    let source: PluginSource
    let publisher: String?
    let changes: PluginGrantChanges?
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
            Text("Version \(manifest.version) · \(source.plainWords) · \(publisher.map { "Verified publisher: \($0)" } ?? "Unverified")")
                .font(.btBody).foregroundStyle(Color.btTextSecondary)
            if let changes, changes.asksForMore {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This update asks for more:").font(.btBodyMedium)
                    ForEach(changes.capabilities, id: \.rawValue) { capability in
                        Text(capability.plainWords)
                    }
                    ForEach(changes.networkHosts, id: \.self) { host in Text("Reach \(host).") }
                    ForEach(changes.secretNames, id: \.self) { name in Text("Use your \(name).") }
                    ForEach(changes.places, id: \.self) { place in Text(place) }
                    if changes.background { Text("Run in the background.") }
                    if changes.cli { Text("Run more command-line actions.") }
                    Text("The installed version stays on until you approve this update.")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                }
            }
            if let description = manifest.description, !description.isEmpty {
                Text(description).font(.btBody).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if publisher == nil {
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
            if let cli = manifest.cli {
                // The binary and every command, in plain words (ABS-139).
                VStack(alignment: .leading, spacing: 4) {
                    Text("On your Mac, it will be able to:").font(.btBodyMedium).foregroundStyle(Color.btText)
                    ForEach(cli.sentences, id: \.self) { sentence in
                        Text(sentence).font(.btBody).foregroundStyle(Color.btTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
