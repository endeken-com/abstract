import Foundation

/// A fresh-worktree automation run's chat: named for its automation and
/// start time until its agent's first turn ends, then for what the agent
/// says it worked on. The prompt is the same every run, so it can't name one.
public enum AutomationRunNaming {
    static let separator = " · "

    /// The name a run's chat starts with.
    public static func provisional(_ automationName: String, at date: Date) -> String {
        automationName + separator + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Whether a run's chat still has the name it started with.
    public static func isProvisional(_ name: String, automationName: String) -> Bool {
        name.hasPrefix(automationName + separator)
    }

    /// What the naming call summarizes: the agent's report, not the instructions it followed.
    public static func task(fromReport report: String) -> String {
        "Name this chat for the work the agent's report says it did, not for the instructions it followed.\n\n" + report
    }
}
