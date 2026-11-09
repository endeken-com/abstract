import Foundation
import Testing
@testable import AbstractCore

/// `response.response.models` of claude 2.1.274's initialize response, as
/// recorded on a subscription account (other response keys trimmed).
private let claudeModels = #"""
[{"value":"default","resolvedModel":"claude-opus-5-5[1m]","displayName":"Default (recommended)","description":"Opus 5.5 with 1M context · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},
 {"value":"opus[1m]","resolvedModel":"claude-opus-5-5[1m]","displayName":"Opus (1M context)","description":"Opus 5.5 with 1M context · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},
 {"value":"claude-fable-5-1[1m]","resolvedModel":"claude-fable-5-1","displayName":"Fable","description":"Fable 5.1 · Most capable for your hardest and longest-running tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},
 {"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet","description":"Sonnet 5 · Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},
 {"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}]
"""#

private func initializeResponse(requestId: String, subtype: String = "success", models: String = claudeModels) -> String {
    #"{"type":"control_response","response":{"subtype":""# + subtype + #"","request_id":""# + requestId
        + #"","response":{"commands":[],"models":"# + models.replacingOccurrences(of: "\n", with: "") + #","pid":1}}}"#
}

/// Sanitized excerpt of codex-cli 0.166.0's account catalogue. The entries
/// are out of priority order to check that discovery uses the CLI's order.
private let codexCache = #"""
{"client_version":"0.166.0","models":[
 {"slug":"gpt-6.1-terra","display_name":"GPT-6.1 Terra","description":"GPT-6.1 Terra Codex model.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"visibility":"list","priority":3,"upgrade":null},
 {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","description":"Latest workhorse model for coding and everyday work.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"visibility":"list","priority":1,"upgrade":null},
 {"slug":"gpt-6-luna","display_name":"GPT-6-Luna","description":"Fast and affordable model for easier tasks.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}],"visibility":"list","priority":6,"upgrade":null},
 {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","description":"Frontier intelligence for the most demanding work.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"visibility":"list","priority":2,"upgrade":null},
 {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","description":"Previous generation workhorse model.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}],"visibility":"list","priority":4,"upgrade":null},
 {"slug":"gpt-reserve","display_name":"GPT-Reserve","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"}],"visibility":"hide","priority":5,"upgrade":null}
]}
"""#

/// Historical retirement metadata stays visible when a user's CLI still lists it.
private let retiringCodexCache = #"{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}],"visibility":"list","priority":1,"upgrade":{"model":"gpt-5.6-sol","retirement_at":"2026-10-14T19:00:00Z"}}]}"#

/// The real executor with another home directory.
private struct HomeExecutor: Executor {
    let homeDirectory: String
    let base = LocalExecutor.shared
    func run(_ command: String, _ args: [String], cwd: String?, stdin: Data?) async throws -> ExecResult { try await base.run(command, args, cwd: cwd, stdin: stdin) }
    func spawn(_ spec: LaunchSpec, onLine: @escaping @Sendable (OutputLine) -> Void,
               onExit: @escaping @Sendable (Int32?) -> Void) throws -> RunningProcess {
        try base.spawn(spec, onLine: onLine, onExit: onExit)
    }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func readFile(_ path: String) throws -> String { try base.readFile(path) }
    func createDirectory(_ path: String) throws { try base.createDirectory(path) }
    func removeItem(_ path: String) throws { try base.removeItem(path) }
    func which(_ binary: String) async -> String? { await base.which(binary) }
}

private func temporaryHome() throws -> String {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    return home
}

@Suite("Claude model discovery")
struct ClaudeModelCatalogTests {
    @Test func theAccountsModelsComeFromTheInitializeResponse() throws {
        let catalog = try #require(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r1"), requestId: "r1"))
        #expect(catalog.models.map(\.id) == ["opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku"])
        #expect(catalog.models.map(\.label) == ["Opus (1M context)", "Fable", "Sonnet", "Haiku"])
        #expect(catalog.option("sonnet")?.detail == "Sonnet 5 · Efficient for routine tasks")
        #expect(catalog.option("sonnet")?.efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(catalog.option("sonnet")?.resolvedId == "claude-sonnet-5")
        #expect(catalog.option("haiku")?.efforts == [], "no effort fields means no effort choice")
    }

    @Test func theDefaultEntryIsNamedAfterTheModelItRuns() throws {
        let catalog = try #require(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r1")))
        let accountDefault = try #require(catalog.accountDefault)
        #expect(accountDefault.label == "Opus 5.5 · 1M context")
        #expect(accountDefault.efforts.count == 5)
        #expect(catalog.option("default") == nil, "the picker's own Default row stands for it")
    }

    @Test func specificVersionsSkipModelsAnEntryAlreadyPins() throws {
        let catalog = try #require(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r1")))
        // claude-fable-5-1 is what the Fable entry (itself a full id) runs.
        #expect(catalog.versions.map(\.id) == ["claude-opus-5-5", "claude-opus-5-5[1m]", "claude-sonnet-5", "claude-haiku-4-5-20251001"])
        #expect(catalog.option("claude-fable-5-2") == nil)
        #expect(catalog.option("claude-mythos-5-2") == nil)
        #expect(catalog.versions.map(\.label) == ["Opus 5.5", "Opus 5.5 · 1M context", "Sonnet 5", "Haiku 4.5"])
        #expect(catalog.option("claude-opus-5-5")?.efforts.count == 5, "inherited from the 1M-context entry")
        #expect(catalog.option("claude-haiku-4-5-20251001")?.efforts == [])
    }

    @Test func versionsPickUpWhateverAnAliasResolvesToToday() throws {
        let models = #"[{"value":"sonnet","resolvedModel":"claude-sonnet-5-1","displayName":"Sonnet","supportsEffort":true,"supportedEffortLevels":["low","high"]}]"#
        let catalog = try #require(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r", models: models)))
        #expect(catalog.versions.last?.id == "claude-sonnet-5-1")
        #expect(catalog.versions.last?.label == "Sonnet 5.1")
        #expect(catalog.versions.last?.efforts == ["low", "high"])
    }

    @Test func fable52AppearsOnlyWhenTheCLIExposesIt() throws {
        let models = #"[{"value":"default","resolvedModel":"claude-fable-5-2","displayName":"Default (recommended)","supportsEffort":true,"supportedEffortLevels":["medium","high"]},{"value":"fable","resolvedModel":"claude-fable-5-2","displayName":"Fable","description":"Available on this account","supportsEffort":true,"supportedEffortLevels":["medium","high"]}]"#
        let catalog = try #require(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r", models: models)))
        #expect(catalog.accountDefault?.label == "Fable 5.2")
        #expect(catalog.models.map(\.id) == ["fable"])
        #expect(catalog.option("fable")?.detail == "Available on this account")
        #expect(catalog.option("claude-fable-5-2")?.efforts == ["medium", "high"])
        #expect(catalog.option("claude-mythos-5-2") == nil)
        #expect(catalog.defaultOption(configured: "claude-fable-5-1")?.id == "claude-fable-5-1", "saved selections stay selectable")
    }

    @Test func verifiedMythosEntryKeepsTheCLIsLabelAndEfforts() throws {
        let models = #"[{"value":"fable","resolvedModel":"claude-fable-5-2","displayName":"Fable 5.2","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-mythos-5-2","resolvedModel":"claude-mythos-5-2","displayName":"Mythos 5.2 (verified)","supportsEffort":true,"supportedEffortLevels":["high","xhigh"]}]"#
        let catalog = try #require(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r", models: models)))
        #expect(catalog.models.map(\.id) == ["fable", "claude-mythos-5-2"])
        #expect(catalog.option("claude-mythos-5-2")?.label == "Mythos 5.2 (verified)")
        #expect(catalog.option("claude-mythos-5-2")?.efforts == ["high", "xhigh"])
        #expect(catalog.versions.map(\.id).contains("claude-fable-5-2"))
        #expect(!catalog.versions.map(\.id).contains("claude-mythos-5-2"), "the direct CLI entry is already in Models")
    }

    @Test func anythingButTheMatchingSuccessfulResponseIsIgnored() {
        #expect(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "other"), requestId: "r1") == nil)
        #expect(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r1", models: "[]"), requestId: "r1") == nil)
        #expect(ClaudeProvider.modelCatalog(
            initializeResponse: #"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":"nope"}}"#) == nil)
        #expect(ClaudeProvider.modelCatalog(initializeResponse: #"{"type":"system","subtype":"hook_started"}"#) == nil)
        #expect(ClaudeProvider.modelCatalog(initializeResponse: "not json") == nil)
    }

    @Test func modelIdsReadAsNames() {
        #expect(ClaudeProvider.displayName("claude-opus-5-5[1m]") == "Opus 5.5 · 1M context")
        #expect(ClaudeProvider.displayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ClaudeProvider.displayName("claude-sonnet-5") == "Sonnet 5")
        #expect(ClaudeProvider.displayName("claude-fable-5-1") == "Fable 5.1")
        #expect(ClaudeProvider.displayName("claude-fable-5-2") == "Fable 5.2")
        #expect(ClaudeProvider.displayName("claude-mythos-5-2") == "Mythos 5.2")
        #expect(ClaudeProvider.displayName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ClaudeProvider.displayName("opus[1m]") == "Opus · 1M context")
        #expect(ClaudeProvider.displayName("sonnet") == "Sonnet")
        #expect(ClaudeProvider.displayName("my-custom-model") == "my-custom-model")
    }

    @Test func theFallbackOffersAliasesAndPinnedVersions() {
        let fallback = Agents.claude.fallbackModels
        #expect(fallback.models.map(\.id) == ["fable", "opus", "sonnet", "haiku"])
        #expect(ClaudeProvider.pinnedVersions.prefix(2) == ["claude-fable-5-2", "claude-mythos-5-2"])
        #expect(fallback.versions.map(\.id) == Array(ClaudeProvider.pinnedVersions.dropFirst(2)))
        #expect(fallback.option("claude-fable-5-2") == nil)
        #expect(fallback.option("claude-mythos-5-2") == nil)
        #expect(fallback.option("haiku")?.efforts == [])
        #expect(fallback.option("claude-opus-5-5")?.efforts == ClaudeProvider.effortLevels)
    }

    @Test func theHandshakeRunsAgainstTheCLIAndStopsIt() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let script = home + "/claude"
        // Reads the request, echoes the id back after some unrelated frames,
        // then would linger for a minute if it weren't stopped.
        let body = """
            #!/bin/sh
            read -r line
            id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\\1/')
            echo '{"type":"system","subtype":"hook_started"}'
            echo 'plain noise'
            printf '%s\\n' '\(initializeResponse(requestId: "ID"))' | sed "s/\\"request_id\\":\\"ID\\"/\\"request_id\\":\\"$id\\"/"
            sleep 60
            """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        // A slow login shell (its first lookup) isn't what's measured.
        _ = await LocalExecutor.shared.searchPath
        let started = Date()
        let catalog = await Agents.claude.discoverModels(executor: HomeExecutor(homeDirectory: home), binary: script, timeout: .seconds(10))
        #expect(catalog?.models.map(\.id) == ["opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku"])
        #expect(Date().timeIntervalSince(started) < 8, "answered from the response line, not the timeout")
    }

    @Test func aCLIThatNeverAnswersTimesOut() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let script = home + "/claude"
        try "#!/bin/sh\nsleep 60\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let catalog = await Agents.claude.discoverModels(executor: HomeExecutor(homeDirectory: home), binary: script, timeout: .milliseconds(500))
        #expect(catalog == nil)
    }

    @Test func aCLIThatExitsOrIsMissingYieldsNothing() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let exec = HomeExecutor(homeDirectory: home)
        #expect(await Agents.claude.discoverModels(executor: exec, binary: "/usr/bin/false", timeout: .seconds(10)) == nil)
        #expect(await Agents.claude.discoverModels(executor: exec, binary: home + "/missing", timeout: .seconds(10)) == nil)
    }
}

@Suite("Codex model discovery")
struct CodexModelCatalogTests {
    let beforeRetirement = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
    let utc = TimeZone(identifier: "UTC")!

    @Test func listedModelsComeInPriorityOrder() throws {
        let catalog = try #require(CodexProvider.modelCatalog(modelsCache: codexCache, now: beforeRetirement, timeZone: utc))
        #expect(catalog.models.map(\.id) == ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna"], "hidden models are left out")
        let astra = try #require(catalog.option("gpt-6-astra"))
        #expect(astra.label == "GPT-6-Astra")
        #expect(astra.detail == "Frontier intelligence for the most demanding work.")
        #expect(astra.efforts == ["low", "medium", "high", "xhigh", "max", "ultra"])
        #expect(astra.defaultEffort == "medium")
        #expect(astra.note == nil)
        #expect(catalog.versions.isEmpty && catalog.accountDefault == nil)
    }

    @Test func newlyReleasedModelsUseTheirCliLabelsAndEfforts() throws {
        let catalog = try #require(CodexProvider.modelCatalog(modelsCache: codexCache))
        for (id, label, defaultEffort, efforts) in [
            ("gpt-6.1-sol", "GPT-6.1-Sol", "low", ["low", "medium", "high", "xhigh", "max", "ultra"]),
            ("gpt-6.1-terra", "GPT-6.1 Terra", "low", ["low", "medium", "high", "xhigh", "max", "ultra"]),
            ("gpt-6-luna", "GPT-6-Luna", "medium", ["low", "medium", "high", "xhigh", "max"]),
        ] {
            let option = try #require(catalog.option(id))
            #expect(option.label == label)
            #expect(option.defaultEffort == defaultEffort)
            #expect(option.efforts == efforts)
            #expect(catalog.defaultOption(configured: id)?.id == id, "saved selections keep their exact CLI id")
        }
        #expect(catalog.option("gpt-reserve") == nil)
        #expect(catalog.option("gpt-image-2.6-sunburst") == nil, "image API models are not in the CLI catalogue")
    }

    @Test func aModelBeingRetiredSaysWhen() throws {
        let before = try #require(CodexProvider.modelCatalog(modelsCache: retiringCodexCache, now: beforeRetirement, timeZone: utc))
        #expect(before.option("gpt-5.5")?.note == "Retires Oct 14")
        let after = try #require(CodexProvider.modelCatalog(modelsCache: retiringCodexCache, now: beforeRetirement.addingTimeInterval(86_400 * 60), timeZone: utc))
        #expect(after.option("gpt-5.5")?.note == "Retired Oct 14")
    }

    @Test func aMissingOrBrokenCacheYieldsNothing() async throws {
        #expect(CodexProvider.modelCatalog(modelsCache: "{}") == nil)
        #expect(CodexProvider.modelCatalog(modelsCache: #"{"models":[]}"#) == nil)
        #expect(CodexProvider.modelCatalog(modelsCache: "garbage") == nil)
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(await Agents.codex.discoverModels(executor: HomeExecutor(homeDirectory: home), binary: nil) == nil)
    }

    @Test func discoveryReadsTheCacheInTheHomeDirectory() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try codexCache.write(toFile: home + "/.codex/models_cache.json", atomically: true, encoding: .utf8)
        let catalog = await Agents.codex.discoverModels(executor: HomeExecutor(homeDirectory: home), binary: nil)
        #expect(catalog?.models.first?.id == "gpt-6.1-sol")
    }
}

@Suite("Model catalogue")
struct ModelCatalogTests {
    @Test func theDefaultIsTheConfiguredModelElseTheAccountDefault() throws {
        let catalog = try #require(ClaudeProvider.modelCatalog(initializeResponse: initializeResponse(requestId: "r")))
        let configured = try #require(catalog.defaultOption(configured: "opus[1m]"))
        #expect(configured.id == "opus[1m]")
        #expect(catalog.resolvedLabel(configured) == "Opus 5.5 · 1M context")
        #expect(catalog.defaultOption(configured: nil)?.label == "Opus 5.5 · 1M context")
        #expect(catalog.defaultOption(configured: "somebody-elses-model")?.label == "somebody-elses-model")
        #expect(catalog.resolvedLabel(try #require(catalog.option("haiku"))) == "Haiku 4.5")
        #expect(ModelCatalog.empty.defaultOption(configured: nil) == nil)
    }

    @Test func survivesTheSettingsCache() throws {
        let store = try Store.inMemory()
        let catalog = try #require(CodexProvider.modelCatalog(modelsCache: codexCache))
        try store.setSetting("modelCatalogs", ["codex": catalog])
        #expect(store.setting("modelCatalogs", as: [String: ModelCatalog].self)?["codex"] == catalog)
    }

    @Test func effortLevelsReadAsWords() {
        #expect(ModelOption.effortTitle("xhigh") == "Extra high")
        #expect(ModelOption.effortTitle("high") == "High")
        #expect(ModelOption.effortTitle("max") == "Max")
        #expect(ModelOption.effortTitle("ultra") == "Ultra")
    }
}

@Suite("Effort selection")
struct EffortSelectionTests {
    @Test func newClaudeModelsUseExactCLIArguments() throws {
        for model in ["claude-fable-5-2", "claude-mythos-5-2"] {
            let context = LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, model: model, effort: "xhigh")
            for spec in [Agents.claude.buildLaunch(context), Agents.claude.buildResume(context, resumeId: "abc")] {
                let modelIndex = try #require(spec.args.firstIndex(of: "--model"))
                let effortIndex = try #require(spec.args.firstIndex(of: "--effort"))
                #expect(spec.args[modelIndex + 1] == model)
                #expect(spec.args[effortIndex + 1] == "xhigh")
            }
        }
    }

    @Test func claudePassesTheChosenEffort() throws {
        let spec = Agents.claude.buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, model: "sonnet", effort: "high"))
        let i = try #require(spec.args.firstIndex(of: "--effort"))
        #expect(spec.args[i + 1] == "high")
        let resume = Agents.claude.buildResume(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, effort: "max"), resumeId: "abc")
        #expect(resume.args.contains("--effort") && resume.args.contains("--resume"))
    }

    @Test func codexPassesTheChosenEffortAsAConfigOverrideBeforeThePrompt() throws {
        let spec = Agents.codex.buildLaunch(LaunchContext(cwd: "/w", prompt: "do it", permissionPolicy: .autoEdits, effort: "xhigh"))
        let i = try #require(spec.args.firstIndex(of: "-c"))
        #expect(spec.args[i + 1] == #"model_reasoning_effort="xhigh""#)
        #expect(spec.args.last == "do it")
        let resume = Agents.codex.buildResume(LaunchContext(cwd: "/w", prompt: "more", permissionPolicy: .autoEdits, effort: "low"), resumeId: "t")
        #expect(resume.args.contains(#"model_reasoning_effort="low""#))
    }

    @Test func newlyReleasedCodexModelsLaunchAndResumeWithSupportedEfforts() throws {
        for (model, effort) in [("gpt-6.1-sol", "ultra"), ("gpt-6.1-terra", "max"), ("gpt-6-luna", "max")] {
            let context = LaunchContext(cwd: "/w", prompt: "review", permissionPolicy: .autoEdits,
                                        model: model, effort: effort)
            let launch = Agents.codex.buildLaunch(context)
            #expect(launch.args.contains(model))
            #expect(launch.args.contains(#"model_reasoning_effort="\#(effort)""#))
            #expect(launch.args.last == "review")
            let resume = Agents.codex.buildResume(context, resumeId: "thread")
            #expect(resume.args.contains(model))
            #expect(resume.args.contains(#"model_reasoning_effort="\#(effort)""#))
            #expect(resume.args.last == "review")
        }
    }

    @Test func noEffortMeansTheAgentsOwnDefault() {
        let claude = Agents.claude.buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, effort: " "))
        #expect(!claude.args.contains("--effort"))
        let codex = Agents.codex.buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask))
        #expect(!codex.args.contains("-c"))
    }

    @Test func codexsConfiguredEffortIsReadFromItsConfig() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try "model = \"gpt-6-astra\"\nmodel_reasoning_effort = \"xhigh\"\n\n[profiles.fast]\nmodel_reasoning_effort = \"low\"\n"
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        #expect(Agents.codex.configuredDefaultEffort(home: home) == "xhigh")
        #expect(Agents.codex.configuredDefaultModel(home: home) == "gpt-6-astra")
        #expect(Agents.claude.configuredDefaultEffort(home: home) == nil)
    }

    @Test func sessionsAndAutomationsRememberTheirEffort() throws {
        let store = try Store.inMemory()
        let project = Project(name: "p", rootPath: "/tmp/p")
        try store.save(project)
        try store.save(Session(id: "s", projectId: project.id, name: "chat", providerId: "claude", model: "sonnet", effort: "high"))
        try store.save(Session(id: "d", projectId: project.id, name: "default", providerId: "claude"))
        try store.save(Automation(id: "a", name: "nightly", prompt: "x", providerId: "codex", projectId: project.id,
                                  rrule: "FREQ=DAILY", timezone: "UTC", model: "gpt-6-astra", effort: "xhigh"))
        #expect(try store.session("s")?.effort == "high")
        #expect(try store.session("d")?.effort == nil)
        #expect(try store.automation("a")?.effort == "xhigh")
    }
}

/// Asks the real CLIs. Opt-in: ABSTRACT_E2E=1 swift test --filter RealModelDiscovery
@Suite("Real model discovery", .enabled(if: ProcessInfo.processInfo.environment["ABSTRACT_E2E"] != nil))
struct RealModelDiscoveryTests {
    @Test(.timeLimit(.minutes(1))) func claudeListsTheAccountsModels() async {
        let catalog = await Agents.claude.discoverModels(executor: LocalExecutor.shared, binary: nil)
        #expect(catalog?.models.isEmpty == false)
        #expect(catalog?.accountDefault != nil)
    }

    @Test func codexListsTheAccountsModels() async {
        let catalog = await Agents.codex.discoverModels(executor: LocalExecutor.shared, binary: nil)
        #expect(catalog?.models.isEmpty == false)
    }
}
