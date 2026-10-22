import Foundation

/// What a workflow does once a step's agent finishes its turn.
public enum WorkflowAdvance: String, Sendable, Hashable, Codable, CaseIterable {
    /// The next step starts on its own.
    case automatic
    /// The chat waits until you continue it.
    case wait

    public var title: String {
        switch self {
        case .automatic: "Continue automatically"
        case .wait: "Wait for me"
        }
    }

    public var detail: String {
        switch self {
        case .automatic: "The next step starts as soon as this one's turn ends."
        case .wait: "The chat waits for you to look and press Continue."
        }
    }
}

/// One step of a workflow: a profile takes the chat over and is asked to
/// do its part.
public struct WorkflowStep: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    /// The profile that does this step, as it is when the step starts.
    public var profileId: String
    /// What this step is asked to do; blank asks it to carry on as its
    /// profile from where the last step left off.
    public var prompt: String
    /// What happens when this step's turn ends.
    public var advance: WorkflowAdvance

    public init(id: String = UUID().uuidString, profileId: String, prompt: String = "", advance: WorkflowAdvance = .automatic) {
        self.id = id; self.profileId = profileId; self.prompt = prompt; self.advance = advance
    }

    private enum CodingKeys: String, CodingKey { case id, profileId, prompt, advance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
                  profileId: try c.decode(String.self, forKey: .profileId),
                  prompt: try c.decodeIfPresent(String.self, forKey: .prompt) ?? "",
                  advance: (try? c.decodeIfPresent(WorkflowAdvance.self, forKey: .advance)) ?? .automatic)
    }

    /// The prompt with something in it, else nil.
    public var nonBlankPrompt: String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Profiles taking turns on one chat: say, a UI researcher, then a
/// developer, a reviewer and QA. Each step hands the chat to its profile,
/// which picks up where the last one left off.
public struct Workflow: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    /// SF Symbol shown beside the name; nil = the default.
    public var iconSymbol: String?
    public var iconColor: String?
    public var iconImagePath: String?
    public var iconValue: IconValue {
        get { IconValue(symbol: iconSymbol, color: iconColor, imagePath: iconImagePath) }
        set { iconSymbol = newValue.symbol; iconColor = newValue.color; iconImagePath = newValue.imagePath }
    }
    public var steps: [WorkflowStep]
    public var sortOrder: Int
    public var createdAt: Date

    public static let defaultSymbol = "point.3.connected.trianglepath.dotted"

    public init(id: String = UUID().uuidString, name: String, iconSymbol: String? = nil,
                iconColor: String? = nil, iconImagePath: String? = nil, steps: [WorkflowStep] = [],
                sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.iconSymbol = iconSymbol; self.steps = steps
        self.iconColor = iconColor; self.iconImagePath = iconImagePath
        self.sortOrder = sortOrder; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconSymbol, iconColor, iconImagePath, steps, sortOrder, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  iconSymbol: try c.decodeIfPresent(String.self, forKey: .iconSymbol),
                  iconColor: try c.decodeIfPresent(String.self, forKey: .iconColor),
                  iconImagePath: try c.decodeIfPresent(String.self, forKey: .iconImagePath),
                  steps: try c.decodeIfPresent([WorkflowStep].self, forKey: .steps) ?? [],
                  sortOrder: try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0,
                  createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0))
    }

    /// What a chat running this workflow carries: its steps as they are
    /// now, so editing the workflow changes later chats, never one already
    /// running it. Each step's profile is read again when the step starts;
    /// the copy kept here stands in when it's gone, or on another Mac.
    public func snapshot(profiles: [AgentProfile]) -> WorkflowSnapshot {
        let byId = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return WorkflowSnapshot(id: id, name: name, icon: iconValue, steps: steps.map {
            WorkflowSnapshot.Step(step: $0, profileName: byId[$0.profileId]?.name ?? "Deleted profile", profile: byId[$0.profileId])
        })
    }

    /// Why it can't run, in a few words; nil when it can.
    public func problem(profiles: [AgentProfile]) -> String? {
        if steps.isEmpty { return "It has no steps yet." }
        let known = Set(profiles.map(\.id))
        if let index = steps.firstIndex(where: { !known.contains($0.profileId) }) {
            return "Step \(index + 1)'s profile was deleted."
        }
        return nil
    }
}

/// A workflow as a chat started it.
public struct WorkflowSnapshot: Sendable, Hashable, Codable {
    public struct Step: Sendable, Hashable, Codable {
        public var step: WorkflowStep
        /// The profile's name when the workflow started, for showing the
        /// steps still to come.
        public var profileName: String
        /// The profile as it was then.
        public var profile: AgentProfile?

        public init(step: WorkflowStep, profileName: String, profile: AgentProfile? = nil) {
            self.step = step; self.profileName = profileName; self.profile = profile
        }

        /// The profile that takes this step: as it is now, else as it was.
        public func resolve(in profiles: [AgentProfile]) -> AgentProfile? {
            profiles.first { $0.id == step.profileId } ?? profile
        }
    }

    public var id: String
    public var name: String
    public var icon: IconValue?
    public var steps: [Step]

    public init(id: String, name: String, icon: IconValue? = nil, steps: [Step]) {
        self.id = id; self.name = name; self.icon = icon; self.steps = steps
    }
}

/// Where a chat is in its workflow.
public struct WorkflowProgress: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable {
        /// The current step's agent has the chat.
        case working
        /// The current step is done and the chat waits for you to continue.
        case waiting
        /// Every step is done.
        case finished
        /// Stopped by you, or a step couldn't start.
        case stopped
    }

    public var workflow: WorkflowSnapshot
    /// The current step, from 0.
    public var step: Int
    public var state: State
    /// Why it stopped, when it stopped on its own.
    public var note: String?

    public init(workflow: WorkflowSnapshot, step: Int = 0, state: State = .working, note: String? = nil) {
        self.workflow = workflow; self.step = step; self.state = state; self.note = note
    }

    public var current: WorkflowSnapshot.Step? { workflow.steps.indices.contains(step) ? workflow.steps[step] : nil }
    public var next: WorkflowSnapshot.Step? { workflow.steps.indices.contains(step + 1) ? workflow.steps[step + 1] : nil }
    public var isLastStep: Bool { step >= workflow.steps.count - 1 }
    /// Still going: working or waiting for you.
    public var isActive: Bool { state == .working || state == .waiting }

    /// "Step 2 of 4"
    public var position: String { "Step \(min(step + 1, workflow.steps.count)) of \(workflow.steps.count)" }
}

/// The rules that move a chat through its workflow, apart from starting
/// agents: the app feeds them how a turn ended and does what they say.
public enum WorkflowEngine {
    public enum Next: Sendable, Hashable {
        /// Nothing to do: no workflow, or the turn didn't finish the step.
        case none
        /// Hand the chat to step `to` now.
        case advance(to: Int)
        /// The step is done; wait for you before step `next`.
        case waitForYou(next: Int)
        /// The last step is done.
        case finished
    }

    /// After a turn ends in a chat. A step is done when its agent's turn
    /// ended on its own (not stopped, not failed), with nothing queued. One
    /// that left work running in the background waits for you rather than
    /// hand the chat on under it: nothing says when that work ends.
    public static func afterTurn(_ progress: WorkflowProgress?, status: SessionStatus, stopped: Bool,
                                 queued: Bool, backgroundTasks: Int) -> Next {
        guard let progress, progress.state == .working, let current = progress.current else { return .none }
        guard status == .idle || status == .finished, !stopped, !queued else { return .none }
        if progress.isLastStep { return .finished }
        let next = progress.step + 1
        return current.step.advance == .automatic && backgroundTasks == 0 ? .advance(to: next) : .waitForYou(next: next)
    }

    /// The first message of a workflow's chat: the first step's prompt,
    /// if it has one, ahead of the task.
    public static func firstMessage(_ snapshot: WorkflowSnapshot, task: String) -> String {
        guard let prompt = snapshot.steps.first?.step.nonBlankPrompt else { return task }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? prompt : "\(prompt)\n\n\(trimmed)"
    }

    /// What the agent taking step `index` over is told.
    public static func message(_ snapshot: WorkflowSnapshot, step index: Int, profileName: String) -> String {
        let step = snapshot.steps[index].step
        let ask = step.nonBlankPrompt
            ?? "Pick up the work in this chat from where the last step left it, and do your part as \(profileName)."
        let next = snapshot.steps.indices.contains(index + 1) ? " \(snapshot.steps[index + 1].profileName) takes over after you." : ""
        return "You're step \(index + 1) of \(snapshot.steps.count) in the “\(snapshot.name)” workflow, "
            + "taking this chat over as \(profileName).\(next)\n\n\(ask)"
    }

    /// The line the transcript shows when a step starts.
    public static func stepNote(_ snapshot: WorkflowSnapshot, step index: Int, profileName: String) -> String {
        "\(snapshot.name): step \(index + 1) of \(snapshot.steps.count), \(profileName)"
    }
}

public extension Session {
    /// Hand this chat to `profile` for a workflow step: its agent, model,
    /// effort and permissions, and its name and instructions.
    mutating func takeStep(_ profile: AgentProfile, in progress: WorkflowProgress) {
        apply(profile)
        workflow = progress
    }
}

// MARK: - Templates

/// A ready-made workflow, with the profiles it needs.
public struct WorkflowTemplate: Sendable, Hashable, Identifiable {
    public struct Step: Sendable, Hashable {
        public var profile: AgentProfile
        public var prompt: String
        public var advance: WorkflowAdvance
    }

    public var id: String { name }
    public var name: String
    public var iconSymbol: String
    public var detail: String
    public var steps: [Step]

    /// The workflow, reusing profiles that already exist by name and
    /// returning the ones it had to make.
    public func make(existing: [AgentProfile], sortOrder: Int) -> (workflow: Workflow, newProfiles: [AgentProfile]) {
        var made: [AgentProfile] = []
        var nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let steps = steps.map { step -> WorkflowStep in
            let name = step.profile.name.lowercased()
            if let found = (existing + made).first(where: { $0.name.lowercased() == name }) {
                return WorkflowStep(profileId: found.id, prompt: step.prompt, advance: step.advance)
            }
            var profile = step.profile
            profile.id = UUID().uuidString
            profile.sortOrder = nextOrder
            nextOrder += 1
            made.append(profile)
            return WorkflowStep(profileId: profile.id, prompt: step.prompt, advance: step.advance)
        }
        return (Workflow(name: name, iconSymbol: iconSymbol, steps: steps, sortOrder: sortOrder), made)
    }

    public static let uiResearcher = AgentProfile(
        name: "UI Researcher", iconSymbol: "paintpalette", providerId: "claude", permissionPolicy: .ask,
        instructions: "You research the interface before anything is built. Look at how well-made products solve the same problem (Dribbble, Mobbin and the apps people already know), then study this project's own screens and components. Write a short design direction: the layout, the states to cover, the components to reuse, and two or three references with what to take from each. You do not change code.")
    public static let qa = AgentProfile(
        name: "QA", iconSymbol: "checkmark.seal", providerId: "claude", permissionPolicy: .autoEdits,
        instructions: "You test the change the way a careful user would. Build and run the project, exercise the new behaviour and the paths around it, including empty, error and edge cases, and run the test suite. Fix what you find when the fix is small and clear; otherwise report it with the steps to reproduce. End with what you tested and what passed.")

    public static let all: [WorkflowTemplate] = [
        WorkflowTemplate(
            name: "Design, build, review, test", iconSymbol: "paintpalette",
            detail: "UI Researcher, Implementer, Reviewer and QA",
            steps: [
                Step(profile: uiResearcher, prompt: "", advance: .wait),
                Step(profile: AgentProfile.starters[0], prompt: "Build it, following the design direction above.", advance: .automatic),
                Step(profile: AgentProfile.starters[1], prompt: "Review the changes made in this chat.", advance: .automatic),
                Step(profile: qa, prompt: "", advance: .automatic),
            ]),
        WorkflowTemplate(
            name: "Plan, build, review", iconSymbol: "list.bullet.clipboard",
            detail: "Planner, Implementer and Reviewer",
            steps: [
                Step(profile: AgentProfile.starters[2], prompt: "", advance: .wait),
                Step(profile: AgentProfile.starters[0], prompt: "Carry out the plan above.", advance: .automatic),
                Step(profile: AgentProfile.starters[1], prompt: "Review the changes made in this chat.", advance: .automatic),
            ]),
    ]
}
