import Foundation
import Testing
@testable import AbstractCore

/// Settings → Agents' default model and effort fill what a chat leaves open,
/// for chats the app starts and ones `abstract` runs alike.
@Suite struct AgentDefaultsTests {
    let claude = ClaudeProvider()

    func launch(_ session: Session, defaults: AgentDefaults?) -> [String] {
        let settings = LaunchSettings(providerOverrides: [:], outputStyle: .default, claudeProfile: nil,
                                      attachmentsDirectory: "/tmp/attachments",
                                      agentDefaults: defaults.map { ["claude": $0] } ?? [:])
        return AgentLaunch.spec(for: session, provider: claude, prompt: "hi", resumeId: nil, settings: settings, home: "/tmp").args
    }

    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).map { args[$0 + 1] }
    }

    @Test func defaultsFillWhatTheChatLeavesOpen() {
        let chat = Session(projectId: nil, name: "Chat", providerId: "claude")
        let args = launch(chat, defaults: AgentDefaults(model: "opus", effort: "high"))
        #expect(value(after: "--model", in: args) == "opus")
        #expect(value(after: "--effort", in: args) == "high")
        #expect(value(after: "--model", in: launch(chat, defaults: nil)) == nil)
    }

    @Test func theChatsOwnChoicesWin() {
        let chat = Session(projectId: nil, name: "Chat", providerId: "claude", model: "sonnet", effort: "low")
        let args = launch(chat, defaults: AgentDefaults(model: "opus", effort: "high"))
        #expect(value(after: "--model", in: args) == "sonnet")
        #expect(value(after: "--effort", in: args) == "low")
    }

    @Test func aDefaultEffortOnlyGoesToAModelThatTakesIt() {
        let haiku = Session(projectId: nil, name: "Chat", providerId: "claude", model: "haiku")
        #expect(value(after: "--effort", in: launch(haiku, defaults: AgentDefaults(effort: "high"))) == nil)
        let sonnet = Session(projectId: nil, name: "Chat", providerId: "claude", model: "sonnet")
        #expect(value(after: "--effort", in: launch(sonnet, defaults: AgentDefaults(effort: "high"))) == "high")
    }

    @Test func theCommandLineReadsThemFromTheStore() throws {
        let store = try Store.inMemory()
        try store.setSetting("agentDefaults", ["claude": AgentDefaults(model: "opus", effort: "max")])
        let settings = LaunchSettings(store: store, dataDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(settings.agentDefaults["claude"] == AgentDefaults(model: "opus", effort: "max"))
    }
}
