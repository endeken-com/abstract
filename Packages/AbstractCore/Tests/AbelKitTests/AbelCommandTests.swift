@testable import AbelKit
import AbstractCore
import Foundation
import Testing

/// ABEL controlling Abstract (ABS-204), against a fake Abstract: what it
/// says, what it asks Abstract to do, and what it refuses.
@MainActor
@Suite struct AbelCommandTests {
    let ears = QuietEars()
    let voice = RecordingVoice()

    static let sidebar = AbelChatInfo(id: "c1", title: "Sidebar fix", project: "Abstract", state: .needsYou,
                                      waiting: "wants to run `swift test`", pullRequest: 43, checks: "success")
    static let palette = AbelChatInfo(id: "c2", title: "Palette overlay", project: "Abstract", state: .needsYou,
                                      waiting: "has a question")
    static let catalog = AbelChatInfo(id: "c3", title: "Nightly catalog", project: "Abstract", state: .working,
                                      activeAt: Date().addingTimeInterval(-600))

    func abstract(shown: String? = nil, frontmost: Bool = false) -> FakeAbstract {
        let fake = FakeAbstract(context: AbelLink.Context(
            shownChatId: shown, shownChatTitle: shown.flatMap { id in [Self.sidebar, Self.palette, Self.catalog].first { $0.id == id }?.title },
            isFrontmost: frontmost, settings: AbelSettings(chatId: "abel-chat"),
            chats: [Self.sidebar, Self.palette, Self.catalog],
            projects: [AbelProjectInfo(id: "p1", name: "Abstract"), AbelProjectInfo(id: "p2", name: "Backtick")]))
        fake.replies[.pending] = AbelLink.Reply(ok: true, pending: AbelLink.Pending(
            chatId: "c1", chatTitle: "Sidebar fix", requestId: "r1", summary: "run `swift test`"))
        fake.replies[.reply] = AbelLink.Reply(ok: true, text: "All green.\n\n```\nlog\n```\n\nSecond paragraph.")
        fake.replies[.startChat] = AbelLink.Reply(ok: true, chatTitle: "Fix the palette overlay", chatId: "c9")
        return fake
    }

    func engine(_ abstract: FakeAbstract) async -> AbelEngine {
        let engine = AbelEngine(ears: ears, voice: voice, abstract: abstract)
        engine.lingering = .milliseconds(10)
        await engine.start()
        return engine
    }

    var said: [String] { voice.spoken.map(\.text) }

    @Test func whatNeedsMeReadsTheWaitingChats() async {
        let engine = await engine(abstract())
        await engine.simulate("Hey Abel, what needs me?".replacingOccurrences(of: "Hey Abel, ", with: ""), trigger: .wakePhrase)
        #expect(said.last == "Two chats need you. Sidebar fix wants to run swift test. Palette overlay has a question.")
    }

    @Test func approveThenYesAllowsTheFirstWaitingChatsRequest() async {
        let fake = abstract()
        let engine = await engine(fake)
        await engine.simulate("what needs me", trigger: .wakePhrase)
        await engine.simulate("approve", trigger: .wakePhrase)
        #expect(said.last == "Let Sidebar fix run swift test? Say yes to allow.")
        #expect(!fake.acting.contains { $0.kind == .answer })
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .answer, chatId: "c1", requestId: "r1", allow: true))
        #expect(said.last == "Allowed in Sidebar fix.")
        #expect(engine.history.contains { $0.kind == .did && $0.text.contains("Allowed run `swift test`") && $0.text.contains("asked by you") })
    }

    @Test func anythingButYesLeavesTheRequestWaiting() async {
        let fake = abstract()
        let engine = await engine(fake)
        await engine.simulate("approve", trigger: .wakePhrase)
        await engine.simulate("yes please do it now", trigger: .wakePhrase)
        #expect(!fake.acting.contains { $0.kind == .answer })
        #expect(said.last == "Cancelled.")
    }

    @Test func denyIsReadBackToo() async {
        let fake = abstract()
        let engine = await engine(fake)
        await engine.simulate("deny", trigger: .wakePhrase)
        #expect(said.last == "Turn down Sidebar fix's request to run swift test? Say yes to turn it down.")
        await engine.simulate("sim", language: "pt-BR", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .answer, chatId: "c1", requestId: "r1", allow: false))
    }

    @Test func aQuestionIsAnsweredInItsChat() async {
        let fake = abstract()
        fake.replies[.pending] = AbelLink.Reply(ok: true, pending: AbelLink.Pending(
            chatId: "c2", chatTitle: "Palette overlay", requestId: "q1", summary: "answer a question", isQuestion: true))
        let engine = await engine(fake)
        await engine.simulate("approve palette overlay", trigger: .wakePhrase)
        #expect(fake.acting.map(\.kind) == [.pending, .open])
        #expect(said.last == "Palette overlay asked a question. Answer it in the chat; I've opened it.")
    }

    @Test func aLongCommandIsApprovedOnScreen() async {
        let fake = abstract()
        fake.replies[.pending] = AbelLink.Reply(ok: true, pending: AbelLink.Pending(
            chatId: "c1", chatTitle: "Sidebar fix", requestId: "r1", summary: "run a long command", onScreenOnly: true))
        let engine = await engine(fake)
        await engine.simulate("approve", trigger: .wakePhrase)
        #expect(fake.acting.map(\.kind) == [.pending, .open])
        #expect(said.last == "I can't read that request back whole. Approve it in Sidebar fix; I've opened it.")
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(!fake.acting.contains { $0.kind == .answer })
    }

    @Test func nothingWaitingSaysSo() async {
        let fake = abstract()
        fake.replies[.pending] = AbelLink.Reply(ok: true)
        let engine = await engine(fake)
        await engine.simulate("approve", trigger: .wakePhrase)
        #expect(said.last == "Nothing is waiting for an answer.")
    }

    @Test func startAChatIsReadBackAndStartedOnYes() async {
        let fake = abstract()
        let engine = await engine(fake)
        await engine.simulate("Start a chat in Abstract to fix the palette overlay", trigger: .wakePhrase)
        #expect(said.last == "Start a chat in Abstract to fix the palette overlay? Say yes to start.")
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .startChat, text: "fix the palette overlay", projectId: "p1"))
        #expect(said.last == "Started the chat Fix the palette overlay.")
    }

    @Test func tellIsReadBack() async {
        let fake = abstract()
        let engine = await engine(fake)
        await engine.simulate("tell sidebar fix to add a test for the grouping", trigger: .wakePhrase)
        #expect(said.last == "Tell Sidebar fix: add a test for the grouping? Say yes to send.")
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .tell, chatId: "c1", text: "add a test for the grouping"))
    }

    @Test func stopAndPauseActAtOnce() async {
        let fake = abstract(shown: "c3")
        let engine = await engine(fake)
        await engine.simulate("stop", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .stop, chatId: "c3"))
        #expect(said.last == "Stopped Nightly catalog.")
        await engine.simulate("pause everything", trigger: .wakePhrase)
        #expect(fake.acting.last?.kind == .pauseAll)
        #expect(said.last == "Paused every agent.")
    }

    @Test func mergeOpensThePullRequestInstead() async {
        let fake = abstract(shown: "c1")
        let engine = await engine(fake)
        await engine.simulate("merge it", trigger: .wakePhrase)
        #expect(fake.acting == [AbelLink.Request(kind: .showScreen, chatId: "c1", screen: "pullRequest")])
        #expect(said.last == "I don't merge by voice. I've opened the pull request for Sidebar fix so you can do it there.")
        #expect(engine.history.contains { $0.kind == .refused })
    }

    @Test(arguments: ["push the branch", "turn on full autonomy", "delete the sidebar fix chat", "faz o merge"])
    func neverByVoice(_ said: String) async {
        let fake = abstract(shown: "c1")
        let engine = await engine(fake)
        await engine.simulate(said, trigger: .wakePhrase)
        #expect(fake.acting.allSatisfy { $0.kind == .showScreen })
        #expect(!fake.acting.contains { [.answer, .tell, .startChat, .stop, .sendDraft].contains($0.kind) })
        #expect(engine.history.last?.kind == .refused || engine.history.contains { $0.kind == .refused })
    }

    @Test func statusAndOpen() async {
        let fake = abstract()
        let engine = await engine(fake)
        await engine.simulate("status of palid overlay", trigger: .wakePhrase)
        #expect(said.last == "Palette overlay has a question.")
        await engine.simulate("status of sidebar fix", trigger: .wakePhrase)
        #expect(said.last == "Sidebar fix wants to run swift test. Pull request 43, checks passing.")
        await engine.simulate("open nightly catalog", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .open, chatId: "c3"))
        await engine.simulate("next one", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .open, chatId: "c1"))
    }

    @Test func readsTheLastReplyAndContinues() async {
        let fake = abstract(shown: "c3")
        let engine = await engine(fake)
        await engine.simulate("read the last reply", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .reply, chatId: "c3"))
        #expect(said.last == "Nightly catalog says: All green, and a line of code.")
        await engine.simulate("continue", trigger: .wakePhrase)
        #expect(said.last == "Second paragraph.")
        await engine.simulate("continue", trigger: .wakePhrase)
        #expect(said.last == "That's the whole reply.")
    }

    @Test func unknownNamesAndQuestionsForABELsChat() async {
        let fake = abstract()
        let engine = await engine(fake)
        await engine.simulate("open the weather report", trigger: .wakePhrase)
        #expect(said.last == "I couldn't find a chat called weather report.")
        await engine.simulate("Which chats touched the plugin catalog this week?", trigger: .wakePhrase)
        #expect(fake.acting.last == AbelLink.Request(kind: .ask, text: "Which chats touched the plugin catalog this week?"))
        #expect(said.last == "Let me check.")
    }

    @Test func holdingTheKeyOverAChatStillDictates() async {
        let fake = abstract(shown: "c1", frontmost: true)
        let engine = await engine(fake)
        await engine.simulate("stop using the old API")
        #expect(fake.acting.last == AbelLink.Request(kind: .dictate, chatId: "c1", text: "stop using the old API"))
        await engine.simulate("what needs me")
        #expect(said.last?.hasPrefix("Two chats need you.") == true)
        await engine.simulate("Abel, open nightly catalog")
        #expect(fake.acting.last == AbelLink.Request(kind: .open, chatId: "c3"))
    }

    // MARK: Tools

    func waitForQuestion(_ engine: AbelEngine) async {
        for _ in 0..<200 where !engine.isWaitingForYes { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func toolsAreOnlyForABELsChat() async {
        let engine = await engine(abstract())
        let reply = await engine.receive(AbelLink.HelperRequest(kind: .tool, text: "{}", chatId: "someone-else", name: "list_chats"))
        #expect(!reply.ok)
        #expect(reply.message == "Only ABEL's own chat can use ABEL's tools.")
    }

    @Test func readingToolsAnswerAtOnce() async {
        let engine = await engine(abstract())
        let list = await engine.receive(AbelLink.HelperRequest(kind: .tool, text: #"{"state":"needs_you"}"#, chatId: "abel-chat", name: "list_chats"))
        #expect(list.ok)
        #expect(list.message?.contains("Sidebar fix in Abstract, Claude, needs you: wants to run `swift test`, pull request #43") == true)
        #expect(list.message?.contains("Nightly catalog") == false)
        let status = await engine.receive(AbelLink.HelperRequest(kind: .tool, text: #"{"chat":"nightly catalog"}"#, chatId: "abel-chat", name: "chat_status"))
        #expect(status.message?.hasPrefix("Nightly catalog is working") == true)
        #expect(voice.spoken.isEmpty)
    }

    @Test func actingToolsWaitForYes() async {
        let fake = abstract()
        let engine = await engine(fake)
        async let reply = engine.receive(AbelLink.HelperRequest(
            kind: .tool, text: #"{"chat":"sidebar fix","allow":true}"#, chatId: "abel-chat", name: "answer_permission"))
        await waitForQuestion(engine)
        #expect(said.last == "Let Sidebar fix run swift test? Say yes to allow.")
        #expect(!fake.acting.contains { $0.kind == .answer })
        await engine.simulate("yes", trigger: .wakePhrase)
        let answered = await reply
        #expect(answered.ok)
        #expect(fake.acting.last == AbelLink.Request(kind: .answer, chatId: "c1", requestId: "r1", allow: true))
        #expect(engine.history.contains { $0.text.contains("asked by ABEL's chat; you said yes") })
    }

    @Test func actingToolsDeclinedDoNothing() async {
        let fake = abstract()
        let engine = await engine(fake)
        async let reply = engine.receive(AbelLink.HelperRequest(
            kind: .tool, text: #"{"prompt":"fix it","project":"Abstract"}"#, chatId: "abel-chat", name: "start_chat"))
        await waitForQuestion(engine)
        await engine.simulate("no", trigger: .wakePhrase)
        let declined = await reply
        #expect(!declined.ok)
        #expect(declined.message == "The person said no.")
        #expect(!fake.acting.contains { $0.kind == .startChat })
    }

    @Test func actingToolsGiveUpWithoutAnAnswer() async {
        let fake = abstract()
        let engine = await engine(fake)
        engine.confirmationWindow = .milliseconds(1)
        // A silent window: the wait is the window plus twenty seconds, so
        // cut it short by answering nothing and checking the gate held.
        async let reply = engine.receive(AbelLink.HelperRequest(
            kind: .tool, text: #"{"chat":"sidebar fix","text":"hi"}"#, chatId: "abel-chat", name: "send_to_chat"))
        await waitForQuestion(engine)
        try? await Task.sleep(for: .milliseconds(20))
        await engine.simulate("yes", trigger: .wakePhrase)
        let late = await reply
        #expect(!late.ok)
        #expect(!fake.acting.contains { $0.kind == .tell })
    }

    @Test func pausedRefusesTools() async {
        let engine = await engine(abstract())
        engine.screen(locked: false, shared: true)
        let reply = await engine.receive(AbelLink.HelperRequest(kind: .tool, text: "{}", chatId: "abel-chat", name: "list_chats"))
        #expect(!reply.ok)
        #expect(reply.message == AbelMachine.PauseReason.screenShared.sentence)
    }

    @Test func toolDefinitionsAreWhatTheServerLists() async {
        #expect(AbelTools.definitions.compactMap { $0["name"]?.string }
            == ["list_chats", "chat_status", "read_reply", "start_chat", "send_to_chat", "stop_chat", "answer_permission",
                "open_app", "open_url", "open_file", "run_shortcut", "run_applescript", "ui_read", "ui_press", "ui_type"])
        #expect(Set(AbelTools.definitions.compactMap { $0["name"]?.string }).subtracting(AbelTools.appTools).count == 7)
        #expect(AbelTools.acting == ["start_chat", "send_to_chat", "stop_chat", "answer_permission"])
        // No tool merges, pushes, deletes or changes permissions.
        #expect(!AbelTools.definitions.contains { ($0["name"]?.string ?? "").contains("merge") || ($0["name"]?.string ?? "").contains("push") })
    }
}
