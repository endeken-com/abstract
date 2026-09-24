import Foundation

/// A session as `abstract` prints it. Absent values are `null`, never missing.
struct SessionJSON: Encodable {
    let session: Session
    let agent: AgentJSON?

    private enum Keys: String, CodingKey {
        case id, projectId, name, provider, branch, worktreePath, baseRef, status, statusDetail, permissionPolicy
        case model, effort, createdAt, lastEventAt, archivedAt, agent
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(session.id, forKey: .id)
        try c.encode(session.projectId, forKey: .projectId)
        try c.encode(session.name, forKey: .name)
        try c.encode(session.providerId, forKey: .provider)
        try c.encode(session.branch, forKey: .branch)
        try c.encode(session.worktreePath, forKey: .worktreePath)
        try c.encode(session.baseRef, forKey: .baseRef)
        try c.encode(session.status.rawValue, forKey: .status)
        try c.encode(session.statusDetail, forKey: .statusDetail)
        try c.encode(session.permissionPolicy.rawValue, forKey: .permissionPolicy)
        try c.encode(session.model, forKey: .model)
        try c.encode(session.effort, forKey: .effort)
        try c.encode(session.createdAt, forKey: .createdAt)
        try c.encode(session.lastEventAt, forKey: .lastEventAt)
        try c.encode(session.archivedAt, forKey: .archivedAt)
        try c.encode(agent, forKey: .agent)
    }
}

/// A running agent: its id (for `agent send`), and who runs it.
struct AgentJSON: Encodable {
    let id: String
    let sessionId: String
    let provider: String
    /// `cli` (started by `abstract`) or `app`.
    let driver: String
    let startedAt: Date

    init(_ agent: AgentRecord, driver: SessionDriver) {
        id = agent.id; sessionId = agent.sessionId; provider = agent.providerId
        self.driver = driver.rawValue; startedAt = agent.startedAt
    }

    /// The chat's running agent, from whoever drives it; nil when none runs.
    init?(sessionId: String, locks: URL) {
        guard let holder = SessionLock.holder(of: sessionId, in: locks), let agent = holder.agent else { return nil }
        self.init(agent, driver: holder.driver)
    }
}

struct ErrorJSON: Encodable {
    let code: String
    let message: String
}

enum CLIOutput {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Millisecond precision, as the store keeps dates.
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(style))
        }
        return try encoder.encode(value)
    }
}
