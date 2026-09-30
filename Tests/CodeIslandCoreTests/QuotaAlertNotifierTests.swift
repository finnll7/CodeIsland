import CodeIslandCore
import XCTest
@testable import CodeIslandCore

/// QuotaAlertNotifier's pure tier selection: one shot per tier per billing
/// window, most severe unsent tier wins, refill clears the flags.
final class QuotaAlertNotifierTests: XCTestCase {
    func testAboveFortyPercentNeverAlerts() {
        XCTAssertNil(QuotaAlertNotifier.alertTier(remainingPercent: 41, sentFlags: []))
        XCTAssertNil(QuotaAlertNotifier.alertTier(remainingPercent: 100, sentFlags: []))
    }

    func testFirstCrossingSelectsTheFortyTier() {
        let tier = QuotaAlertNotifier.alertTier(remainingPercent: 39, sentFlags: [])
        XCTAssertEqual(tier?.key, "quotaAlertSent40")
    }

    func testAlreadySentTierIsSkipped() {
        let tier = QuotaAlertNotifier.alertTier(remainingPercent: 15, sentFlags: ["quotaAlertSent40"])
        // 40% already alerted → next unsent tier down is 20%.
        XCTAssertEqual(tier?.key, "quotaAlertSent20")
    }

    func testBulkBurnDownJumpsToTheMostSevereUnsentTier() {
        // Sleep-walk from 100% to 5%: only ONE notification, the 10% tier.
        let tier = QuotaAlertNotifier.alertTier(remainingPercent: 5, sentFlags: [])
        XCTAssertEqual(tier?.key, "quotaAlertSent10")
    }

    func testAllTiersSentMeansSilence() {
        XCTAssertNil(QuotaAlertNotifier.alertTier(
            remainingPercent: 5,
            sentFlags: ["quotaAlertSent40", "quotaAlertSent20", "quotaAlertSent10"]
        ))
    }

    func testRefillClearsFlags() {
        // New billing window: remaining back above 40% → nil now, and the
        // caller clears the flags so next cycle re-alerts.
        XCTAssertNil(QuotaAlertNotifier.alertTier(
            remainingPercent: 75,
            sentFlags: ["quotaAlertSent40", "quotaAlertSent20", "quotaAlertSent10"]
        ))
    }

    func testBoundaryValuesAreInclusive() {
        // "不足 40%" thresholds hit exactly at 40/20/10 remaining.
        XCTAssertNotNil(QuotaAlertNotifier.alertTier(remainingPercent: 40, sentFlags: []))
        XCTAssertNotNil(QuotaAlertNotifier.alertTier(remainingPercent: 20, sentFlags: ["quotaAlertSent40"]))
        XCTAssertNotNil(QuotaAlertNotifier.alertTier(remainingPercent: 10, sentFlags: ["quotaAlertSent40", "quotaAlertSent20"]))
    }

    func testNegativeRemainingClampsIntoTheDeepestTier() {
        // Overdrawn (more used than the limit) still alerts the deepest tier.
        let tier = QuotaAlertNotifier.alertTier(remainingPercent: -3, sentFlags: [])
        XCTAssertEqual(tier?.key, "quotaAlertSent10")
    }
}
