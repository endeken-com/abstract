import Foundation
import Testing
@testable import AbstractCore

/// Where a chat's name comes from, and when a better one replaces it.
@Suite struct ChatNameSourceTests {
    // MARK: Ranking

    @Test func everyPairOfSourcesFollowsTheRanking() {
        let replaces: [ChatNameSource: Set<ChatNameSource>] = [
            .fallback: [],
            .request: [.fallback],
            .work: [.fallback, .request],
            .pullRequest: [.fallback, .request, .work, .pullRequest],
            .manual: Set(ChatNameSource.allCases),
        ]
        for current in ChatNameSource.allCases {
            for new in ChatNameSource.allCases {
                #expect(current.mayBeReplaced(by: new) == replaces[new]!.contains(current), "\(new) replacing \(current)")
            }
        }
    }

    @Test func theTurnEndReportOnlyNamesARunStillOnItsPlaceholder() {
        let automation = "Roadmap: build the next ticket"
        let placeholder = AutomationRunNaming.provisional(automation, at: Date(timeIntervalSince1970: 0))
        #expect(AutomationRunNaming.namesFromReport(placeholder, source: .fallback, automationName: automation))
        for source in [ChatNameSource.work, .pullRequest, .manual, .request] {
            #expect(!AutomationRunNaming.namesFromReport(placeholder, source: source, automationName: automation))
        }
        #expect(!AutomationRunNaming.namesFromReport("ABS-64 · Group the sidebar", source: .work, automationName: automation))
        #expect(!AutomationRunNaming.namesFromReport("ABS-64 · Group the sidebar", source: .fallback, automationName: automation))
    }

    @Test func theFirstReplyNamesAChatWithItsStartingNameOrAWeakPrompt() {
        #expect(ChatNaming.namesFromFirstReply(source: .fallback, weakPrompt: false, requestPending: false))
        #expect(ChatNaming.namesFromFirstReply(source: .fallback, weakPrompt: true, requestPending: true))
        // The prompt is still being asked about, and could name it well.
        #expect(!ChatNaming.namesFromFirstReply(source: .fallback, weakPrompt: false, requestPending: true))
        #expect(ChatNaming.namesFromFirstReply(source: .request, weakPrompt: true, requestPending: false))
        #expect(!ChatNaming.namesFromFirstReply(source: .request, weakPrompt: false, requestPending: false))
        for source in [ChatNameSource.work, .pullRequest, .manual] {
            #expect(!ChatNaming.namesFromFirstReply(source: source, weakPrompt: true, requestPending: false))
        }
    }

    // MARK: Ticket IDs

    @Test func ticketIDsAreFound() {
        #expect(ChatNaming.ticket(in: "DGDEV-1114") == "DGDEV-1114")
        #expect(ChatNaming.ticket(in: "Taking ABS-64: the sidebar groups chats") == "ABS-64")
        #expect(ChatNaming.ticket(in: "Fix #3981, the crash on launch") == "#3981")
        #expect(ChatNaming.ticket(in: "https://linear.app/team/issue/ABS-12/title") == "ABS-12")
        // Not tickets: versions, encodings, words with numbers, a placeholder.
        for text in ["Read it as UTF-8", "Switch to GPT-5", "Hash with SHA-256", "Fix the step-2 wizard", "Build ABS-<n>",
                     "CVE-2024-1234 isn't a ticket here", "A-1 sauce", "page#3"] {
            #expect(ChatNaming.ticket(in: text) == nil, "\(text)")
        }
    }

    @Test func theTicketIsKeptInFrontOfATitle() {
        #expect(ChatNaming.withTicket("Sign-up fails with 401", from: ["DGDEV-1114"]) == "DGDEV-1114 · Sign-up fails with 401")
        #expect(ChatNaming.withTicket("ABS-64 · Group the sidebar", from: ["ABS-70"]) == "ABS-64 · Group the sidebar")
        #expect(ChatNaming.withTicket("Fix login (#12)", from: ["ABS-70"]) == "Fix login (#12)")
        #expect(ChatNaming.withTicket("Group the sidebar", from: [nil, "no ticket", "Fixes ABS-64"]) == "ABS-64 · Group the sidebar")
        #expect(ChatNaming.withTicket("Group the sidebar", from: []) == "Group the sidebar")
    }

    @Test func aPullRequestNameDropsDraftMarkersAndKeepsTheTicket() {
        #expect(ChatNaming.pullRequestName("Draft: The sidebar groups chats", ticketFrom: ["ABS-64 · Group the sidebar"])
            == "ABS-64 · The sidebar groups chats")
        #expect(ChatNaming.pullRequestName("[WIP] Phone pill", ticketFrom: [nil, "ABS-66\n\nFixes ABS-66"]) == "ABS-66 · Phone pill")
        #expect(ChatNaming.pullRequestName("  Shows diff stats ", ticketFrom: ["Diff stats"]) == "Shows diff stats")
    }

    // MARK: Generic titles

    @Test func genericTitlesAreRecognised() {
        for title in ["Test verification", "Swift tests and iOS export", "Code changes", "Fix issues", "Updates", "DGDEV-1114",
                      "#3981", "ABS-60 · Checks and lint", "Cleanup", "Run tests in CI"] {
            #expect(ChatNaming.isGeneric(title), "\(title)")
        }
        for title in ["Add chat log timing", "ABS-64 · Group the sidebar by status", "Sign-up and team invites fail with 401",
                      "Fix flaky checkout tests", "Show each chat's pull request in the sidebar", "Export chats as Markdown files"] {
            #expect(!ChatNaming.isGeneric(title), "\(title)")
        }
    }

    @Test func theNamingRequestAsksForWhatTheWorkDelivers() {
        let prompt = ChatNaming.prompt(instructions: "", task: "DGDEV-1114")
        #expect(prompt.contains("what the work delivers for the user, in sentence case"))
        #expect(prompt.contains("at most 50 characters"))
        #expect(prompt.contains("keep it in front"))
        #expect(prompt.contains(#"Bad: "Test verification", "Swift tests and iOS export"."#))
        // The project's instructions still apply on top.
        #expect(ChatNaming.prompt(instructions: "Keep titles short.", task: "x").contains("<instructions>\nKeep titles short.\n</instructions>"))
    }

    @Test func aGenericTitleIsAskedAboutOnceMore() async throws {
        let agent = try ScriptedAgent([claudeAnswer(title: "Test verification", branch: "feature/test-verification"),
                                       claudeAnswer(title: "Group the sidebar by status", branch: "feature/status-sidebar")])
        #expect(try await agent.suggest().get() == .init(title: "Group the sidebar by status", branch: "feature/status-sidebar"))
        #expect(agent.calls == 2)
        #expect(agent.prompt(2).contains("Your last answer's title, “Test verification”, names the process, not what the work delivers."))

        let id = try ScriptedAgent([claudeAnswer(title: "DGDEV-1114", branch: "bugfix/dgdev-1114"),
                                    claudeAnswer(title: "DGDEV-1114 · Invites fail with 401", branch: "bugfix/dgdev-1114-invites")])
        #expect(try await id.suggest().get().title == "DGDEV-1114 · Invites fail with 401")
        #expect(id.prompt(2).contains("“DGDEV-1114”, is only a ticket ID"))
    }

    @Test func aSecondGenericTitleNamesNothing() async throws {
        let agent = try ScriptedAgent([claudeAnswer(title: "Test verification", branch: "feature/test-verification"),
                                       claudeAnswer(title: "Swift tests and iOS export", branch: "feature/tests")])
        #expect(await agent.suggest() == .failure(.init("Claude Code only suggested names about how the work was checked, not what it does.")))
        #expect(agent.calls == 2)
    }

    @Test func aGenericTitleThenAWrongPrefixIsAskedAboutBoth() async throws {
        let agent = try ScriptedAgent([claudeAnswer(title: "Code changes", branch: "feature/code-changes"),
                                       claudeAnswer(title: "Retry relay image pushes", branch: "fix/relay-retry"),
                                       claudeAnswer(title: "Retry relay image pushes", branch: "bugfix/relay-retry")])
        #expect(try await agent.suggest().get() == .init(title: "Retry relay image pushes", branch: "bugfix/relay-retry"))
        #expect(agent.calls == 3)
    }

    // MARK: Weak prompts

    @Test func weakPromptsAreRecognised() {
        let weak: [String?] = [nil, "", "DGDEV-1114", "fix the build", "~/Projects/app/Sources/Relay.swift",
                               "https://linear.app/team/issue/ABS-12/title", "npm run test -- --watch src/relay",
                               "$ swift test --filter RelayTests 2>&1 | tail",
                               PromptAttachments.message("", [PromptAttachment(kind: .file, title: "crash.log", path: "/tmp/crash.log")])]
        for prompt in weak { #expect(ChatNaming.isWeakPrompt(prompt), "\(prompt ?? "nil")") }
        let strong = ["Make the relay retry an image push that times out", "git push fails with 403 when the token has expired",
                      "Make the sidebar show each worktree's diff stat",
                      PromptAttachments.message("Why does this crash on launch every time?",
                                                [PromptAttachment(kind: .file, title: "crash.log", path: "/tmp/crash.log")])]
        for prompt in strong { #expect(!ChatNaming.isWeakPrompt(prompt), "\(prompt)") }
    }

    // MARK: The turn-end report

    @Test func theReportsNamingTaskCarriesTheRequestAndFirstReply() {
        let task = AutomationRunNaming.reportTask(request: "Build the next ticket", firstReply: "Taking ABS-64: group the sidebar.",
                                                  report: "All checks pass.")
        #expect(task == "Asked:\nBuild the next ticket\n\nFirst reply:\nTaking ABS-64: group the sidebar.\n\nFinal report:\nAll checks pass.")
        #expect(AutomationRunNaming.reportTask(request: nil, firstReply: " ", report: "Done.") == "Final report:\nDone.")
        // A long request can't crowd out the report.
        let long = AutomationRunNaming.reportTask(request: String(repeating: "rules ", count: 1_000), firstReply: nil, report: "Opened #48.")
        #expect(long.hasSuffix("Final report:\nOpened #48.") && long.count < ChatNaming.taskLimit)
    }

    // MARK: Storing it

    @Test func existingChatsCountAsNamedFromTheirPrompt() throws {
        let store = try Store.inMemory(migratedTo: "v8-pinned", thenRunning: """
            INSERT INTO sessions (id, name, provider_id, created_at) VALUES ('s1', 'Test verification', 'claude', '2026-10-01 00:00:00.000');
            """)
        #expect(try store.session("s1")?.nameSource == .request)
    }

    @Test func everySourceIsSaved() throws {
        let store = try Store.inMemory()
        for source in ChatNameSource.allCases {
            var session = Session(projectId: nil, name: "Chat", providerId: "claude")
            session.nameSource = source
            try store.save(session)
            #expect(try store.session(session.id)?.nameSource == source)
        }
    }

    @Test func aChatFromAnOlderMacDecodesWithoutASource() throws {
        var session = Session(projectId: nil, name: "Chat", providerId: "claude", createdAt: Date(timeIntervalSince1970: 0))
        session.nameSource = .manual
        session.pinnedAt = Date(timeIntervalSince1970: 5)
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Session.self, from: data) == session)
        var older = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        older["nameSource"] = nil
        older["providerSessions"] = nil
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.nameSource == .request && decoded.providerSessions.isEmpty && decoded.name == "Chat")
    }
}

/// Recorded runs from this repository, replayed through the naming rules
/// the app follows: what each chat ends up named.
@Suite struct ChatNamingReplayTests {
    struct Answer: Decodable { var title: String; var branch: String }
    struct PullRequestStep: Decodable { var title: String; var body: String }
    struct Step: Decodable {
        var start: [Answer]?
        var reply: String?
        var turnEnd: String?
        var answers: [Answer]?
        var pullRequest: PullRequestStep?
        var rename: String?
    }
    struct Run: Decodable {
        var `case`: String
        var automation: String?
        var prompt: String
        var steps: [Step]
        var expect: String
        var neverNamed: [String]?
    }

    /// One chat's name as `AppModel` keeps it.
    struct Chat {
        var name: String
        var source: ChatNameSource
        let prompt: String
        var firstReply: String?
        var replyCalls = 0
        var names: [String] = []

        mutating func rename(to title: String?, source new: ChatNameSource) {
            guard let title, source.mayBeReplaced(by: new) else { return }
            name = new == .pullRequest || new == .manual ? title : ChatNaming.withTicket(title, from: [prompt])
            source = new
            names.append(name)
        }
    }

    static func answered(_ answers: [Answer]) throws -> ScriptedAgent {
        try ScriptedAgent(answers.map { claudeAnswer(title: $0.title, branch: $0.branch) })
    }

    @Test func recordedRunsEndNamedForTheirWork() async throws {
        let url = try #require(Bundle.module.url(forResource: "chat-naming-runs", withExtension: "json", subdirectory: "Fixtures"))
        let runs = try JSONDecoder().decode([Run].self, from: Data(contentsOf: url))
        #expect(runs.count == 5)
        for run in runs {
            let start = run.automation.map { AutomationRunNaming.provisional($0, at: Date(timeIntervalSince1970: 0)) }
            var chat = Chat(name: start ?? Workspace.title(fromPrompt: run.prompt), source: .fallback, prompt: run.prompt)
            for step in run.steps {
                if let answers = step.start {
                    let agent = try Self.answered(answers)
                    chat.rename(to: try? await agent.suggest(instructions: "", task: run.prompt).get().title, source: .request)
                }
                if let reply = step.reply,
                   ChatNaming.namesFromFirstReply(source: chat.source, weakPrompt: run.automation == nil && ChatNaming.isWeakPrompt(run.prompt),
                                                  requestPending: false),
                   chat.replyCalls < 3, AutomationRunNaming.canName(fromReply: reply) {
                    chat.replyCalls += 1
                    chat.firstReply = reply
                    let agent = try Self.answered(step.answers ?? [])
                    chat.rename(to: try? await agent.suggest(instructions: "", task: reply, focus: AutomationRunNaming.firstReplyFocus,
                                                             attempts: 1).get().title, source: .work)
                }
                if let report = step.turnEnd, let automation = run.automation,
                   AutomationRunNaming.namesFromReport(chat.name, source: chat.source, automationName: automation) {
                    let agent = try Self.answered(step.answers ?? [])
                    let task = AutomationRunNaming.reportTask(request: run.prompt, firstReply: chat.firstReply, report: report)
                    chat.rename(to: try? await agent.suggest(instructions: "", task: task, focus: AutomationRunNaming.reportFocus).get().title,
                                source: .work)
                }
                if let pr = step.pullRequest {
                    chat.rename(to: ChatNaming.pullRequestName(pr.title, ticketFrom: [chat.name, pr.body, run.prompt]), source: .pullRequest)
                }
                if let typed = step.rename { chat.rename(to: typed, source: .manual) }
            }
            #expect(chat.name == run.expect, "\(run.case)")
            for generic in run.neverNamed ?? [] { #expect(!chat.names.contains { $0.contains(generic) }, "\(run.case)") }
        }
    }
}
