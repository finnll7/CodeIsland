import XCTest
@testable import CodeIslandCore

final class SessionHeadlineTests: XCTestCase {
    private func snapshot(cwd: String?, title: String?, source: String = "claude") -> SessionSnapshot {
        var s = SessionSnapshot()
        s.cwd = cwd
        s.sessionTitle = title
        s.source = source
        return s
    }

    func testProjectNameLeadsAndTitleTrailsByDefault() {
        let headline = snapshot(cwd: "/Users/me/code/island", title: "Fix hover delay")
            .headline(showProjectName: true)
        XCTAssertEqual(headline, SessionHeadline(text: "island", kind: .project, trailingSessionLabel: "Fix hover delay"))
    }

    func testHiddenProjectNamePromotesTheSessionTitle() {
        let headline = snapshot(cwd: "/Users/me/code/island", title: "  Fix hover delay ")
            .headline(showProjectName: false)
        XCTAssertEqual(headline.kind, .sessionTitle)
        XCTAssertEqual(headline.text, "Fix hover delay")
        XCTAssertNil(headline.trailingSessionLabel, "the title is not repeated after itself")
    }

    /// Without a title the card must not fall back to the folder it was told
    /// to hide — the agent name is the neutral stand-in.
    func testHiddenProjectNameWithoutTitleFallsBackToTheAgentNotTheFolder() {
        let headline = snapshot(cwd: "/Users/me/code/secret-client", title: nil, source: "codex")
            .headline(showProjectName: false)
        XCTAssertEqual(headline.kind, .agent)
        XCTAssertEqual(headline.text, "Codex")
        XCTAssertFalse(headline.text.contains("secret-client"))
    }

    func testBlankTitleCountsAsNoTitle() {
        let headline = snapshot(cwd: "/tmp/x", title: "   ", source: "claude").headline(showProjectName: false)
        XCTAssertEqual(headline.kind, .agent)
        XCTAssertEqual(headline.text, "Claude")
    }

    func testContextLabelFollowsTheSetting() {
        XCTAssertEqual(
            SessionHeadline.contextLabel(projectName: "island", sessionLabel: "Refactor", showProjectName: true),
            "island"
        )
        XCTAssertEqual(
            SessionHeadline.contextLabel(projectName: "island", sessionLabel: "Refactor", showProjectName: false),
            "Refactor"
        )
        XCTAssertNil(
            SessionHeadline.contextLabel(projectName: "island", sessionLabel: nil, showProjectName: false),
            "no title: show nothing rather than the folder"
        )
    }

    func testPandaMemoryWorkerIsRecognizedAndOrdinarySessionsAreNot() {
        var worker = snapshot(cwd: "/", title: nil, source: "panda")
        worker.providerSessionId = "memory-stage2--Users-kenshin-project-huixuesheng"
        XCTAssertTrue(worker.isPandaMemoryWorker)

        var stage1 = snapshot(cwd: "/", title: nil, source: "panda")
        stage1.providerSessionId = "memory-stage1--Users-kenshin-project-CodeIsland"
        XCTAssertTrue(stage1.isPandaMemoryWorker, "any memory-worker stage is an internal task")

        var conversation = snapshot(cwd: "/tmp/x", title: nil, source: "panda")
        conversation.providerSessionId = "64ae46cb-26ee-4cdf-8b93-a134a5d92585"
        XCTAssertFalse(conversation.isPandaMemoryWorker)

        var otherCLI = snapshot(cwd: "/tmp/x", title: nil, source: "claude")
        otherCLI.providerSessionId = "memory-stage2--Users-kenshin-project-CodeIsland"
        XCTAssertFalse(otherCLI.isPandaMemoryWorker, "the prefix only means something on a panda session")
    }
}
