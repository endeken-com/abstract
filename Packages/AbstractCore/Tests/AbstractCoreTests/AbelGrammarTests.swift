import Foundation
import Testing
@testable import AbstractCore

/// ABEL's instant commands (ABS-204) over 100 transcripts the on-device
/// recognizer really produced, mistakes and all, plus near-miss names.
@Suite struct AbelGrammarTests {
    static let chats = ["Sidebar fix", "Palette overlay", "Nightly catalog", "Gemini transport", "Worktree naming",
                        "Plugin catalog", "Mobile push notifications", "Revund review"]
        .map { AbelChatInfo(id: "chat-" + AbelText.normalized($0).replacingOccurrences(of: " ", with: "-"), title: $0) }
    static let projects = ["Abstract", "Backtick", "payments-api"].map { AbelProjectInfo(id: "project-\($0)", name: $0) }

    struct Line: Sendable, CustomTestStringConvertible {
        var heard: String
        var expected: String
        var testDescription: String { "“\(heard)” → \(expected)" }
    }

    static let lines: [Line] = {
        let url = Bundle.module.url(forResource: "Fixtures/abel-transcripts", withExtension: "tsv")!
        return try! String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return Line(heard: parts[0], expected: parts[1])
            }
    }()

    static func chatId(_ title: String) -> String? {
        title == "-" ? nil : chats.first { $0.title == title }!.id
    }

    /// The fixture's expectation as an intent.
    static func expected(_ text: String) -> AbelIntent? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let two = arg.split(separator: "|", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "whatNeedsMe": return .whatNeedsMe
        case "next": return .next
        case "continue": return .continueReading
        case "pauseEverything": return .pauseEverything
        case "sendIt": return .sendIt
        case "yes": return .yes
        case "no": return .no
        case "chat": return nil
        case "open": return .open(chatId: chatId(arg)!)
        case "readLast": return .readLast(chatId: chatId(arg))
        case "approve": return .approve(chatId: chatId(arg))
        case "deny": return .deny(chatId: chatId(arg))
        case "stop": return .stop(chatId: chatId(arg))
        case "status": return .status(chatId: chatId(arg)!)
        case "tell": return .tell(chatId: chatId(two[0])!, text: two[1])
        case "start": return .startChat(projectId: two[0] == "-" ? nil : "project-\(two[0])", prompt: two[1])
        case "forbidden": return .forbidden(AbelForbidden(rawValue: two[0])!, chatId: two.count > 1 ? chatId(two[1]) : nil)
        default: return nil
        }
    }

    @Test func thereAreAHundredTranscripts() {
        #expect(Self.lines.count >= 100)
    }

    @Test(arguments: lines)
    func understands(_ line: Line) {
        let intent = AbelResolver.resolve(line.heard, chats: Self.chats, projects: Self.projects)
        let kind = line.expected.split(separator: ":").first.map(String.init) ?? ""
        switch kind {
        case "chat":
            #expect(intent == .askABEL(line.heard))
        case "unknown":
            guard case let .notFound(command, _) = intent else { Issue.record("got \(intent)"); return }
            #expect(command == line.expected.split(separator: ":")[1].description)
        case "ambiguous":
            guard case let .ambiguous(command, ids) = intent else { Issue.record("got \(intent)"); return }
            #expect(command == "open")
            #expect(ids.count >= 2)
        default:
            #expect(intent == Self.expected(line.expected))
        }
    }

    @Test func scoresNearMissNames() {
        #expect(AbelNames.score("palid overlay", "Palette overlay") >= AbelNames.threshold)
        #expect(AbelNames.score("the sidebar fixed chat", "Sidebar fix") >= AbelNames.threshold)
        #expect(AbelNames.score("apps 158", "ABS-158") >= AbelNames.threshold)
        #expect(AbelNames.score("weather", "Palette overlay") < AbelNames.threshold)
        #expect(AbelNames.score("sidebar fix", "Sidebar fix") == 1)
    }

    @Test func commandWordsAreFuzzy() {
        #expect(AbelGrammar.parse("Cause everything") == .pauseEverything)
        #expect(AbelGrammar.parse("Approved.") == .approve(chat: nil))
        #expect(AbelGrammar.parse("Please read the last reply") == .readLast(chat: nil))
        #expect(AbelGrammar.parse("stop it now") == .stop(chat: nil))
        #expect(AbelGrammar.parse("stock") == nil)
        // Answers to a request are never guessed at.
        #expect(AbelGrammar.parse("a prove") == nil)
        #expect(AbelGrammar.parse("improve") == nil)
        #expect(AbelGrammar.parse("deni") == nil)
    }

    @Test func bareCommandsCanBeSaidWhileDictating() {
        #expect(AbelGrammar.isBareCommand("send it"))
        #expect(AbelGrammar.isBareCommand("what needs me"))
        #expect(AbelGrammar.isBareCommand("approve"))
        #expect(!AbelGrammar.isBareCommand("open sidebar fix"))
        #expect(!AbelGrammar.isBareCommand("add a test for the grouping"))
        #expect(!AbelGrammar.isBareCommand("stop using the old API"))
    }

    @Test func similarityIsEditDistance() {
        #expect(AbelText.similarity("pause", "cause") == 0.8)
        #expect(AbelText.similarity("", "a") == 0)
        #expect(AbelText.similarity("same", "same") == 1)
    }
}
