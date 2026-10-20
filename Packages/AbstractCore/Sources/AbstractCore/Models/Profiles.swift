import Foundation

/// A named setup a chat or automation starts from (ABS-101): which agent
/// runs, on which model and effort, how much it may do without asking,
/// and the instructions it is given every time. Choosing one fills those
/// fields in; they can still be changed for that chat, which keeps the
/// values it started with.
public struct AgentProfile: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    /// SF Symbol shown beside the name; nil = the default person.
    public var iconSymbol: String?
    public var providerId: String
    /// Model name or alias; nil = the agent's configured default.
    public var model: String?
    /// Reasoning effort, e.g. "high"; nil = the agent's own default.
    public var effort: String?
    public var permissionPolicy: PermissionPolicy
    /// Markdown given to the agent at every start.
    public var instructions: String
    /// Skills and MCP servers the profile asks for. Kept with the
    /// profile so they can be handed to the agent once those can be
    /// given per chat; nothing reads them yet.
    public var skills: [String] = []
    public var mcpServers: [String] = []
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString, name: String, iconSymbol: String? = nil,
        providerId: String = "claude", model: String? = nil, effort: String? = nil,
        permissionPolicy: PermissionPolicy = .ask, instructions: String = "",
        skills: [String] = [], mcpServers: [String] = [], sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id; self.name = name; self.iconSymbol = iconSymbol
        self.providerId = providerId; self.model = model; self.effort = effort
        self.permissionPolicy = permissionPolicy; self.instructions = instructions
        self.skills = skills; self.mcpServers = mcpServers
        self.sortOrder = sortOrder; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconSymbol, providerId, model, effort, permissionPolicy
        case instructions, skills, mcpServers, sortOrder, createdAt
    }

    /// A profile saved before a field existed reads with its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            iconSymbol: try c.decodeIfPresent(String.self, forKey: .iconSymbol),
            providerId: try c.decodeIfPresent(String.self, forKey: .providerId) ?? "claude",
            model: try c.decodeIfPresent(String.self, forKey: .model),
            effort: try c.decodeIfPresent(String.self, forKey: .effort),
            permissionPolicy: try c.decodeIfPresent(PermissionPolicy.self, forKey: .permissionPolicy) ?? .ask,
            instructions: try c.decodeIfPresent(String.self, forKey: .instructions) ?? "",
            skills: try c.decodeIfPresent([String].self, forKey: .skills) ?? [],
            mcpServers: try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? [],
            sortOrder: try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0,
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSinceReferenceDate: 0))
    }

    /// What a chat started from this profile keeps: its name for the
    /// header and its instructions as they were at the start, so editing
    /// the profile changes later chats, never a running one.
    public var snapshot: ProfileSnapshot {
        ProfileSnapshot(id: id, name: name, instructions: instructions)
    }

    /// The profiles every install starts with. Plain profiles once saved:
    /// they can be edited or deleted like any other. Planner's
    /// instructions ask for a plan first; Plan mode itself is picked
    /// per message in the composer (ABS-104).
    public static let starters: [AgentProfile] = [
        AgentProfile(
            name: "Implementer", iconSymbol: "hammer", providerId: "claude",
            permissionPolicy: .autoEdits,
            instructions: "You implement the task you are given. Read the surrounding code first, make the smallest change that does the job, and run the project's tests before you finish. Say plainly what you changed and what you verified.",
            sortOrder: 0),
        AgentProfile(
            name: "Reviewer", iconSymbol: "magnifyingglass", providerId: "codex",
            effort: "high", permissionPolicy: .ask,
            instructions: "You review the changes you are shown; you do not make changes of your own. Read the diff and the code around it, then report what is wrong or risky, most serious first, naming the file and line for each point. Say what you checked and found sound, too.",
            sortOrder: 1),
        AgentProfile(
            name: "Planner", iconSymbol: "list.bullet.clipboard", providerId: "claude",
            permissionPolicy: .ask,
            instructions: "You plan the task before any work starts. Explore the code as needed, then write a short plan: what will change, in which files, in what order, and how it will be checked. Ask for approval of the plan before changing anything.",
            sortOrder: 2),
    ]

    /// The profiles on offer for a project: all of them, unless the
    /// project picked which ones show. A chat with no project sees all.
    public static func visible(_ profiles: [AgentProfile], in project: Project?) -> [AgentProfile] {
        guard let picked = project?.profileIds else { return profiles }
        let allowed = Set(picked)
        return profiles.filter { allowed.contains($0.id) }
    }
}

/// The part of a profile a chat carries with it once started: its id and
/// name, and its instructions as they were then.
public struct ProfileSnapshot: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var instructions: String

    public init(id: String, name: String, instructions: String) {
        self.id = id; self.name = name; self.instructions = instructions
    }

    /// The instructions with something in them, else nil.
    public var nonBlankInstructions: String? {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : instructions
    }
}

public extension Session {
    /// The profile this chat started from, as it was then; nil when it
    /// started from none.
    var profileSnapshot: ProfileSnapshot? {
        guard let profileId, let profileName else { return nil }
        return ProfileSnapshot(id: profileId, name: profileName, instructions: profileInstructions ?? "")
    }

    /// Start this chat from `profile`: its agent, model, effort and
    /// permissions, with its name and instructions kept for its lifetime.
    mutating func apply(_ profile: AgentProfile) {
        providerId = profile.providerId
        model = profile.model
        effort = profile.effort
        permissionPolicy = profile.permissionPolicy
        apply(profile.snapshot)
    }

    /// Keep a profile's name and instructions, for a chat whose agent,
    /// model, effort and permissions were already filled in from it
    /// (and may have been changed since), or that arrived from another Mac.
    mutating func apply(_ snapshot: ProfileSnapshot) {
        profileId = snapshot.id
        profileName = snapshot.name
        profileInstructions = snapshot.nonBlankInstructions
    }
}

public extension Automation {
    /// This automation as one run of it starts: with a profile, the
    /// profile's agent, model, effort and permissions as they are now,
    /// so editing the profile changes later runs. Without one, itself.
    func resolved(with profile: AgentProfile?) -> Automation {
        guard let profile, profile.id == profileId else { return self }
        var run = self
        run.providerId = profile.providerId
        run.model = profile.model
        run.effort = profile.effort
        run.permissionPolicy = profile.permissionPolicy
        return run
    }
}
