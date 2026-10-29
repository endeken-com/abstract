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
    @State private var afterDetail: (() -> Void)?
    @State private var catalogBusy: String?
    @State private var catalogLoading = true
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
        galleryContent
        .sheet(isPresented: Binding(get: { selectedPluginID != nil }, set: { if !$0 { selectedPluginID = nil } }),
               onDismiss: {
                   let action = afterDetail
                   afterDetail = nil
                   action?()
               }) {
            if let selectedPluginID, let item = items.first(where: { $0.id == selectedPluginID }) {
                detail(item)
            }
        }
        .sheet(item: $pending) { item in pendingReview(item) }
        .sheet(item: $settingsPageFor) { plugin in settingsPage(plugin) }
        .sheet(item: $enabling) { plugin in enableReview(plugin) }
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

    private var galleryContent: some View {
        let all = items
        return VStack(alignment: .leading, spacing: Space.lg) {
            searchField
            filterBar
            if !all.isEmpty { categoryBar(all) }
            catalogStatus(all)
            if let pickedProblem {
                notice("This plugin could not be opened", detail: pickedProblem, symbol: "exclamationmark.triangle")
            }
            galleryResults(all)
            if !model.plugins.orphans.isEmpty { orphanSection }
        }
        .padding(.horizontal, SettingsLayout.margin + SettingsLayout.textInset)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: SettingsLayout.rowWidth + 2 * SettingsLayout.margin, alignment: .leading)
        .frame(maxWidth: .infinity)
        .task { await reloadCatalog() }
    }

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.btTextTertiary)
            TextField("Search plugins", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search plugins")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 34)
        .background(Color.btField, in: shape)
        .overlay(shape.strokeBorder(Color.btFieldBorder))
    }

    private var filterBar: some View {
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
    }

    private func categoryBar(_ all: [PluginGalleryItem]) -> some View {
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

    @ViewBuilder
    private func catalogStatus(_ all: [PluginGalleryItem]) -> some View {
        if let problem = model.plugins.catalogProblem {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "wifi.exclamationmark")
                    .frame(width: 20).foregroundStyle(Color.btTextSecondary)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("The catalog is unavailable").font(.btBodyMedium).foregroundStyle(Color.btText)
                    Text("Installed and bundled plugins still work. \(problem)")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    Button("Try Again") { Task { await reloadCatalog() } }
                        .buttonStyle(.bt(.secondary, size: .small))
                        .padding(.top, Space.xs)
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.btHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        } else if catalogLoading && !all.isEmpty {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text("Checking the catalog…").font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
        }
    }

    private func notice(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(Color.btRemoved)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.btBodyMedium).foregroundStyle(Color.btText)
                Text(detail).font(.btCaption).foregroundStyle(Color.btTextSecondary)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.btHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    @ViewBuilder
    private func galleryResults(_ all: [PluginGalleryItem]) -> some View {
        let visible = PluginGalleryItem.filter(all, query: query, view: selectedView, category: selectedCategory)
        if visible.isEmpty {
            if catalogLoading && all.isEmpty {
                VStack(spacing: Space.md) {
                    ProgressView().controlSize(.regular)
                    Text("Checking the catalog…").font(.btBody).foregroundStyle(Color.btTextSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if all.isEmpty {
                EmptyStateView(symbol: emptySymbol, title: emptyTitle, message: emptyMessage,
                               action: ("Install from folder or zip…", { pickPackage() }))
                    .frame(minHeight: 180)
            } else {
                EmptyStateView(symbol: emptySymbol, title: emptyTitle, message: emptyMessage)
                    .frame(minHeight: 180)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: Space.md)],
                      alignment: .leading, spacing: Space.md) {
                ForEach(visible) { item in galleryCard(item) }
            }
        }
    }

    private var orphanSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Packages that could not be read").font(.btHeadline)
            ForEach(model.plugins.orphans, id: \.name) { orphan in
                notice(orphan.name, detail: orphan.problem, symbol: "exclamationmark.triangle")
            }
        }
    }

    private func pendingReview(_ item: PendingInstall) -> some View {
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

    @ViewBuilder
    private func settingsPage(_ plugin: InstalledPlugin) -> some View {
        if let page = plugin.manifest?.contributes.settingsPage {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(page.title).font(.btHeadline).foregroundStyle(Color.btText)
                        Text("\(plugin.record.name) settings")
                            .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    }
                    Spacer()
                    Button("Done") { settingsPageFor = nil }
                        .buttonStyle(.btPrimary)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(Space.xl)
                Divider()
                PluginHostView(pluginId: plugin.id, viewId: page.id,
                               placement: PluginPlacement(place: .settings, contributionId: page.id))
                    .frame(minHeight: 380)
            }
            .frame(width: 560)
        }
    }

    private func enableReview(_ plugin: InstalledPlugin) -> some View {
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

    private var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a different search or category."
        }
        if selectedCategory != nil { return "Try another category or show all kinds." }
        switch selectedView {
        case .all: return "Add a plugin from a folder or zip to get started."
        case .installed: return "Plugins you install will appear here."
        case .updates: return "Updates and plugins needing review will appear here."
        }
    }

    private var emptyTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCategory != nil {
            return "No matching plugins"
        }
        switch selectedView {
        case .all: return "No plugins yet"
        case .installed: return "No installed plugins"
        case .updates: return "You're up to date"
        }
    }

    private var emptySymbol: String {
        selectedView == .updates ? "checkmark.circle" : "puzzlepiece.extension"
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
            .buttonStyle(.btSecondary)
    }

    private func categoryButton(_ title: String, category: PluginGalleryItem.Category?) -> some View {
        Button(title) { selectedCategory = category }
            .buttonStyle(.bt(category == selectedCategory ? .secondary : .ghost, size: .small))
    }

    private func galleryCard(_ item: PluginGalleryItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                PluginIcon(symbol: item.symbol, size: 40)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(item.name).font(.btBodyMedium).foregroundStyle(Color.btText)
                        .lineLimit(1)
                    Text(item.category.rawValue).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                }
                Spacer(minLength: 0)
            }
            Text(item.summary).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: Space.xs) {
                statusLabel(item)
                Text("· \(item.source.plainWords)")
                    .font(.btCaption).foregroundStyle(Color.btTextTertiary)
                    .lineLimit(1)
            }
            HStack(spacing: Space.sm) {
                Button("Details") { selectedPluginID = item.id }
                    .buttonStyle(.bt(.ghost, size: .small))
                Spacer(minLength: 0)
                primaryAction(item)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Color.btSurface, in: shape)
        .overlay(shape.strokeBorder(Color.btBorder, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private func statusLabel(_ item: PluginGalleryItem) -> some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(item.state == .installed ? Color.btAdded : item.state == .needsReview || item.state == .problem
                      ? Color.btRemoved : Color.btTextTertiary)
                .frame(width: 6, height: 6)
            Text(item.statusText).lineLimit(1)
        }
        .font(.btCaption)
        .foregroundStyle(Color.btTextSecondary)
    }

    @ViewBuilder
    private func primaryAction(_ item: PluginGalleryItem) -> some View {
        switch item.state {
        case .available:
            Button(catalogBusy == item.id ? "Loading…" : "Install") {
                afterClosingDetails { install(item) }
            }
                .buttonStyle(.bt(.secondary, size: .small))
                .disabled(catalogBusy != nil)
        case .updateAvailable:
            Button(catalogBusy == item.id ? "Loading…" : "Update") {
                if let entry = item.catalogEntry { afterClosingDetails { download(entry) } }
            }
                .buttonStyle(.bt(.secondary, size: .small))
                .disabled(catalogBusy != nil)
        case .disabled:
            Button("Enable") { afterClosingDetails { enabling = item.installed } }
                .buttonStyle(.bt(.secondary, size: .small))
        case .needsReview, .problem:
            Button("Review") { selectedPluginID = item.id }
                .buttonStyle(.bt(.secondary, size: .small))
        case .installed:
            if let plugin = item.installed, let view = plugin.view {
                Button("Open") {
                    model.destination = .plugin(plugin.id, view.id)
                    model.isSettingsOpen = false
                }
                .buttonStyle(.bt(.secondary, size: .small))
            } else {
                Button("Manage") { selectedPluginID = item.id }
                    .buttonStyle(.bt(.secondary, size: .small))
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.md) {
                PluginIcon(symbol: item.symbol, size: 44)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(item.name).font(.btHeadline).foregroundStyle(Color.btText)
                    HStack(spacing: Space.sm) {
                        Text(item.category.rawValue).font(.btCaption).foregroundStyle(Color.btTextSecondary)
                        Text("·").foregroundStyle(Color.btTextTertiary)
                        statusLabel(item)
                    }
                }
                Spacer()
                Button { selectedPluginID = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.icon(size: 26))
                    .help("Close plugin details")
                    .accessibilityLabel("Close plugin details")
            }
            .padding(Space.xl)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text(item.summary).font(.btBody).foregroundStyle(Color.btTextSecondary)
                    Text("Version \(item.version) · \(item.source.plainWords) · \(item.publisher.map { "Verified publisher: \($0)" } ?? "Unverified")")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    if let manifest = item.installed?.manifest ?? bundled.first(where: { $0.inspection.manifest.id == item.id })?.inspection.manifest {
                        Divider().padding(.vertical, Space.xs)
                        Text("What it adds").font(.btBodyMedium).foregroundStyle(Color.btText)
                        Text(manifest.appearanceSentences.isEmpty ? "A plugin screen in Abstract." : manifest.appearanceSentences.joined(separator: " "))
                            .font(.btBody).foregroundStyle(Color.btTextSecondary)
                    }
                    if let plugin = item.installed {
                        Divider().padding(.vertical, Space.xs)
                        row(plugin)
                    } else {
                        Text("Installing opens a review of what this plugin can access.")
                            .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.xl)
            }
            .frame(minHeight: 160, maxHeight: 510)
            Divider()
            if let plugin = item.installed {
                pluginActions(plugin)
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.md)
            } else {
                HStack {
                    Spacer()
                    primaryAction(item)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.md)
            }
        }
        .frame(width: 560)
    }

    @ViewBuilder
    private func row(_ plugin: InstalledPlugin) -> some View {
        let record = plugin.record
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .center, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Turned \(plugin.isUsable ? "on" : "off")")
                        .font(.btBodyMedium).foregroundStyle(Color.btText)
                    Text("Choose whether this plugin can run in Abstract.")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                }
                Spacer()
                Toggle("Turn on \(record.name)", isOn: Binding(
                    get: { plugin.isUsable },
                    set: { on in
                        if on { afterClosingDetails { enabling = plugin } }
                        else { model.setPluginEnabled(plugin.id, false) }
                    }
                ))
                .labelsHidden()
                .disabled(plugin.manifest == nil || plugin.problem != nil)
            }

            if let manifest = plugin.manifest, !manifest.grantedCapabilities.isEmpty {
                Divider()
                Text("Permissions").font(.btBodyMedium).foregroundStyle(Color.btText)
                // What it actually holds now; before its first review,
                // what it asks for.
                Text((record.grantedCapabilities.isEmpty ? manifest.grantedCapabilities : record.grantedCapabilities).map {
                    $0.plainWords(transcriptProjects: model.pluginProjectNames(record.transcriptProjectKeys))
                }.sorted().joined(separator: "\n"))
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
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(record.alwaysAllowedActions.contains(capability)
                         ? "\(words) — always allowed."
                         : "\(words) — asks first.")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    HStack(spacing: Space.sm) {
                        if record.alwaysAllowedActions.contains(capability) {
                            Button("Ask First") { model.plugins.setAlwaysAllowed(plugin.id, capability, false) }
                                .buttonStyle(.bt(.secondary, size: .small))
                        }
                        Button("Revoke") { model.plugins.revokeCapability(plugin.id, capability) }
                            .buttonStyle(.bt(.danger, size: .small))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.md)
                .background(Color.btHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            if let problem = plugin.problem {
                Text(problem).font(.btCaption).foregroundStyle(Color.btRemoved)
                if plugin.manifest != nil && record.source != .catalog {
                    Button("Review") { model.plugins.reviewChangedPackage(plugin.id) }
                        .buttonStyle(.btSecondary)
                }
            } else if let note = model.plugins.backgroundProblems[plugin.id] {
                // Its background script misbehaved (ABS-93); its screen
                // and places still work.
                HStack(spacing: Space.sm) {
                    Text("Its background work stopped working. \(note)")
                        .font(.btCaption).foregroundStyle(Color.btRemoved)
                    Button("Restart") { model.plugins.restartBackground(plugin.id) }
                        .buttonStyle(.btSecondary)
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
        }
        .padding(.vertical, 2)
    }

    private func pluginActions(_ plugin: InstalledPlugin) -> some View {
        HStack(spacing: Space.sm) {
            if plugin.isUsable, let view = plugin.view {
                Button("Open") {
                    model.destination = .plugin(plugin.id, view.id)
                    model.isSettingsOpen = false
                }
                .buttonStyle(.btSecondary)
            }
            if plugin.isUsable, let page = plugin.manifest?.contributes.settingsPage {
                Button(page.title) { afterClosingDetails { settingsPageFor = plugin } }
                    .buttonStyle(.btSecondary)
            }
            if plugin.isUsable, plugin.manifest?.grantedCapabilities.contains(.transcriptsRead) == true {
                Button("Choose Projects…") { afterClosingDetails { enabling = plugin } }
                    .buttonStyle(.btSecondary)
            }
            Spacer(minLength: 0)
            Button("Remove", role: .destructive) { afterClosingDetails { removing = plugin } }
                .buttonStyle(.btDanger)
        }
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

    private func reloadCatalog() async {
        catalogLoading = true
        await model.plugins.loadCatalog()
        catalogLoading = false
    }

    private func afterClosingDetails(_ action: @escaping () -> Void) {
        if selectedPluginID == nil { action() }
        else {
            afterDetail = action
            selectedPluginID = nil
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

private struct PluginIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .regular))
            .foregroundStyle(Color.btText)
            .frame(width: size, height: size)
            .background(Color.btHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.md) {
                PluginIcon(symbol: manifest.view?.symbolOrFallback ?? PluginManifest.fallbackSymbol, size: 44)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(title).font(.btHeadline).foregroundStyle(Color.btText)
                    Text("Version \(manifest.version) · \(source.plainWords)")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                }
            }
            .padding(Space.xl)
            Divider()
            ScrollView {
                reviewContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.xl)
            }
            .frame(minHeight: 180, maxHeight: 520)
            Divider()
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(.btGhost)
                    .keyboardShortcut(.cancelAction)
                if let secondaryLabel {
                    Button(secondaryLabel) { confirm(false, pickedKeys) }
                        .buttonStyle(.btSecondary)
                }
                Button(primaryLabel) { confirm(true, pickedKeys) }
                    .buttonStyle(.btPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
        }
        .frame(width: 560)
        .onAppear { pickedProjects = Set(initialProjectKeys) }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if let changes, changes.asksForMore {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("This update asks for more").font(.btBodyMedium).foregroundStyle(Color.btText)
                    ForEach(changes.capabilities, id: \.rawValue) { capability in
                        reviewItem(capability.plainWords)
                    }
                    ForEach(changes.networkHosts, id: \.self) { host in reviewItem("Reach \(host).") }
                    ForEach(changes.secretNames, id: \.self) { name in reviewItem("Use your \(name).") }
                    ForEach(changes.places, id: \.self) { place in reviewItem(place) }
                    if changes.background { reviewItem("Run in the background.") }
                    if changes.cli { reviewItem("Run more command-line actions.") }
                    Text("The installed version stays on until you approve this update.")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.btHover, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            if let description = manifest.description, !description.isEmpty {
                Text(description).font(.btBody).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(publisher.map { "Verified publisher: \($0)" } ?? "Unverified publisher")
                .font(.btCaption).foregroundStyle(Color.btTextSecondary)
            if publisher == nil {
                Text(manifest.networkHosts.isEmpty
                     ? "It isn't signed. It runs in a locked-down page with no network or file access, and it can only see and do what's listed here."
                     : "It isn't signed. It runs in a locked-down page, and Abstract sends its web requests for it — only to the addresses listed here.")
                    .font(.btBody).foregroundStyle(Color.btTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Where it appears").font(.btBodyMedium).foregroundStyle(Color.btText)
                ForEach(manifest.appearanceSentences, id: \.self) { sentence in
                    reviewItem(sentence)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("What it can access").font(.btBodyMedium).foregroundStyle(Color.btText)
                if manifest.grantedCapabilities.isEmpty {
                    Text("Nothing beyond showing its own screen.")
                        .font(.btBody).foregroundStyle(Color.btTextSecondary)
                }
                ForEach(manifest.grantedCapabilities.map {
                    $0.plainWords(transcriptProjects: pickedNames)
                }.sorted(), id: \.self) { words in
                    reviewItem(words)
                }
                if manifest.grantedCapabilities.contains(where: \.isAction) {
                    Text("Before it starts a chat, sends a message, stops or resumes an agent, answers for you, or runs an automation, Abstract will ask you first. You can let it always do one of those, and take any of them back here in Settings.")
                        .font(.btBody).foregroundStyle(Color.btTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let cli = manifest.cli {
                // The binary and every command, in plain words (ABS-139).
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("On your Mac, it will be able to:").font(.btBodyMedium).foregroundStyle(Color.btText)
                    ForEach(cli.sentences, id: \.self) { sentence in
                        reviewItem(sentence)
                    }
                }
            }
            if !manifest.networkSentences.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("On the web, it will be able to:").font(.btBodyMedium).foregroundStyle(Color.btText)
                    ForEach(manifest.networkSentences, id: \.self) { sentence in
                        reviewItem(sentence)
                    }
                }
            }
            if manifest.grantedCapabilities.contains(.transcriptsRead) {
                VStack(alignment: .leading, spacing: Space.sm) {
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
        }
    }

    private func reviewItem(_ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(Color.btTextTertiary)
                .accessibilityHidden(true)
            Text(words).font(.btBody).foregroundStyle(Color.btTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(secret.title).font(.btBodyMedium).foregroundStyle(Color.btText)
            if entered {
                HStack(spacing: Space.sm) {
                    Text("Entered — kept in your Keychain.")
                        .font(.btCaption).foregroundStyle(Color.btTextSecondary)
                    Spacer()
                    Button("Remove") {
                        model.plugins.setSecret(nil, pluginId: pluginId, name: secret.name)
                        entered = false
                    }
                    .buttonStyle(.bt(.danger, size: .small))
                }
            } else {
                HStack(spacing: Space.sm) {
                    SecureField(secret.title, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Button("Save") {
                        model.plugins.setSecret(draft, pluginId: pluginId, name: secret.name)
                        draft = ""
                        entered = model.plugins.hasSecret(pluginId: pluginId, name: secret.name)
                    }
                    .buttonStyle(.bt(.secondary, size: .small))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { entered = model.plugins.hasSecret(pluginId: pluginId, name: secret.name) }
    }
}
