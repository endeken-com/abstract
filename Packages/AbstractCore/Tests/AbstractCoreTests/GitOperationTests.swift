import Foundation
import Testing
import AbstractCore

@Suite struct GitOperationTests {
    @Test func codexCommandResultFindsCreatedPullRequestAndPush() {
        let stream = ChatStream(providerId: "codex")
        let started = #"{"type":"item.started","item":{"id":"pr","type":"command_execution","command":"/bin/zsh -lc \"gh pr create\"","status":"in_progress"}}"#
        let completed = #"{"type":"item.completed","item":{"id":"pr","type":"command_execution","command":"/bin/zsh -lc \"gh pr create\"","aggregated_output":"https://github.com/example/app/pull/42\n","exit_code":0,"status":"completed"}}"#
        _ = stream.feed(OutputLine(stream: .stdout, line: started))
        let events = stream.feed(OutputLine(stream: .stdout, line: completed))
        #expect(events.contains(.gitOperation(.pullRequest(number: 42,
            url: URL(string: "https://github.com/example/app/pull/42"), action: "created"))))

        let push = #"{"type":"item.completed","item":{"id":"push","type":"command_execution","command":"git push origin HEAD","aggregated_output":"Everything up-to-date","exit_code":0,"status":"completed"}}"#
        #expect(stream.feed(OutputLine(stream: .stdout, line: push)).contains(.gitOperation(.push(branch: nil))))
    }

    @Test func openCodeCommandResultFindsCreatedPullRequest() {
        let stream = ChatStream(providerId: "opencode")
        let started = #"{"type":"tool_use","sessionID":"ses_clean","part":{"type":"tool","tool":"bash","callID":"pr","state":{"status":"running","input":{}}}}"#
        let line = #"{"type":"tool_use","sessionID":"ses_clean","part":{"type":"tool","tool":"bash","callID":"pr","state":{"status":"completed","input":{"command":"gh pr create"},"output":"https://github.com/example/app/pull/73"}}}"#
        _ = stream.feed(OutputLine(stream: .stdout, line: started))
        #expect(stream.feed(OutputLine(stream: .stdout, line: line)).contains(
            .gitOperation(.pullRequest(number: 73, url: URL(string: "https://github.com/example/app/pull/73"), action: "created"))))
    }

    @Test func failedOrUnrelatedCommandsDoNotClaimPullRequests() {
        #expect(GitOperation.fallback(command: "gh pr create", output: "https://github.com/example/app/pull/42", succeeded: false).isEmpty)
        #expect(GitOperation.fallback(command: "gh pr view", output: "https://github.com/example/app/pull/42", succeeded: true).isEmpty)
        #expect(GitOperation.fallback(command: "git push origin HEAD", output: "failed", succeeded: false).isEmpty)
    }

    @Test func pinnedPullRequestStaysWithChatAfterBranchRename() throws {
        let old = try #require(PullRequest(contract: .object([
            "number": .number(42), "title": .string("Finish feature"), "head": .string("feature/old"),
        ])))
        let other = try #require(PullRequest(contract: .object([
            "number": .number(43), "title": .string("Another request"), "head": .string("feature/new"),
        ])))
        #expect(PullRequestAssociation.retained(old, pinnedNumber: 42)?.number == 42)
        #expect(PullRequestAssociation.candidates([old, other], branch: "feature/new", pinnedNumber: 42)
            .map(\.number) == [42, 43])
        #expect(PullRequestAssociation.retained(old, pinnedNumber: nil) == nil)
        #expect(PullRequestAssociation.candidates([old, other], branch: "feature/new", pinnedNumber: nil)
            .map(\.number) == [43])
    }
}
