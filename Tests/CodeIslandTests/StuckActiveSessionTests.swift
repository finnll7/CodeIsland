import XCTest
@testable import CodeIsland
import CodeIslandCore

/// A finished turn's Stop sets the card idle — but events that are not a new
/// turn can revive it afterwards: an idle-time auto-compact's PreCompact, a
/// background-task completion Notification, or an out-of-order tool hook
/// racing the Stop. A daemon-backed host (Panda desktop) never exits, so no
/// process backstop corrected the card and it read "running" for hours.
final class StuckActiveSessionTests: XCTestCase {

    // MARK: - The predicate

    func testQuietActiveCardIsStuck() {
        let now = Date()
        XCTAssertTrue(AppState.isStuckActiveSession(
            status: .running, lastActivity: now.addingTimeInterval(-601), now: now
        ))
        XCTAssertTrue(AppState.isStuckActiveSession(
            status: .processing, lastActivity: now.addingTimeInterval(-601), now: now
        ))
    }

    func testFreshActiveCardIsNotStuck() {
        let now = Date()
        XCTAssertFalse(AppState.isStuckActiveSession(
            status: .running, lastActivity: now.addingTimeInterval(-599), now: now
        ))
        // A card still firing hook events keeps resetting its clock.
        XCTAssertFalse(AppState.isStuckActiveSession(
            status: .running, lastActivity: now, now: now
        ))
    }

    func testWaitingAndIdleCardsAreExempt() {
        let now = Date()
        let ancient = now.addingTimeInterval(-3600)
        for status in [AgentStatus.idle, .waitingApproval, .waitingQuestion] {
            XCTAssertFalse(AppState.isStuckActiveSession(status: status, lastActivity: ancient, now: now))
        }
    }

    // MARK: - The sweep

    /// PreCompact while idle: .processing with a pinned description — the
    /// exact shape the thinking-timeout skip (it requires an empty
    /// description) left running forever.
    @MainActor
    func testCompactingCardPinnedByToolDescriptionSettlesToIdle() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "panda"
        session.status = .processing
        session.toolDescription = "Compacting context…"
        session.lastActivity = Date().addingTimeInterval(-900)
        appState.sessions["panda-1"] = session

        appState.settleStuckActiveSessions()

        let settled = appState.sessions["panda-1"]
        XCTAssertEqual(settled?.status, .idle, "a card quiet for 15 minutes is not compacting anymore")
        XCTAssertNil(settled?.currentTool)
        XCTAssertNil(settled?.toolDescription)
    }

    /// A late PreToolUse after the Stop: .running with a tool in flight that
    /// never got its PostToolUse. No watchdog covered .running at all.
    @MainActor
    func testRevivedRunningCardWithToolChromeSettlesToIdle() {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .running
        session.currentTool = "Bash"
        session.toolDescription = "swift build"
        session.lastActivity = Date().addingTimeInterval(-1200)
        appState.sessions["claude-1"] = session

        appState.settleStuckActiveSessions()

        XCTAssertEqual(appState.sessions["claude-1"]?.status, .idle)
        XCTAssertNil(appState.sessions["claude-1"]?.currentTool)
        XCTAssertNil(appState.sessions["claude-1"]?.toolDescription)
    }

    @MainActor
    func testBusyWaitingAndRemoteCardsAreLeftAlone() {
        let appState = AppState()

        var busy = SessionSnapshot()
        busy.source = "claude"
        busy.status = .running
        busy.currentTool = "Bash"
        busy.lastActivity = Date().addingTimeInterval(-60)  // still firing events
        appState.sessions["busy"] = busy

        var waiting = SessionSnapshot()
        waiting.source = "claude"
        waiting.status = .waitingApproval
        waiting.lastActivity = Date().addingTimeInterval(-3600)
        appState.sessions["waiting"] = waiting

        var remote = SessionSnapshot()
        remote.source = "claude"
        remote.remoteHostId = "ssh-box"
        remote.status = .running
        remote.lastActivity = Date().addingTimeInterval(-3600)
        appState.sessions["remote"] = remote

        appState.settleStuckActiveSessions()

        XCTAssertEqual(appState.sessions["busy"]?.status, .running, "a card with fresh events is working")
        XCTAssertEqual(appState.sessions["waiting"]?.status, .waitingApproval, "waiting states are actionable, not stuck")
        XCTAssertEqual(appState.sessions["remote"]?.status, .running, "remote turns can legitimately stay silent (#121)")
    }
}
