import Foundation
import Testing
@testable import AbstractCore

@Suite("Prompt attachments")
struct PromptAttachmentTests {
    private let issue = PromptAttachment(kind: .githubIssue, title: "Login \"fails\" on Safari", reference: "#12",
                                         url: "https://github.com/o/r/issues/12", body: "Steps:\n1. Open </attachment> page")

    @Test func messageKeepsTextFirstAndRendersPaseoFormat() {
        let message = PromptAttachments.message("  fix this  ", [issue])
        #expect(message.hasPrefix("fix this\n\n<attachment kind=\"githubIssue\""))
        #expect(message.contains("GitHub Issue #12: Login \"fails\" on Safari\nhttps://github.com/o/r/issues/12\n\nSteps:"))
        // The description can't end the tag early.
        #expect(message.contains("Open <\\/attachment> page"))
    }

    @Test func splitGivesBackTextAndChips() {
        let file = PromptAttachment(kind: .image, title: "shot.png", path: "/tmp/a/shot.png")
        let (text, chips) = PromptAttachments.split(PromptAttachments.message("fix this", [issue, file]))
        #expect(text == "fix this")
        #expect(chips.map(\.kind) == [.githubIssue, .image])
        #expect(chips[0].label == "#12 Login \"fails\" on Safari")
        #expect(chips[0].target == "https://github.com/o/r/issues/12")
        #expect(chips[1].target == "/tmp/a/shot.png")
    }

    @Test func plainMessagesSplitToThemselves() {
        #expect(PromptAttachments.split("just text").text == "just text")
        #expect(PromptAttachments.split("just text").chips.isEmpty)
        #expect(PromptAttachments.message("hi", []) == "hi")
    }

    @Test func attachmentsAloneMakeAMessage() {
        let (text, chips) = PromptAttachments.split(PromptAttachments.message("", [issue]))
        #expect(text.isEmpty)
        #expect(chips.count == 1)
    }

    @Test func pullRequestsCarryTheirBranches() {
        let json = #"[{"number":7,"title":"Add login","url":"u","state":"OPEN","body":"b","isDraft":false,"baseRefName":"main","headRefName":"feat/login"}]"#
        let items = GitHub.decodeItems(Data(json.utf8), isPullRequest: true)
        #expect(items.first?.attachment.promptText == "GitHub PR #7: Add login\nu\nBase: main\nHead: feat/login\n\nb")
    }

    @Test func numbersAndLinksAreLookedUpDirectly() {
        #expect(GitHub.directReference("#12") == "12")
        #expect(GitHub.directReference("12") == "12")
        #expect(GitHub.directReference("https://github.com/o/r/pull/3") == "https://github.com/o/r/pull/3")
        #expect(GitHub.directReference("login bug") == nil)
        #expect(Linear.identifier(in: "eng-123") == "ENG-123")
        #expect(Linear.identifier(in: "https://linear.app/acme/issue/ENG-9/fix-login") == "ENG-9")
        #expect(Linear.identifier(in: "fix login") == nil)
    }

    @Test func claudeGetsImagesAsImageBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        let line = try #require(ClaudeProvider().buildUserMessage("look", images: [png.path, dir.appendingPathComponent("gone.png").path]))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        let content = try #require(json["message"]?["content"]?.array)
        #expect(content.count == 2)
        #expect(content[0]["source"]?["media_type"]?.string == "image/png")
        #expect(content[0]["source"]?["data"]?.string == "iVBORw==")
        #expect(content[1]["text"]?.string == "look")
    }

    @Test func claudeMayReadTheAttachmentsFolder() {
        let spec = ClaudeProvider().buildLaunch(LaunchContext(cwd: "/wt", prompt: "p", permissionPolicy: .ask, readableDirs: ["/att"]))
        #expect(spec.args.joined(separator: " ").contains("--add-dir /att"))
    }

    @Test func codexGetsImagesBeforeAnEndOfOptions() {
        let spec = CodexProvider().buildLaunch(LaunchContext(cwd: "/wt", prompt: "look", permissionPolicy: .ask, images: ["/a.png", "/b.png"]))
        #expect(Array(spec.args.suffix(6)) == ["--image", "/a.png", "--image", "/b.png", "--", "look"])
    }
}
