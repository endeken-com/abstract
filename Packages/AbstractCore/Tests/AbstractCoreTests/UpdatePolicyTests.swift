import Testing
@testable import AbstractCore

@Suite struct UpdatePolicyTests {
    @Test func onlyNightlyAcceptsTheNightlyChannel() {
        #expect(UpdateChannel.stable.sparkleChannels.isEmpty)
        #expect(UpdateChannel.nightly.sparkleChannels == ["nightly"])
    }

    @Test func storedChannelFallsBackToStable() {
        #expect(UpdateChannel(stored: "nightly") == .nightly)
        #expect(UpdateChannel(stored: "stable") == .stable)
        #expect(UpdateChannel(stored: nil) == .stable)
        #expect(UpdateChannel(stored: "") == .stable)
        #expect(UpdateChannel(stored: "beta") == .stable)
        #expect(UpdateChannel(stored: "Nightly") == .stable)
    }

    @Test func releaseBuildsUpdateThemselves() {
        #expect(UpdatePolicy.shouldStart(version: "0.9.1", isDebug: false, isDemo: false))
        #expect(UpdatePolicy.shouldStart(version: "0.10.0-nightly.42", isDebug: false, isDemo: false))
    }

    @Test func devDebugAndDemoBuildsNeverUpdate() {
        #expect(!UpdatePolicy.shouldStart(version: "0.0.0", isDebug: false, isDemo: false))
        #expect(!UpdatePolicy.shouldStart(version: nil, isDebug: false, isDemo: false))
        #expect(!UpdatePolicy.shouldStart(version: "", isDebug: false, isDemo: false))
        #expect(!UpdatePolicy.shouldStart(version: "0.9.1", isDebug: true, isDemo: false))
        #expect(!UpdatePolicy.shouldStart(version: "0.9.1", isDebug: false, isDemo: true))
    }
}
