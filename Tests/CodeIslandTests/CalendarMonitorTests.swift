import CodeIslandCore
import XCTest
@testable import CodeIsland

/// CalendarMonitor's pure display formatting (EventKit itself can't be unit
/// tested — these cover the countdown/progress derivation only).
@MainActor
final class CalendarMonitorTests: XCTestCase {
    private let localize: (String) -> String = { key in
        [
            "calendar_in_progress": "In progress — %d min left",
            "calendar_ending_now": "Ending now",
            "calendar_starts_in_min": "Starts in %d min",
            "calendar_starting_now": "Starting now",
        ][key] ?? key
    }

    private func event(start: Date, end: Date, inProgress: Bool) -> CalendarMonitor.DisplayEvent {
        CalendarMonitor.DisplayEvent(title: "Standup", start: start, end: end, isInProgress: inProgress)
    }

    func testInProgressCountdown() {
        let now = Date()
        let event = event(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(1500), inProgress: true)
        XCTAssertEqual(CalendarMonitor.countdownText(event: event, now: now, localize: localize), "In progress — 25 min left")
    }

    func testInProgressEndingInsideTheMinute() {
        let now = Date()
        let event = event(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(30), inProgress: true)
        XCTAssertEqual(CalendarMonitor.countdownText(event: event, now: now, localize: localize), "Ending now")
    }

    func testUpcomingCountdown() {
        let now = Date()
        let event = event(start: now.addingTimeInterval(120 * 60), end: now.addingTimeInterval(150 * 60), inProgress: false)
        XCTAssertEqual(CalendarMonitor.countdownText(event: event, now: now, localize: localize), "Starts in 120 min")
    }

    func testUpcomingStartingInsideTheMinute() {
        let now = Date()
        let event = event(start: now.addingTimeInterval(20), end: now.addingTimeInterval(60 * 60), inProgress: false)
        XCTAssertEqual(CalendarMonitor.countdownText(event: event, now: now, localize: localize), "Starting now")
    }

    func testTomorrowEventUsesTomorrowTemplate() {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let event = event(start: start, end: start.addingTimeInterval(1800), inProgress: false)
        let text = CalendarMonitor.countdownText(event: event, now: now, localize: localize)
        XCTAssertTrue(text.hasPrefix("Tomorrow at "), text)
    }

    func testLaterThisWeekUsesDateTemplate() {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: 4, to: now)!
        let event = event(start: start, end: start.addingTimeInterval(1800), inProgress: false)
        let text = CalendarMonitor.countdownText(event: event, now: now, localize: localize)
        XCTAssertTrue(text.hasPrefix("Starts "), text)
    }

    func testProgressFractionBounds() {
        let now = Date()
        let running = event(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600), inProgress: true)
        XCTAssertEqual(CalendarMonitor.progressFraction(event: running, now: now) ?? -1, 0.5, accuracy: 0.01)
        let upcoming = event(start: now.addingTimeInterval(600), end: now.addingTimeInterval(1200), inProgress: false)
        XCTAssertNil(CalendarMonitor.progressFraction(event: upcoming, now: now))
    }
}
