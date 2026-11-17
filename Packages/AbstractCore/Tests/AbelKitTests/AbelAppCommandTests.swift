@testable import AbelKit
import AbstractCore
import Foundation
import Testing

/// Other apps, as the test plays them: what ABEL opened, ran and typed.
@MainActor
final class FakeAppControl: AppControlling {
    var did: [String] = []
    var apps = [AbelAppInfo(name: "Safari", bundleId: "com.apple.Safari", path: "/Applications/Safari.app"),
                AbelAppInfo(name: "Notes", bundleId: "com.apple.Notes", path: "/System/Applications/Notes.app"),
                AbelAppInfo(name: "Terminal", bundleId: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app")]
    var shortcutList = ["Standup", "Morning routine"]
    var shortcutOutput = "Three meetings today. The first is at ten."
    var elements = [AbelUIElement(role: "AXButton", title: "New Note"), AbelUIElement(role: "AXButton", title: "Send"),
                    AbelUIElement(role: "AXTextField", title: "Password", isSecure: true)]
    var focusedIsSecure = false
    var accessibilityAllowed = true

    func installedApps() -> [AbelAppInfo] { apps }
    func open(app: AbelAppInfo) async throws { did.append("open app \(app.name)") }
    func open(url: URL) async throws { did.append("open \(url.isFileURL ? url.path : url.absoluteString)") }
    func shortcuts() async -> [String] { shortcutList }
    func runShortcut(_ name: String, input: String?) async throws -> String {
        did.append("shortcut \(name)" + (input.map { " with \($0)" } ?? ""))
        return shortcutOutput
    }
    func runAppleScript(_ source: String) async throws -> String { did.append("script \(source)"); return "" }
    func uiRead(app: AbelAppInfo) throws -> [AbelUIElement] { did.append("read \(app.name)"); return elements }
    func uiPress(app: AbelAppInfo, element: String) throws { did.append("press \(element) in \(app.name)") }
    func uiType(app: AbelAppInfo, text: String) throws {
        try AbelSecureField.check(role: focusedIsSecure ? "AXTextField" : "AXTextArea",
                                  subrole: focusedIsSecure ? "AXSecureTextField" : nil)
        did.append("type \(text) in \(app.name)")
    }
}

@MainActor
@Suite struct AbelAppCommandTests {
    let ears = QuietEars()
    let voice = RecordingVoice()
    let apps = FakeAppControl()

    func engine(kinds: Set<AbelAppControl.Kind> = Set(AbelAppControl.Kind.allCases),
                modes: [String: AbelAppControl.Mode] = [:]) async -> AbelEngine {
        var context = AbelLink.Context(shownChatId: nil, isFrontmost: false,
                                       chats: [AbelChatInfo(id: "c1", title: "Palette overlay", pullRequest: 43,
                                                            pullRequestURL: "https://github.com/example/app/pull/43")])
        context.settings = AbelSettings(chatId: "abel-chat", appControl: AbelAppControl(kinds: kinds, apps: modes))
        let engine = AbelEngine(ears: ears, voice: voice, abstract: FakeAbstract(context: context))
        engine.appControl = apps
        engine.lingering = .milliseconds(10)
        await engine.start()
        return engine
    }

    var said: String? { voice.spoken.last?.text }

    func tool(_ engine: AbelEngine, _ name: String, _ arguments: String) async -> AbelLink.HelperReply {
        await engine.receive(AbelLink.HelperRequest(kind: .tool, text: arguments, chatId: "abel-chat", name: name))
    }

    func waitForQuestion(_ engine: AbelEngine) async {
        for _ in 0..<200 where !engine.isWaitingForYes { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: By voice

    @Test func opensAnAppAtOnce() async {
        let engine = await engine()
        await engine.simulate("open Safari", trigger: .wakePhrase)
        #expect(apps.did == ["open app Safari"])
        #expect(said == "Opening Safari.")
    }

    @Test func opensTheChatsPullRequestInTheBrowser() async {
        let engine = await engine()
        await engine.simulate("open the PR for the palette chat", trigger: .wakePhrase)
        #expect(apps.did == ["open https://github.com/example/app/pull/43"])
        #expect(said == "Opening the pull request for Palette overlay.")
    }

    @Test func anAppSetToOffIsNotOpened() async {
        let engine = await engine(modes: ["com.apple.Safari": .off])
        await engine.simulate("open Safari", trigger: .wakePhrase)
        #expect(apps.did.isEmpty)
        #expect(said == "Safari is set to Off for ABEL in Settings › ABEL › Other apps.")
    }

    @Test func runShortcutAsksFirstThenReadsItsOutput() async {
        let engine = await engine()
        await engine.simulate("run shortcut standup", trigger: .wakePhrase)
        #expect(said == "Run the shortcut Standup? Say yes to run it.")
        #expect(apps.did.isEmpty)
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(apps.did == ["shortcut Standup"])
        #expect(said == "Standup says: Three meetings today. The first is at ten.")
        #expect(engine.history.contains { $0.text == "Ran the shortcut “Standup”, asked by you" })
    }

    @Test func anAllowedShortcutRunsAtOnce() async {
        let engine = await engine(modes: ["com.apple.shortcuts": .allowed])
        await engine.simulate("run shortcut standup", trigger: .wakePhrase)
        #expect(apps.did == ["shortcut Standup"])
    }

    @Test func shortcutsOffSaysWhere() async {
        let engine = await engine(kinds: [.open])
        await engine.simulate("run shortcut standup", trigger: .wakePhrase)
        #expect(apps.did.isEmpty)
        #expect(said == "Run your shortcuts is off. Turn it on in Settings › ABEL › Other apps.")
    }

    @Test func nothingWhileTheScreenIsShared() async {
        let engine = await engine(modes: ["com.apple.Safari": .allowed])
        engine.screen(locked: false, shared: true)
        let reply = await tool(engine, "open_app", #"{"app":"Safari"}"#)
        #expect(!reply.ok)
        #expect(apps.did.isEmpty)
    }

    // MARK: Tools

    @Test func theBuildLogGoesToNotesAfterYes() async {
        let engine = await engine()
        let script = #"tell application "Notes" to make new note with properties {body:"Build log"}"#
        async let reply = tool(engine, "run_applescript", #"{"app":"Notes","script":"tell application \"Notes\" to make new note with properties {body:\"Build log\"}"}"#)
        await waitForQuestion(engine)
        #expect(engine.display.detail == script)
        #expect(said == "Run this one-line AppleScript in Notes? It's on the panel. Say yes to run it.")
        #expect(apps.did.isEmpty)
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(await reply.ok)
        #expect(apps.did == ["script \(script)"])
        #expect(engine.display.detail.isEmpty)
    }

    @Test func theChatOpeningAnAppAsksFirst() async {
        let engine = await engine()
        async let reply = tool(engine, "open_app", #"{"app":"Safari"}"#)
        await waitForQuestion(engine)
        #expect(said == "Open Safari? Say yes to open.")
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(await reply.ok)
        #expect(apps.did == ["open app Safari"])
    }

    @Test func twoCallsAreAskedOneAfterTheOther() async {
        let engine = await engine()
        async let first = tool(engine, "open_url", #"{"url":"https://example.com"}"#)
        async let second = tool(engine, "run_shortcut", #"{"name":"standup"}"#)
        await waitForQuestion(engine)
        await engine.simulate("yes", trigger: .wakePhrase)
        for _ in 0..<200 where !(engine.isWaitingForYes && said?.contains("shortcut") == true) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(said == "Run the shortcut Standup? Say yes to run it.")
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(await first.ok)
        #expect(await second.ok)
        #expect(apps.did == ["open https://example.com", "shortcut Standup"])
    }

    @Test func aLongScriptIsRefusedRatherThanCutShort() async {
        let engine = await engine(modes: ["com.apple.Notes": .allowed])
        let long = (0..<20).map { _ in "tell application \\\"Notes\\\" to activate" }.joined(separator: "\\n")
        let reply = await tool(engine, "run_applescript", #"{"app":"Notes","script":""# + long + #""}"#)
        #expect(!reply.ok)
        #expect(reply.message == "That script is too long to show whole before it runs. Ask for a shorter one.")
    }

    @Test func scriptsAreReadBackEvenInAnAllowedApp() async {
        let engine = await engine(modes: ["com.apple.Notes": .allowed])
        async let reply = tool(engine, "run_applescript", #"{"app":"Notes","script":"tell application \"Notes\" to activate"}"#)
        await waitForQuestion(engine)
        #expect(engine.isWaitingForYes)
        await engine.simulate("no", trigger: .wakePhrase)
        #expect(await !reply.ok)
        #expect(apps.did.isEmpty)
    }

    @Test func notesSetToOffIsRefusedWithASentence() async {
        let engine = await engine(modes: ["com.apple.Notes": .off])
        let reply = await tool(engine, "run_applescript", #"{"app":"Notes","script":"tell application \"Notes\" to activate"}"#)
        #expect(!reply.ok)
        #expect(reply.message == "Notes is set to Off for ABEL in Settings › ABEL › Other apps.")
        #expect(apps.did.isEmpty)
    }

    @Test func aScriptThatReachesTheShellIsRefused() async {
        let engine = await engine(modes: ["com.apple.Notes": .allowed])
        let reply = await tool(engine, "run_applescript", #"{"app":"Notes","script":"do shell script \"id\""}"#)
        #expect(!reply.ok)
        #expect(!engine.isWaitingForYes)
        #expect(apps.did.isEmpty)
    }

    @Test func typingIntoAPasswordFieldIsRefused() async {
        apps.focusedIsSecure = true
        let engine = await engine(modes: ["com.apple.Safari": .allowed])
        async let reply = tool(engine, "ui_type", #"{"app":"Safari","text":"hunter2"}"#)
        await waitForQuestion(engine)
        await engine.simulate("yes", trigger: .wakePhrase)
        let refused = await reply
        #expect(!refused.ok)
        #expect(refused.message == "That's a password field. ABEL never types into one.")
        #expect(!apps.did.contains { $0.hasPrefix("type") })
    }

    @Test func typingIsAlwaysReadBack() async {
        let engine = await engine(modes: ["com.apple.Terminal": .allowed])
        async let reply = tool(engine, "ui_type", #"{"app":"Terminal","text":"ls"}"#)
        await waitForQuestion(engine)
        #expect(said == "Type ls in Terminal? Say yes to type it.")
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(await reply.ok)
        #expect(apps.did == ["type ls in Terminal"])
    }

    @Test func pressingSendNeedsYesEvenWhenAllowed() async {
        let engine = await engine(modes: ["com.apple.Notes": .allowed])
        let plain = await tool(engine, "ui_press", #"{"app":"Notes","element":"New Note"}"#)
        #expect(plain.ok)
        #expect(apps.did.last == "press New Note in Notes")
        async let send = tool(engine, "ui_press", #"{"app":"Notes","element":"send"}"#)
        await waitForQuestion(engine)
        #expect(said == "Press Send in Notes? Say yes to press it.")
        await engine.simulate("no", trigger: .wakePhrase)
        #expect(await !send.ok)
        #expect(apps.did.last == "read Notes")
    }

    @Test func runShortcutToolReadsItsOutput() async {
        let engine = await engine(modes: ["com.apple.shortcuts": .allowed])
        let reply = await tool(engine, "run_shortcut", #"{"name":"stand up","input":"today"}"#)
        #expect(reply.ok)
        #expect(reply.message == "Three meetings today. The first is at ten.")
        #expect(apps.did == ["shortcut Standup with today"])
    }

    @Test func openURLOnlyOpensWebLinks() async {
        let engine = await engine()
        let file = await tool(engine, "open_url", #"{"url":"file:///etc/passwd"}"#)
        #expect(!file.ok)
        async let web = tool(engine, "open_url", #"{"url":"https://example.com"}"#)
        await waitForQuestion(engine)
        await engine.simulate("yes", trigger: .wakePhrase)
        #expect(await web.ok)
        #expect(apps.did == ["open https://example.com"])
    }

    @Test func openFileStaysAtHome() async {
        let engine = await engine()
        let outside = await tool(engine, "open_file", #"{"path":"/etc/hosts"}"#)
        #expect(!outside.ok)
        #expect(outside.message == "ABEL opens only files and folders in your home folder.")
        #expect(apps.did.isEmpty)
    }
}
