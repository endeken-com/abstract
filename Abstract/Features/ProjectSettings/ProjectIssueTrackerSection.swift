import SwiftUI
import AbstractCore

// MARK: - Issue tracker

/// Which team or project of each tracker this project uses (ABS-143).
/// Each tracker plugin that's on draws its own section, opened here, and
/// saves the link in its own storage; turning the plugin off hides its
/// row and keeps the link.
struct IssueTrackerSection: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var editing: ResolvedPluginContribution?

    var body: some View {
        let sections = model.plugins.contributions(.projectSettings)
        if !sections.isEmpty {
            PageSection(title: "Issue tracker",
                        detail: "The composer's issue search looks here first, and this project's agents are told which team and project it is.") {
                let trackers = model.projectIssueTrackers(project.id)
                ForEach(sections) { section in
                    let tracker = trackers.available.first { $0.pluginId == section.pluginId }
                    let link = trackers.linked.first { $0.tracker.pluginId == section.pluginId }?.link
                    HStack(alignment: .center, spacing: Space.sm) {
                        TrackerGlyph(pluginId: section.pluginId, size: 15)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tracker?.title ?? section.pluginName).font(.btBody).foregroundStyle(Color.btText)
                            Text(link?.title ?? "Not linked. Its search looks in every team and project.")
                                .font(.btCallout).foregroundStyle(Color.btTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Space.md)
                        Button(link == nil ? "Link…" : "Change…") { editing = section }
                            .buttonStyle(.bt(.ghost, size: .small))
                    }
                }
            }
            .sheet(item: $editing) { section in
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        Text(section.contribution.title).font(.btHeadline).foregroundStyle(Color.btText)
                        Spacer()
                        Button("Done") { editing = nil }.buttonStyle(.btPrimary)
                    }
                    PluginHostView(pluginId: section.pluginId, viewId: section.contribution.id,
                                   placement: PluginPlacement(place: .projectSettings, contributionId: section.contribution.id,
                                                              projectKey: model.pluginProjectKey(project.id)))
                        .frame(height: 360)
                }
                .padding(Space.xl)
                .frame(width: 520)
            }
        }
    }
}
