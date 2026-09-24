import Foundation

/// A question Claude asks when it needs you to choose the way forward, from
/// its `AskUserQuestion` tool. It arrives as a permission request whose input
/// is `{"questions":[{"question","header","options":[{"label","description"}],
/// "multiSelect"}]}`; allowing it with `answers` added to that input (question
/// text → the chosen labels, comma-separated, or your own words) is how the
/// agent hears back.
public struct AgentQuestion: Sendable, Hashable, Identifiable {
    public struct Option: Sendable, Hashable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) { self.label = label; self.description = description }
    }

    public static let toolName = "AskUserQuestion"

    /// The question text, which also keys its answer.
    public var question: String
    /// A short tag, e.g. "Approach".
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool
    public var id: String { question }

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect
    }

    public static func isQuestion(_ toolName: String) -> Bool { toolName == Self.toolName }

    /// The questions in a tool input; ones without text are left out.
    public static func parse(_ input: JSONValue) -> [AgentQuestion] {
        (input["questions"]?.array ?? []).compactMap { q in
            guard let text = q["question"]?.string, !text.isEmpty else { return nil }
            let options = (q["options"]?.array ?? []).compactMap { o in
                o["label"]?.string.map { Option(label: $0, description: o["description"]?.string.flatMap { $0.isEmpty ? nil : $0 }) }
            }
            return AgentQuestion(question: text, header: q["header"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                 options: options, multiSelect: q["multiSelect"]?.bool == true)
        }
    }

    /// One answer as the tool takes it: the chosen labels, then anything
    /// typed, joined by ", ". nil when nothing was chosen or typed.
    public static func answer(chosen: [String], other: String = "") -> String? {
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = chosen + (typed.isEmpty ? [] : [typed])
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The answers in the tool's result, which reads `Your questions have been
    /// answered: "Q"="A", "Q2"="B". You can now continue…` (claude 2.1.280).
    /// Empty when it doesn't read that way.
    public static func answers(fromResult output: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)""#) else { return [:] }
        let text = output as NSString
        var out: [String: String] = [:]
        for match in regex.matches(in: output, range: NSRange(location: 0, length: text.length)) {
            out[text.substring(with: match.range(at: 1))] = text.substring(with: match.range(at: 2))
        }
        return out
    }

    /// The tool input with `answers` set, sent back as the allowed input.
    public static func answeredInput(_ input: JSONValue, answers: [String: String]) -> JSONValue {
        var object = input.object ?? [:]
        object["answers"] = .object(answers.mapValues { .string($0) })
        return .object(object)
    }
}
