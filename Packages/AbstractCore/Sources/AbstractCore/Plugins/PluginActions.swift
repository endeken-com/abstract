import Foundation

/// What a plugin asks Abstract to do to a chat or an automation (ABS-92).
/// The bridge builds one only from a granted, well-formed message; the
/// host shows `describe` when the kind still asks first, then carries it
/// out. Nothing here acts on anything by itself.
public struct PluginAction: Sendable, Equatable {
    public var capability: PluginCapability
    /// The chat it acts on: `chats.message`, `chats.control`,
    /// `permissions.answer`.
    public var chatId: String?
    /// The project a new chat starts in, as the snapshot names it;
    /// nil starts a standalone chat.
    public var projectKey: String?
    /// The message or the new chat's prompt.
    public var text: String?
    /// The agent a new chat runs; nil takes the project's usual agent.
    public var agentId: String?
    /// A new chat's permission level (a `PermissionPolicy` raw value
    /// from the autonomy levels); nil takes the project's usual level.
    public var policy: String?
    public var control: Control?
    /// The permission request or question being answered.
    public var requestId: String?
    /// A permission answer: allow or decline.
    public var allow: Bool?
    /// A question's answers, by question text.
    public var answers: [String: String] = [:]
    public var automationId: String?
    /// A new chat that reviews this chat's changes, read-only, in its
    /// worktree (ABS-112).
    public var reviewOf: String?
    /// A child chat starts from this chat's branch.
    public var parentId: String?
    public var title: String?
    /// `chats.message` sending the chat's Review comments, as your own
    /// Send would, instead of `text`.
    public var sendsReview = false
    /// Several permission requests allowed at once (ABS-111): each one
    /// runs exactly the same command. Empty for every other action.
    public var batch: [Target] = []

    /// One waiting request, by its chat.
    public struct Target: Sendable, Hashable {
        public var chatId: String
        public var requestId: String
        public init(chatId: String, requestId: String) { self.chatId = chatId; self.requestId = requestId }
    }

    /// Stopping a chat's agent: `pause` ends its turn and leaves it
    /// resumable by the next message, `stop` ends the agent itself,
    /// `resume` asks it to carry on. The host maps these onto its own
    /// stop and resume; there is no other paused state to learn.
    public enum Control: String, Sendable, Equatable {
        case stop, pause, resume
    }

    public init(capability: PluginCapability, chatId: String? = nil, projectKey: String? = nil,
                text: String? = nil, agentId: String? = nil, policy: String? = nil,
                control: Control? = nil, requestId: String? = nil, allow: Bool? = nil,
                answers: [String: String] = [:], automationId: String? = nil,
                reviewOf: String? = nil, parentId: String? = nil, title: String? = nil,
                sendsReview: Bool = false, batch: [Target] = []) {
        self.capability = capability; self.chatId = chatId; self.projectKey = projectKey
        self.text = text; self.agentId = agentId; self.policy = policy; self.control = control
        self.requestId = requestId; self.allow = allow; self.answers = answers
        self.automationId = automationId; self.reviewOf = reviewOf; self.parentId = parentId; self.title = title
        self.sendsReview = sendsReview
        self.batch = batch
    }

    /// The one sentence the ask shows: who is asking, and what it will do.
    public func describe(pluginName: String, chatTitle: String? = nil,
                         projectName: String? = nil, automationName: String? = nil) -> String {
        let chat = chatTitle.map { "“\($0)”" } ?? "one of your chats"
        switch capability {
        case .chatsCreate:
            if parentId != nil {
                return "\(pluginName) wants \(agentId.map(ProviderRegistry.name) ?? "an agent") to work on “\(title ?? "a sub-task")” in \(projectName ?? "this project")."
            }
            if reviewOf != nil {
                let agent = agentId.map(ProviderRegistry.name) ?? "an agent"
                return "\(pluginName) wants \(agent) to review the changes in \(chat), without changing anything."
            }
            if let projectName { return "\(pluginName) wants to start a chat in \(projectName)." }
            return "\(pluginName) wants to start a chat."
        case .chatsMessage:
            if sendsReview { return "\(pluginName) wants to send your Review comments to \(chat)." }
            return "\(pluginName) wants to send a message to \(chat)."
        case .chatsControl:
            switch control {
            case .stop: return "\(pluginName) wants to stop the agent in \(chat)."
            case .pause: return "\(pluginName) wants to pause the agent in \(chat)."
            case .resume: return "\(pluginName) wants to resume the agent in \(chat)."
            case nil: return "\(pluginName) wants to control the agent in \(chat)."
            }
        case .permissionsAnswer:
            if !batch.isEmpty {
                let chats = Set(batch.map(\.chatId)).count
                return "\(pluginName) wants to allow the same command \(batch.count) times, in \(chats == 1 ? "one chat" : "\(chats) chats")."
            }
            if !answers.isEmpty { return "\(pluginName) wants to answer the agent's questions in \(chat)." }
            return "\(pluginName) wants to \(allow == true ? "allow" : "decline") a permission request in \(chat)."
        case .automationsRun:
            if let automationName { return "\(pluginName) wants to run “\(automationName)” now." }
            return "\(pluginName) wants to run one of your automations now."
        default:
            return "\(pluginName) wants to do something in \(chat)."
        }
    }

    /// What the ask shows under the sentence, when there is more to read:
    /// the message or prompt itself, or the answers being given.
    public var detail: String? {
        if let text, !text.isEmpty { return text }
        if !answers.isEmpty {
            return answers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        return nil
    }
}
