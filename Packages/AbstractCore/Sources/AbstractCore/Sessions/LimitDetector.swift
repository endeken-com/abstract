import Foundation

/// Why an agent stopped when it ran out of room to work.
public enum LimitKind: String, Sendable, Hashable {
    /// The account's plan or credits ran out for now.
    case usage
    /// Too many requests: it may pass, but another agent can carry on now.
    case rateLimit
    /// The conversation no longer fits the model.
    case context
}

/// Recognises the CLIs' limit errors, so the chat can offer another agent.
public enum LimitDetector {
    public static func classify(_ message: String) -> LimitKind? {
        let m = message.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { m.contains($0) } }
        if any(["prompt is too long", "context window", "context length", "context limit", "maximum context",
                "too many tokens"]) { return .context }
        if any(["usage limit", "hit your limit", "limit reached", "quota", "credit balance", "out of credits"]) { return .usage }
        if any(["rate limit", "rate_limit", "429", "too many requests"]) { return .rateLimit }
        return nil
    }
}
