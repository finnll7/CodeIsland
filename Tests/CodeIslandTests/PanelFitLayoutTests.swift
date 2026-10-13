import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Every expanded surface has to fit the panel window: what doesn't is cut
/// off by the window's bottom edge, out of reach. Rendered offscreen on a red
/// backdrop (PanelHost) so the panel's bottom edge can be read from pixels.
@MainActor
final class PanelFitLayoutTests: XCTestCase {
    private var sandbox: DefaultsSandbox?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() {
        MascotAnimationGate.shared.setPanelVisible(true)
        sandbox?.restore()
        super.tearDown()
    }

    // MARK: - Session list

    func testListScrollsByHeightNotOnlyBySessionCount() {
        // The task box is a fixed slot sized by task count — not a
        // count-triggered switch: four tall cards scroll exactly like eight
        // short ones once they outgrow the two-card slot.
        // slot = cards*90 + headers*24 + 8 (a header budgeted per card).
        let slot = PanelHeightMetrics.taskSlotHeight(taskCount: 4, maxVisibleSessions: 2)
        XCTAssertEqual(slot, 236, accuracy: 1)
        XCTAssertGreaterThan(4 * 150, slot, "four tall cards must overflow the box")
        XCTAssertGreaterThan(4 * 90, slot, "four normal cards overflow the two-card slot too")
        XCTAssertLessThan(90, slot, "a single card fits without scrolling")
        // Two tasks and eight tasks reserve the same slot; one reserves half.
        XCTAssertEqual(PanelHeightMetrics.taskSlotHeight(taskCount: 8, maxVisibleSessions: 2), slot, accuracy: 1)
        XCTAssertEqual(PanelHeightMetrics.taskSlotHeight(taskCount: 1, maxVisibleSessions: 2), 122, accuracy: 1)
        // No tasks, no slot at all.
        XCTAssertEqual(PanelHeightMetrics.taskSlotHeight(taskCount: 0, maxVisibleSessions: 2), 0, accuracy: 1)
        // The setting widens the slot; the task count grows it up to the cap.
        XCTAssertEqual(PanelHeightMetrics.taskSlotHeight(taskCount: 3, maxVisibleSessions: 5), 350, accuracy: 1)
        XCTAssertEqual(PanelHeightMetrics.taskSlotHeight(taskCount: 5, maxVisibleSessions: 5), 578, accuracy: 1)
        XCTAssertEqual(PanelHeightMetrics.taskSlotHeight(taskCount: 8, maxVisibleSessions: 5), 578, accuracy: 1)
        // And the window grows with the setting (full-slot budget).
        XCTAssertEqual(PanelHeightMetrics.desiredHeight(maxVisibleSessions: 5), 948, accuracy: 1)
    }

    func testFewTallSessionsStayInsideTheWindow() throws {
        // Four sessions — under the five the window is sized for — but with
        // a task list, an approval row and a recap they ran ~150pt past the
        // 510pt window, footer and all.
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    func testTallSessionsAtALargeFontStayInsideTheWindow() throws {
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 37)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    func testSqueezedBranchKeepsAFewCharacters() {
        // A long project name used to leave the branch an icon and "…".
        let short = BranchLabelMetrics.minimumWidth(for: "main", fontSize: 11)
        let long = BranchLabelMetrics.minimumWidth(for: "feature/very-long-branch-name-for-onboarding-flow", fontSize: 11)
        let twelve = BranchLabelMetrics.minimumWidth(for: String(repeating: "x", count: 12), fontSize: 11)
        XCTAssertLessThan(short, twelve, "a short branch must not be padded")
        XCTAssertEqual(long, twelve, accuracy: 1, "a long branch keeps room for twelve characters")
    }

    // MARK: - Question card

    func testQuestionWithManyOptionsKeepsItsButtonsInsideTheWindow() async throws {
        // Ten options with descriptions used to push option 10, "Other" and
        // the Dismiss / Skip row past the bottom of the 510pt window.
        let state = AppState()
        var s = SessionSnapshot()
        s.source = "claude"
        s.cwd = "/Users/dev/code/web-app"
        s.status = .waitingQuestion
        state.sessions = ["q": s]
        state.activeSessionId = "q"
        let regions = (1...10).map { ("region-\($0)", Optional("Latency to the team: medium")) }
        let release = try await DemoRequests.enqueueQuestion(state, sessionId: "q", cwd: "/Users/dev/code/web-app", items: [
            ("Which region should the staging stack deploy to?", "Region", regions, false),
        ])
        defer { release() }
        state.refreshDerivedState()
        state.surface = .questionCard(sessionId: "q")
        let panel = try PanelHost(state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the question card runs off the bottom of the window")
    }

    // MARK: - Approval card

    func testApprovalCardHeadsItselfWithTheSessionAsking() async throws {
        // With several sessions queued, the card said only "! Bash" — not
        // which project's command it was about to allow. It now opens with
        // the same context row as a question card (agent icon + project),
        // which only a card whose session is gone goes without.
        func cardHeight(sessionKnown: Bool) async throws -> CGFloat {
            let state = AppState()
            var s = SessionSnapshot()
            s.source = "codex"
            s.cwd = "/Users/dev/code/api-server"
            s.status = .waitingApproval
            if sessionKnown { state.sessions = ["c": s] }
            state.activeSessionId = "c"
            let release = await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent([
                "hook_event_name": "PermissionRequest", "session_id": "c", "cwd": "/Users/dev/code/api-server",
                "_source": "codex", "tool_name": "Bash", "tool_input": ["command": "cargo test"],
            ]))
            defer { release() }
            state.refreshDerivedState()
            state.surface = .approvalCard(sessionId: "c")
            let panel = try PanelHost(state, notchHeight: 32)
            defer { panel.close() }
            panel.settle()
            return panel.height - (try panel.gapUnderPanel())
        }
        let withRow = try await cardHeight(sessionKnown: true)
        let withoutRow = try await cardHeight(sessionKnown: false)
        XCTAssertGreaterThan(withRow - withoutRow, 14, "the approval card has no session context row")
    }

    // MARK: - Fixtures

    private struct Demo {
        let state: AppState
        let release: () -> Void
    }

    private func tallSessions(count: Int) throws -> Demo {
        let state = AppState()
        var usage = ClaudeUsageTotals()
        usage.outputTokens = 96_000
        state.claudeUsage = ClaudeUsageScanner.Snapshot(last5h: usage, today: usage, hourlyOutputTokens: [1, 2, 3], scannedAt: Date())
        for index in 0..<count {
            var s = SessionSnapshot(startTime: Date().addingTimeInterval(-600))
            s.source = "claude"
            s.cwd = "/Users/dev/code/project-\(index)"
            s.gitBranch = "feat/branch-\(index)"
            s.status = .running
            s.currentTool = "Edit"
            s.toolDescription = "src/components/Dashboard.tsx"
            s.lastUserPrompt = "Add filters to the dashboard page"
            s.addRecentMessage(ChatMessage(isUser: true, text: "Add filters to the dashboard page"))
            s.addRecentMessage(ChatMessage(isUser: false, text: "Adding a date-range and status filter bar above the orders table."))
            s.agentTasks = AgentTaskList(items: (1...5).map {
                AgentTaskItem(id: "t\($0)", title: "Task \($0)", status: $0 < 3 ? .completed : ($0 == 3 ? .inProgress : .pending))
            })
            state.sessions["s\(index)"] = s
        }
        state.activeSessionId = "s0"
        state.refreshDerivedState()
        state.surface = .sessionList
        return Demo(state: state, release: {})
    }
}
