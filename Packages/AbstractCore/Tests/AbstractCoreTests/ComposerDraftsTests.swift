import XCTest
@testable import AbstractCore

@MainActor
final class ComposerDraftsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("composer-drafts.json") }

    func testEachChatKeepsItsOwnDraft() {
        let drafts = ComposerDrafts(file: nil)
        drafts.draft("a").text = "for a"
        drafts.draft("b").text = "for b"
        drafts.draft(ComposerDrafts.newChat).text = "a new task"

        XCTAssertEqual(drafts.draft("a").text, "for a")
        XCTAssertEqual(drafts.draft("b").text, "for b")
        XCTAssertEqual(drafts.draft(ComposerDrafts.newChat).text, "a new task")
        XCTAssertEqual(drafts.draft("c").text, "")
    }

    func testTheSameDraftComesBackForAKey() {
        let drafts = ComposerDrafts(file: nil)
        let first = drafts.draft("a")
        first.text = "typed"
        XCTAssertTrue(drafts.draft("a") === first)
    }

    func testClearEmptiesTextAndAttachments() {
        let drafts = ComposerDrafts(file: nil)
        let draft = drafts.draft("a")
        draft.text = "hello"
        draft.attachments = [PromptAttachment(kind: .githubIssue, title: "Bug", reference: "#1")]
        draft.clear()
        XCTAssertTrue(draft.value.isEmpty)
        XCTAssertTrue(drafts.snapshot.isEmpty)
    }

    func testSnapshotSkipsEmptyDrafts() {
        let drafts = ComposerDrafts(file: nil)
        drafts.draft("a").text = "kept"
        _ = drafts.draft("b")
        XCTAssertEqual(drafts.snapshot, ["a": ComposerDraft(text: "kept")])
    }

    func testRemoveForgetsADeletedChat() {
        let drafts = ComposerDrafts(file: nil)
        drafts.draft("a").text = "gone"
        drafts.remove("a")
        XCTAssertEqual(drafts.draft("a").text, "")
    }

    func testDraftsSurviveARelaunch() async throws {
        let issue = PromptAttachment(kind: .githubIssue, title: "Bug", reference: "#1")
        let drafts = ComposerDrafts(file: file, delay: .milliseconds(10))
        drafts.draft("a").text = "half a thought"
        drafts.draft("a").attachments = [issue]
        drafts.draft(ComposerDrafts.newChat).text = "new"
        drafts.flush()

        let relaunched = ComposerDrafts(file: file)
        XCTAssertEqual(relaunched.draft("a").text, "half a thought")
        XCTAssertEqual(relaunched.draft("a").attachments, [issue])
        XCTAssertEqual(relaunched.draft(ComposerDrafts.newChat).text, "new")
    }

    func testTypingSavesAfterAPause() async throws {
        let drafts = ComposerDrafts(file: file, delay: .milliseconds(20))
        for prefix in ["h", "he", "hel", "hell", "hello"] { drafts.draft("a").text = prefix }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        for _ in 0..<100 where ComposerDrafts.read(file)["a"]?.text != "hello" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(ComposerDrafts.read(file)["a"]?.text, "hello")
    }

    func testClearingEveryDraftRemovesTheFile() {
        let drafts = ComposerDrafts(file: file)
        drafts.draft("a").text = "x"
        drafts.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        drafts.draft("a").clear()
        drafts.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingAttachedFilesAreDroppedOnLoad() throws {
        let kept = dir.appendingPathComponent("kept.txt")
        try Data("x".utf8).write(to: kept)
        let present = PromptAttachment(kind: .file, title: "kept.txt", path: kept.path)
        let missing = PromptAttachment(kind: .image, title: "gone.png", path: dir.appendingPathComponent("gone.png").path)
        ComposerDrafts.write(["a": ComposerDraft(attachments: [present, missing]),
                              "b": ComposerDraft(attachments: [missing])], to: file)

        let drafts = ComposerDrafts(file: file)
        XCTAssertEqual(drafts.draft("a").attachments, [present])
        XCTAssertNil(drafts.snapshot["b"])
    }

    func testUnreadableFileStartsEmpty() throws {
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(ComposerDrafts(file: file).snapshot.isEmpty)
    }
}
