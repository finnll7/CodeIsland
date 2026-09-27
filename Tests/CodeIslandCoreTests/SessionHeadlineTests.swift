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

    func testTitledSessionLeadsWithTheTitleAndTrailsTheFolder() {
        let headline = snapshot(cwd: "/Users/me/code/island", title: "Fix hover delay")
            .headline(showProjectName: true)
        // The session title is the task name — it leads; the folder follows
        // as a smaller link instead of the other way round.
        XCTAssertEqual(headline, SessionHeadline(text: "Fix hover delay", kind: .sessionTitle, trailingProjectName: "island"))
    }

    func testHiddenProjectNameShowsTheTitleAlone() {
        let headline = snapshot(cwd: "/Users/me/code/island", title: "  Fix hover delay ")
            .headline(showProjectName: false)
        XCTAssertEqual(headline.kind, .sessionTitle)
        XCTAssertEqual(headline.text, "Fix hover delay")
        XCTAssertNil(headline.trailingProjectName, "the folder is hidden")
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
}
