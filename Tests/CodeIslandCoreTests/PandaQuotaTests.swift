import XCTest
@testable import CodeIslandCore

final class PandaQuotaTests: XCTestCase {
    func testParseQuotaFetchMappedResponse() throws {
        // Shape actually returned by window.pandaDesktop.quotaFetch() (the
        // WLt-mapped structure with display strings), verified live via CDP.
        let json = """
        {"status":"ok","quotaStatus":"normal","billingScope":"user","billingScopeLabel":"个人套餐",
         "organizationLabel":"教育产品研发运营中心","planLabel":"二档套餐","message":"",
         "usedCreditsDisplay":"17,688","creditLimitDisplay":"35,000","remainingCreditsDisplay":"17,312",
         "usagePercent":51,"showProgress":true,"renewalText":"将于 2026年9月28日 刷新",
         "periodText":"2026-09-21 ～ 2026-09-28","isUnlimited":false,"hasPlan":true,"fetchedAt":1790493856865}
        """.data(using: .utf8)!
        let snap = try PandaQuotaSnapshot.parse(json)
        XCTAssertEqual(snap.planLabel, "二档套餐")
        XCTAssertEqual(snap.usedCredits, 17688)
        XCTAssertEqual(snap.creditLimit, 35000)
        XCTAssertEqual(snap.remainingCredits, 17312)
        XCTAssertEqual(snap.usagePercent, 51)
        XCTAssertEqual(snap.renewalText, "将于 2026年9月28日 刷新")
        XCTAssertEqual(snap.periodText, "2026-09-21 ～ 2026-09-28")
        XCTAssertTrue(snap.hasPlan)
        XCTAssertEqual(snap.level, .normal)
        XCTAssertEqual(snap.creditsDisplay(snap.usedCredits), "17,688")
    }

    func testParseGatewayRawResponse() throws {
        // Shape per the Jbn normaliser in Panda Desktop's quotaRuntime (direct
        // API path, numeric fields).
        let json = """
        {"quotaStatus":"normal","billingScope":"user","billingScopeLabel":"个人","organizationLabel":"",
         "planLabel":"二档套餐","usedCredits":16971,"personalUsedCredits":0,"remainingCredits":18029,
         "creditLimit":35000,"creditHardLimit":0,"overdraftCredits":0,"limitDisplay":"35000",
         "usagePercent":48,"isUnlimited":false,"message":"","windowStartLabel":"2026-09-22","windowEndLabel":"2026-09-28"}
        """.data(using: .utf8)!
        let snap = try PandaQuotaSnapshot.parse(json)
        XCTAssertEqual(snap.planLabel, "二档套餐")
        XCTAssertEqual(snap.usedCredits, 16971)
        XCTAssertEqual(snap.creditLimit, 35000)
        XCTAssertEqual(snap.remainingCredits, 18029)
        XCTAssertEqual(snap.usagePercent, 48)
        XCTAssertTrue(snap.hasPlan)
        XCTAssertEqual(snap.level, .normal)
        XCTAssertEqual(snap.creditsDisplay(snap.usedCredits), "16,971")
    }

    func testParseUnwrapsDataEnvelope() throws {
        let json = #"{"data":{"planLabel":"二档套餐","usedCredits":100,"creditLimit":200,"usagePercent":50}}"#.data(using: .utf8)!
        let snap = try PandaQuotaSnapshot.parse(json)
        XCTAssertEqual(snap.planLabel, "二档套餐")
        XCTAssertEqual(snap.usagePercent, 50)
    }

    func testParseRejectsNonQuotaPayload() {
        XCTAssertThrowsError(try PandaQuotaSnapshot.parse(#"{"foo":1}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try PandaQuotaSnapshot.parse("not json".data(using: .utf8)!))
    }

    func testLevelThresholds() {
        func snap(_ percent: Double) -> PandaQuotaSnapshot {
            PandaQuotaSnapshot(planLabel: "p", usedCredits: 0, creditLimit: 0, remainingCredits: 0,
                               usagePercent: percent, billingScope: "user", quotaStatus: "normal",
                               periodText: "", renewalText: "", isUnlimited: false, fetchedAt: Date())
        }
        XCTAssertEqual(snap(79).level, .normal)
        XCTAssertEqual(snap(80).level, .warning)
        XCTAssertEqual(snap(100).level, .critical)
    }
}
