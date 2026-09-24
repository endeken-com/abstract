import Foundation

/// A Linear issue found to attach to a message.
public struct LinearIssue: Sendable, Hashable, Identifiable {
    public var id: String
    /// "ENG-123".
    public var identifier: String
    public var title: String
    public var url: String
    public var description: String?
    /// The state's name, e.g. "In Progress".
    public var state: String?
    /// Linear's kind of state: "triage", "backlog", "unstarted", "started", "completed", "canceled".
    public var stateType: String?

    public var attachment: PromptAttachment {
        PromptAttachment(kind: .linearIssue, title: title, reference: identifier, url: url, body: description,
                         details: state.map { ["State: \($0)"] } ?? [])
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.string, let identifier = json["identifier"]?.string, let title = json["title"]?.string else { return nil }
        self.id = id
        self.identifier = identifier
        self.title = title
        url = json["url"]?.string ?? ""
        description = json["description"]?.string
        state = json["state"]?["name"]?.string
        stateType = json["state"]?["type"]?.string
    }
}

/// Linear's GraphQL API, with a personal API key.
public enum Linear {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!
    static let fields = "id identifier title url description state { name type }"

    /// Whose key it is: a key that works answers with a name.
    public static func viewer(apiKey: String) async throws -> String {
        let data = try await request("query { viewer { name email } }", [:], apiKey: apiKey)
        return data["viewer"]?["name"]?.string ?? data["viewer"]?["email"]?.string ?? "Linear"
    }

    /// Your open issues, or with a query any that match it; "ENG-123" or an
    /// issue's link finds that one issue.
    public static func search(_ query: String, apiKey: String) async throws -> [LinearIssue] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identifier = identifier(in: q) {
            let data = try? await request("query($id: String!) { issue(id: $id) { \(fields) } }", ["id": identifier], apiKey: apiKey)
            return data?["issue"].flatMap(LinearIssue.init(json:)).map { [$0] } ?? []
        }
        if q.isEmpty {
            let data = try await request("""
                query { viewer { assignedIssues(first: 30, orderBy: updatedAt, \
                filter: { state: { type: { nin: ["completed", "canceled"] } } }) { nodes { \(fields) } } } }
                """, [:], apiKey: apiKey)
            return nodes(data["viewer"]?["assignedIssues"])
        }
        let data = try await request("query($term: String!) { searchIssues(term: $term, first: 30) { nodes { \(fields) } } }",
                                     ["term": q], apiKey: apiKey)
        return nodes(data["searchIssues"])
    }

    /// "ENG-123", or the identifier in a linear.app issue link.
    static func identifier(in query: String) -> String? {
        if query.wholeMatch(of: #/[A-Za-z][A-Za-z0-9]*-\d+/#) != nil { return query.uppercased() }
        if query.contains("linear.app/"), let match = query.firstMatch(of: #/\/issue\/([A-Za-z][A-Za-z0-9]*-\d+)/#) {
            return match.output.1.uppercased()
        }
        return nil
    }

    private static func nodes(_ connection: JSONValue?) -> [LinearIssue] {
        (connection?["nodes"]?.array ?? []).compactMap(LinearIssue.init(json:))
    }

    private static func request(_ query: String, _ variables: [String: String], apiKey: String) async throws -> JSONValue {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Personal API keys go as they are; OAuth tokens as bearer tokens.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(key.hasPrefix("lin_api_") ? key : "Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        if let message = json?["errors"]?.array?.first?["message"]?.string {
            throw AbstractError.message(status == 401 || status == 400 && message.localizedCaseInsensitiveContains("auth")
                                        ? "Linear didn't accept this API key." : message)
        }
        guard status == 200, let payload = json?["data"] else {
            throw AbstractError.message(status == 401 ? "Linear didn't accept this API key." : "Linear answered with HTTP \(status).")
        }
        return payload
    }
}
