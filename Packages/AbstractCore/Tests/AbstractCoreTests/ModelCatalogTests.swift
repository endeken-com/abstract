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

/// Excerpt of codex-cli 0.153.4's ~/.codex/models_cache.json, out of priority
/// order on purpose, with one hidden model and one being retired.
private let codexCache = #"""
{"fetched_at":"2026-09-22T12:00:00Z","etag":"W/\"abc\"","client_version":"0.153.4","models":[
 {"slug":"gpt-5.5","display_name":"GPT-5.5","description":"Proven previous-generation model for coding and general work.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast responses with lighter reasoning"},{"effort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},{"effort":"high","description":"Greater reasoning depth for complex problems"},{"effort":"xhigh","description":"Extra high reasoning depth for complex problems"}],"visibility":"list","priority":12,"upgrade":{"model":"gpt-5.6-sol","migration_markdown":"GPT-5.5 retires on October 14, 2026.","retirement_at":"2026-10-14T19:00:00Z"}},
 {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","description":"Our most capable model for complex, demanding work.","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"medium","description":"x"},{"effort":"high","description":"x"},{"effort":"xhigh","description":"x"},{"effort":"max","description":"x"},{"effort":"ultra","description":"x"}],"visibility":"list","priority":1,"upgrade":null},
 {"slug":"gpt-reserve","display_name":"GPT-Reserve","description":"Fast and affordable agentic coding model.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"x"}],"visibility":"hide","priority":3,"upgrade":null},
 {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","description":"Balanced.","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"x"},{"effort":"medium","description":"x"}],"visibility":"list","priority":2,"upgrade":null}
]}
"""#

/// The real executor with another home directory.
private struct HomeExecutor: Executor {
    let homeDirectory: String
    let base = LocalExecutor.shared
    func run(_ command: String, _ args: [String], cwd: String?) async throws -> ExecResult { try await base.run(command, args, cwd: cwd) }
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
        #expect(ClaudeProvider.displayName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ClaudeProvider.displayName("opus[1m]") == "Opus · 1M context")
        #expect(ClaudeProvider.displayName("sonnet") == "Sonnet")
        #expect(ClaudeProvider.displayName("my-custom-model") == "my-custom-model")
    }

    @Test func theFallbackOffersAliasesAndPinnedVersions() {
        let fallback = ClaudeProvider().fallbackModels
        #expect(fallback.models.map(\.id) == ["fable", "opus", "sonnet", "haiku"])
        #expect(fallback.versions.map(\.id) == ClaudeProvider.pinnedVersions)
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

        let started = Date()
        let catalog = await ClaudeProvider().discoverModels(executor: HomeExecutor(homeDirectory: home), binary: script, timeout: .seconds(10))
        #expect(catalog?.models.map(\.id) == ["opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku"])
        #expect(Date().timeIntervalSince(started) < 8, "answered from the response line, not the timeout")
    }

    @Test func aCLIThatNeverAnswersTimesOut() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let script = home + "/claude"
        try "#!/bin/sh\nsleep 60\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let catalog = await ClaudeProvider().discoverModels(executor: HomeExecutor(homeDirectory: home), binary: script, timeout: .milliseconds(500))
        #expect(catalog == nil)
    }

    @Test func aCLIThatExitsOrIsMissingYieldsNothing() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let exec = HomeExecutor(homeDirectory: home)
        #expect(await ClaudeProvider().discoverModels(executor: exec, binary: "/usr/bin/false", timeout: .seconds(10)) == nil)
        #expect(await ClaudeProvider().discoverModels(executor: exec, binary: home + "/missing", timeout: .seconds(10)) == nil)
    }
}

@Suite("Codex model discovery")
struct CodexModelCatalogTests {
    let beforeRetirement = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
    let utc = TimeZone(identifier: "UTC")!

    @Test func listedModelsComeInPriorityOrder() throws {
        let catalog = try #require(CodexProvider.modelCatalog(modelsCache: codexCache, now: beforeRetirement, timeZone: utc))
        #expect(catalog.models.map(\.id) == ["gpt-6-astra", "gpt-6-sol", "gpt-5.5"], "hidden models are left out")
        let astra = try #require(catalog.option("gpt-6-astra"))
        #expect(astra.label == "GPT-6-Astra")
        #expect(astra.detail == "Our most capable model for complex, demanding work.")
        #expect(astra.efforts == ["low", "medium", "high", "xhigh", "max", "ultra"])
        #expect(astra.defaultEffort == "low")
        #expect(astra.note == nil)
        #expect(catalog.versions.isEmpty && catalog.accountDefault == nil)
    }

    @Test func aModelBeingRetiredSaysWhen() throws {
        let before = try #require(CodexProvider.modelCatalog(modelsCache: codexCache, now: beforeRetirement, timeZone: utc))
        #expect(before.option("gpt-5.5")?.note == "Retires Oct 14")
        let after = try #require(CodexProvider.modelCatalog(modelsCache: codexCache, now: beforeRetirement.addingTimeInterval(86_400 * 60), timeZone: utc))
        #expect(after.option("gpt-5.5")?.note == "Retired Oct 14")
    }

    @Test func aMissingOrBrokenCacheYieldsNothing() async throws {
        #expect(CodexProvider.modelCatalog(modelsCache: "{}") == nil)
        #expect(CodexProvider.modelCatalog(modelsCache: #"{"models":[]}"#) == nil)
        #expect(CodexProvider.modelCatalog(modelsCache: "garbage") == nil)
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(await CodexProvider().discoverModels(executor: HomeExecutor(homeDirectory: home), binary: nil) == nil)
    }

    @Test func discoveryReadsTheCacheInTheHomeDirectory() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try codexCache.write(toFile: home + "/.codex/models_cache.json", atomically: true, encoding: .utf8)
        let catalog = await CodexProvider().discoverModels(executor: HomeExecutor(homeDirectory: home), binary: nil)
        #expect(catalog?.models.first?.id == "gpt-6-astra")
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
    @Test func claudePassesTheChosenEffort() throws {
        let spec = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, model: "sonnet", effort: "high"))
        let i = try #require(spec.args.firstIndex(of: "--effort"))
        #expect(spec.args[i + 1] == "high")
        let resume = ClaudeProvider().buildResume(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, effort: "max"), resumeId: "abc")
        #expect(resume.args.contains("--effort") && resume.args.contains("--resume"))
    }

    @Test func codexPassesTheChosenEffortAsAConfigOverrideBeforeThePrompt() throws {
        let spec = CodexProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "do it", permissionPolicy: .autoEdits, effort: "xhigh"))
        let i = try #require(spec.args.firstIndex(of: "-c"))
        #expect(spec.args[i + 1] == #"model_reasoning_effort="xhigh""#)
        #expect(spec.args.last == "do it")
        let resume = CodexProvider().buildResume(LaunchContext(cwd: "/w", prompt: "more", permissionPolicy: .autoEdits, effort: "low"), resumeId: "t")
        #expect(resume.args.contains(#"model_reasoning_effort="low""#))
    }

    @Test func noEffortMeansTheAgentsOwnDefault() {
        let claude = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask, effort: " "))
        #expect(!claude.args.contains("--effort"))
        let codex = CodexProvider().buildLaunch(LaunchContext(cwd: "/w", prompt: "p", permissionPolicy: .ask))
        #expect(!codex.args.contains("-c"))
    }

    @Test func codexsConfiguredEffortIsReadFromItsConfig() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try "model = \"gpt-6-astra\"\nmodel_reasoning_effort = \"xhigh\"\n\n[profiles.fast]\nmodel_reasoning_effort = \"low\"\n"
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        #expect(CodexProvider().configuredDefaultEffort(home: home) == "xhigh")
        #expect(CodexProvider().configuredDefaultModel(home: home) == "gpt-6-astra")
        #expect(ClaudeProvider().configuredDefaultEffort(home: home) == nil)
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
        let catalog = await ClaudeProvider().discoverModels(executor: LocalExecutor.shared, binary: nil)
        #expect(catalog?.models.isEmpty == false)
        #expect(catalog?.accountDefault != nil)
    }

    @Test func codexListsTheAccountsModels() async {
        let catalog = await CodexProvider().discoverModels(executor: LocalExecutor.shared, binary: nil)
        #expect(catalog?.models.isEmpty == false)
    }
}
