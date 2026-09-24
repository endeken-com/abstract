import Foundation
import Testing
@testable import AbstractCore

@Suite("Local model providers", .serialized)
struct LocalModelProviderTests {
    @Test func codexIsPointedAtTheServer() {
        LocalModelEndpoints.set(.ollama, URL(string: "http://192.168.1.20:11434"))
        defer { LocalModelEndpoints.set(.ollama, nil) }
        let spec = LocalModelProvider(.ollama).buildLaunch(LaunchContext(cwd: "/tmp/wt", prompt: "Fix it", permissionPolicy: .autoEdits,
                                                                        model: "qwen3-coder:30b"))
        #expect(spec.command == "codex")
        let args = spec.args.joined(separator: " ")
        #expect(args.contains("-c model_provider=\"abstract_ollama\""))
        #expect(args.contains("-c model_providers.abstract_ollama.base_url=\"http://192.168.1.20:11434/v1\""))
        #expect(args.contains("-m qwen3-coder:30b"))
        #expect(spec.args.last == "Fix it")
    }

    @Test func lmStudioDefaultsToItsOwnPort() {
        let args = LocalModelProvider(.lmstudio).serverArgs().joined(separator: " ")
        #expect(args.contains("http://127.0.0.1:1234/v1"))
    }

    @Test func modelListsLeaveOutEmbeddings() {
        let ollama = #"{"models":[{"name":"qwen3-coder:30b"},{"name":"nomic-embed-text:latest"},{"name":"gpt-oss:20b"}]}"#
        #expect(LocalModelServer.models(.ollama, from: Data(ollama.utf8)) == ["qwen3-coder:30b", "gpt-oss:20b"])
        let lmstudio = #"{"data":[{"id":"openai/gpt-oss-20b","object":"model"},{"id":"text-embedding-nomic-embed-text-v1.5"}]}"#
        #expect(LocalModelServer.models(.lmstudio, from: Data(lmstudio.utf8)) == ["openai/gpt-oss-20b"])
    }

    @Test func anUnreachableServerSaysSo() async {
        let status = await LocalModelServer.status(.ollama, at: URL(string: "http://127.0.0.1:9")!)
        #expect(!status.reachable && status.error != nil)
    }
}

@Suite("Local model pricing")
struct LocalModelPricingTests {
    @Test func localModelsHaveNoPrice() {
        #expect(ModelPricing.rates(provider: .codex, model: "qwen3-coder:30b") == nil)
        #expect(ModelPricing.rates(provider: .codex, model: "openai/gpt-oss-20b") == nil)
        #expect(ModelPricing.rates(provider: .codex, model: "o4-mini")?.known == false)
    }
}
