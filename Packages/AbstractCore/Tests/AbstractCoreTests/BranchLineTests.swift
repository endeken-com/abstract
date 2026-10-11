import Foundation
import Testing
@testable import AbstractCore

@Suite struct BranchLineTests {
    @Test func namesTheBranchAndTheWorktreeItLivesIn() {
        let line = BranchLine(branch: "roadmap-product-owner-research", worktreePath: "/tmp/worktrees/repo-1a2b/abuja")
        #expect(line.help == "Branch: roadmap-product-owner-research in worktree abuja")
        #expect(line.accessibilityLabel == "Branch roadmap-product-owner-research")
    }

    @Test func leavesTheFolderOutWhenItMatchesTheBranchOrIsMissing() {
        #expect(BranchLine(branch: "abuja", worktreePath: "/tmp/worktrees/repo-1a2b/abuja/").help == "Branch: abuja")
        #expect(BranchLine(branch: "abstract/abuja", worktreePath: nil).help == "Branch: abstract/abuja")
        #expect(BranchLine(branch: "main", worktreePath: "/").help == "Branch: main")
    }

    @Test func buildsFromTheChat() {
        let chat = Session(projectId: "p", name: "Fix login", providerId: "claude",
                           worktreePath: "/tmp/worktrees/repo-1a2b/lisbon", branch: "abstract/fix-login")
        #expect(BranchLine(session: chat)?.help == "Branch: abstract/fix-login in worktree lisbon")
        #expect(BranchLine(session: chat)?.accessibilityLabel == "Branch abstract/fix-login")

        let standalone = Session(projectId: nil, name: "Notes", providerId: "claude",
                                 worktreePath: "/tmp/notes", branch: "main")
        #expect(BranchLine(session: standalone)?.help == "Branch: main in folder notes")

        #expect(BranchLine(session: Session(projectId: "p", name: "New", providerId: "claude")) == nil)
    }
}
