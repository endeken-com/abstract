import Foundation
import Testing
import AbstractCore

@Suite struct PlanModeTests {
    private func context(_ policy: PermissionPolicy, prompt: String = "do it") -> LaunchContext {
        LaunchContext(cwd: "/tmp/work", prompt: prompt, permissionPolicy: policy)
    }

    // MARK: - Launch specs

    @Test func claudePlanAndAskUsePlanMode() throws {
        let provider = ClaudeProvider()
        for policy in [PermissionPolicy.plan, .readOnly] {
            let args = provider.buildLaunch(context(policy)).args
            let mode = try #require(args.firstIndex(of: "--permission-mode"))
            #expect(args[mode + 1] == "plan")
            #expect(provider.buildResume(context(policy), resumeId: "s").args.contains("plan"))
            #expect(provider.buildPermissionModeChange(policy, requestId: "r")?.contains(#""mode":"plan""#) == true)
        }
    }

    @Test func codexPlanAndAskAreReadOnlyAndPlanStopsAfterPlanning() {
        let provider = CodexProvider()
        for policy in [PermissionPolicy.plan, .readOnly] {
            let args = provider.buildLaunch(context(policy)).args
            #expect(args.contains("read-only"))
            #expect(!args.contains("workspace-write"))
            #expect(provider.buildResume(context(policy), resumeId: "t").args.contains(#"sandbox_mode="read-only""#))
        }
        let planArgs = provider.buildLaunch(context(.plan)).args
        #expect(planArgs.contains { $0.contains(Plan.instruction) })
        let askArgs = provider.buildLaunch(context(.readOnly)).args
        #expect(!askArgs.contains { $0.contains(Plan.instruction) })
    }

    @Test func openCodePlanAndAskUseItsPlanAgent() {
        let provider = OpenCodeProvider()
        for policy in [PermissionPolicy.plan, .readOnly] {
            let args = provider.buildLaunch(context(policy)).args
            #expect(args.contains("--agent"))
            #expect(args.contains("plan"))
            #expect(!args.contains("--auto"))
            #expect(provider.buildResume(context(policy), resumeId: "s").args.contains("--agent"))
        }
        #expect(!provider.buildLaunch(context(.autoEdits)).args.contains("--agent"))
    }

    @Test func musePlanAndAskCannotWrite() {
        let provider = MuseProvider()
        for policy in [PermissionPolicy.plan, .readOnly] {
            let args = provider.buildLaunch(context(policy)).args
            #expect(args.contains("--disable-write"))
            #expect(args.contains("--disable-shell"))
            #expect(!provider.permissionDetail(policy).isEmpty)
        }
    }

    // MARK: - Plan text

    @Test func readsAPlanFromClaudesExitPlanModeFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "claude-plan", withExtension: "jsonl", subdirectory: "Fixtures"))
        let parser = ClaudeProvider().makeParser()
        let events = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { parser.feed($0, stream: .stdout) }
        let request = try #require(events.compactMap { event -> (String, JSONValue)? in
            if case let .permissionRequest(_, toolName, input) = event { (toolName, input) } else { nil }
        }.first)
        #expect(Plan.isExitPlanMode(request.0))
        #expect(Plan.text(fromExitPlanModeInput: request.1) == "# Plan\n\n1. Read the parser.\n2. Add a test.")
        #expect(Plan.text(fromExitPlanModeInput: .object([:])) == nil)
        #expect(Plan.text(fromExitPlanModeInput: .object(["plan": .string("  \n")])) == nil)
    }

    @Test func onlyAPlanModeReplyBecomesAPlan() {
        #expect(Plan.text(fromFinalReply: "the plan", policy: .plan) == "the plan")
        #expect(Plan.text(fromFinalReply: "an answer", policy: .readOnly) == nil)
        #expect(Plan.text(fromFinalReply: "done", policy: .autoEdits) == nil)
        #expect(Plan.text(fromFinalReply: "  ", policy: .plan) == nil)
    }

    // MARK: - Revisions and decisions (what AppModel applies)

    @Test func revisionsKeepHistoryAndIgnoreRepeats() {
        var plan = PlanState()
        #expect(plan.current == nil && !plan.isVisible)
        let first = plan.add("first")
        let repeatAdd = plan.add("first")
        let empty = plan.add("  ")
        let second = plan.add("second")
        #expect(first && !repeatAdd && !empty && second)
        #expect(plan.current == "second")
        #expect(plan.history == ["first"])
        #expect(plan.isVisible)
    }

    @Test func approveRequestChangesAndDiscard() {
        var plan = PlanState()
        plan.add("v1")
        plan.requestChanges()
        #expect(plan.status == .changesRequested)
        #expect(plan.isVisible)
        // A revised plan waits for a fresh decision, history kept.
        plan.add("v2")
        #expect(plan.status == .waiting)
        #expect(plan.history == ["v1"])
        plan.approve()
        #expect(plan.status == .approved)
        #expect(!plan.isVisible)
        #expect(plan.current == "v2")

        var discarded = PlanState()
        discarded.add("v1")
        discarded.discard()
        #expect(discarded.status == .discarded)
        #expect(!discarded.isVisible)
    }

    @Test func quotingForTheComposerAndTheApproveMessage() {
        #expect(Plan.quoted("# Plan\n\nstep") == "> # Plan\n>\n> step")
        #expect(Plan.approveMessage == "Implement the approved plan")
    }

    @Test func planAndAskAreComposerModesNotAutonomyDefaults() {
        #expect(PermissionPolicy.autonomyCases == [.ask, .autoEdits, .bypass])
        #expect(PermissionPolicy.plan.isReadOnly && PermissionPolicy.readOnly.isReadOnly)
        #expect(!PermissionPolicy.ask.isReadOnly && !PermissionPolicy.bypass.isReadOnly)
        #expect(PermissionPolicy.plan.title == "Plan")
        #expect(PermissionPolicy.readOnly.title == "Ask (read-only)")
    }
}
