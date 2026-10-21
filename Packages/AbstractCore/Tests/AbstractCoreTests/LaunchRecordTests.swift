import Foundation
import Testing
@testable import AbstractCore

struct LaunchRecordTests {
    @Test func threeAgentsKeepTheirActualLaunchChoices() {
        let context = LaunchContext(cwd: "/tmp/project", prompt: "Fix it", permissionPolicy: .autoEdits,
                                    model: "chosen-model", effort: "high")
        let providers: [any ProviderDefinition] = [ClaudeProvider(), CodexProvider(), OpenCodeProvider()]
        for provider in providers {
            let spec = provider.buildLaunch(context)
            let record = LaunchRecord(spec: spec, prompt: context.prompt, model: context.model, effort: context.effort)
            #expect(record.binary == spec.command)
            #expect(record.args == spec.args)
            #expect(record.cwd == context.cwd)
            #expect(record.model == "chosen-model")
            #expect(record.effort == "high")
        }
    }

    @Test func redactsEnvironmentValuesWhereverTheyAppear() {
        let spec = LaunchSpec(command: "codex", args: ["exec", "--config", "token=ordinary-secret", "prompt ordinary-secret",
                                                      "--password", "plain-value", "--api-key=another-value"],
                              cwd: "/tmp/project", env: ["MY_TOKEN": "ordinary-secret", "MODE": "safe"],
                              keepStdinOpen: false)
        let record = LaunchRecord(spec: spec, prompt: "prompt ordinary-secret", model: "test-model", effort: "high")
        #expect(record.env["MY_TOKEN"] == "••••")
        #expect(record.env["MODE"] == "safe")
        #expect(record.args[2] == "token=••••")
        #expect(record.prompt == "prompt ••••")
        #expect(record.args[5] == "••••")
        #expect(record.args[6] == "--api-key=••••")
        #expect(!record.line.line.contains("ordinary-secret"))
        #expect(!record.shellCommand.contains("ordinary-secret"))
        #expect(!record.shellCommand.contains("MY_TOKEN"))
        #expect(!record.shellCommand.contains("--password"))
        #expect(!record.shellCommand.contains("--api-key"))
    }

    @Test func shellCommandQuotesMetacharactersAndStdin() {
        let spec = LaunchSpec(command: "/opt/agent tool", args: ["run", "it's $HOME; echo bad"], cwd: "/tmp/a b",
                              env: ["MODE": "a'b"], stdinInitial: "hello\nworld", keepStdinOpen: false)
        let record = LaunchRecord(spec: spec, prompt: "hello\nworld", model: nil, effort: nil)
        #expect(record.shellCommand == "cd '/tmp/a b' && printf %s 'hello\nworld' | env MODE='a'\\''b' '/opt/agent tool' 'run' 'it'\\''s $HOME; echo bad'")
    }

    @Test func copiedCommandRunsWithTheRecordedFolderAndArguments() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("launch quote \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spec = LaunchSpec(command: "/bin/sh", args: ["-c", "printf '%s\\n%s\\n' \"$MODE\" \"$PWD\""],
                              cwd: folder.path, env: ["MODE": "it's; safe"], keepStdinOpen: false)
        let record = LaunchRecord(spec: spec, prompt: nil, model: nil, effort: nil)
        let result = try await LocalExecutor.shared.run("/bin/zsh", ["-c", record.shellCommand], cwd: folder.path)
        #expect(result.ok)
        #expect(result.stdout == "it's; safe\n\(folder.path)\n")
    }

    @Test func markerIsHiddenAndOldLogsStillHaveTurns() {
        let spec = LaunchSpec(command: "/bin/echo", args: ["hello"], cwd: "/tmp/project", keepStdinOpen: false)
        let record = LaunchRecord(spec: spec, prompt: "hello", model: "model", effort: nil)
        let stream = ChatStream(providerId: "codex")
        var timeline = Timeline()
        for line in [OutputLine(stream: .user, line: "hello"), record.line] {
            timeline.append(contentsOf: stream.feed(line))
        }
        timeline.append(.text(role: .assistant, text: "done", blockId: nil, partial: false))
        timeline.append(.status(.idle, detail: nil))
        let turn = timeline.blocks.compactMap { if case let .turn(_, info) = $0 { info } else { nil } }.last
        #expect(turn?.launch == record)
        #expect(!timeline.blocks.contains { if case .raw = $0 { true } else { false } })

        var old = Timeline()
        old.append(.text(role: .user, text: "hello", blockId: nil, partial: false))
        old.append(.text(role: .assistant, text: "done", blockId: nil, partial: false))
        old.append(.status(.idle, detail: nil))
        let oldTurn = old.blocks.compactMap { if case let .turn(_, info) = $0 { info } else { nil } }.last
        #expect(oldTurn != nil)
        #expect(oldTurn?.launch == nil)
    }

    @Test func eachTurnKeepsItsOwnLaunchLine() {
        let spec = LaunchSpec(command: "agent", args: ["run"], cwd: "/tmp/project", keepStdinOpen: true)
        let first = LaunchRecord(spec: spec, prompt: "first", model: "one", effort: nil)
        let second = LaunchRecord(spec: spec, prompt: "second", model: "two", effort: nil)
        let stream = ChatStream(providerId: "claude")
        var timeline = Timeline()
        for (message, record) in [("first", first), ("second", second)] {
            timeline.append(contentsOf: stream.feed(OutputLine(stream: .user, line: message)))
            timeline.append(contentsOf: stream.feed(record.line))
            timeline.append(.text(role: .assistant, text: "done", blockId: nil, partial: false))
            timeline.append(.status(.idle, detail: nil))
        }
        let launches = timeline.blocks.compactMap { if case let .turn(_, info) = $0 { info.launch } else { nil } }
        #expect(launches == [first, second])
    }

    @Test func engineRecordsLaunchBeforeOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("launch-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = SessionEngine(executor: LocalExecutor.shared, logDirectory: folder)
        let spec = LaunchSpec(command: "/bin/echo", args: ["done"], cwd: folder.path, keepStdinOpen: false)
        let record = LaunchRecord(spec: spec, prompt: "go", model: nil, effort: nil)
        engine.recordInput(sessionId: "test", text: "go")
        try engine.launch(sessionId: "test", spec: spec, launchRecord: record)
        for await event in engine.events { if case .exit = event { break } }
        let lines = engine.replay(sessionId: "test").map(\.line)
        #expect(lines.map(\.stream) == [.user, .launch, .stdout])
        #expect(LaunchRecord(lines[1]) == record)
    }
}
