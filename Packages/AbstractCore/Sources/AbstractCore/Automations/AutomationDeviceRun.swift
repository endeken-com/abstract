import Foundation

/// How one run of an automation starts on a paired Mac, worked out from the
/// automation and what that Mac last said about itself. Every way it can't
/// start throws the sentence the run is recorded as failed with.
public enum AutomationDeviceRun {
    /// - Parameters:
    ///   - snapshot: that Mac's last word on itself; nil when it isn't
    ///     connected now.
    ///   - localProject: the automation's project as this Mac has it, so
    ///     its record on the other Mac can be found.
    public static func plan(_ a: Automation, deviceName: String, snapshot: RemoteSnapshot?, localProject: Project?,
                            name: String, nameSource: ChatNameSource, slug: String?,
                            profile: AgentProfile? = nil) throws -> RemoteRunStart {
        // A run from a profile starts with the profile's setup as it is
        // now (ABS-101), on the other Mac as here.
        let a = a.resolved(with: profile)
        guard let snapshot else {
            throw AbstractError.message("\(deviceName) isn't connected, so this run didn't start.")
        }
        guard snapshot.automationDevice == true else {
            throw AbstractError.message("\(deviceName) needs a newer version of Abstract to run an automation started from here.")
        }
        let agent = RetiredAgents.current(a.providerId)
        guard snapshot.providers.contains(agent) else {
            throw AbstractError.message("\(ProviderRegistry.name(agent)) isn't available on \(deviceName), so this run didn't start.")
        }
        var projectId: String?
        if a.projectId != nil {
            guard let localProject else {
                throw AbstractError.message("Its project isn't on this Mac anymore, so this run didn't start.")
            }
            guard let counterpart = Project.counterpart(of: localProject, in: snapshot.projects) else {
                throw AbstractError.message("\(deviceName) doesn't have a project called “\(localProject.name)”, so this run didn't start.")
            }
            projectId = counterpart.id
        }
        return RemoteRunStart(projectId: projectId, providerId: a.providerId, prompt: a.prompt,
                              policy: a.permissionPolicy, model: a.model, effort: a.effort,
                              name: name, nameSource: nameSource,
                              slug: projectId == nil ? nil : slug, automationId: a.id,
                              profile: profile.flatMap { $0.id == a.profileId ? $0.snapshot : nil })
    }

    /// Whether that Mac has its own record of `project`, for the edit page
    /// to say so before a run finds out.
    public static func hasProject(_ project: Project, in snapshot: RemoteSnapshot) -> Bool {
        Project.counterpart(of: project, in: snapshot.projects) != nil
    }
}
