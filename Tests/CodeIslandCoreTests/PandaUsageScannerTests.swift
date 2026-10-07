import XCTest
@testable import CodeIslandCore

final class PandaUsageScannerTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "panda-usage-tests-" + UUID().uuidString
        // Panda lays transcripts out under a per-project sessions/ subdirectory.
        try FileManager.default.createDirectory(
            atPath: home + "/projects/p1/sessions", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func epochMs(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }

    private func turnMetricsLine(turns: [(id: String, startedAt: Date, prompt: Int, completion: Int, cached: Int, cacheWrite: Int)]) -> String {
        let entries = turns.map { t in
            """
            {"turnId":"\(t.id)","startedAt":\(epochMs(t.startedAt)),"completedAt":\(epochMs(t.startedAt) + 60_000),"modelId":"m","promptTokens":\(t.prompt),"completionTokens":\(t.completion),"totalTokens":\(t.prompt + t.completion),"cachedTokens":\(t.cached),"cacheWriteTokens":\(t.cacheWrite),"reactLoopCount":1,"status":"completed"}
            """
        }.joined(separator: ",")
        return #"{"type":"session_meta","field":"turnMetrics","value":[\#(entries)],"updatedAt":0}"#
    }

    private func turnMetricsLine(turns: [[String: Any]]) -> String {
        let entries = turns.map { dict in
            (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }.joined(separator: ",")
        return #"{"type":"session_meta","field":"turnMetrics","value":[\#(entries)],"updatedAt":0}"#
    }

    private func turnDict(id: String, startedAt: Date, prompt: Int, completion: Int, cached: Int, cacheWrite: Int, reactLoops: Int) -> [String: Any] {
        [
            "turnId": id,
            "startedAt": epochMs(startedAt),
            "completedAt": epochMs(startedAt) + 60_000,
            "modelId": "m",
            "promptTokens": prompt,
            "completionTokens": completion,
            "cachedTokens": cached,
            "cacheWriteTokens": cacheWrite,
            "reactLoopCount": reactLoops,
            "status": "completed",
        ]
    }

    private var calendar: Calendar { Calendar.current }

    /// Wednesday noon of the current week — unambiguously inside the week and
    /// on today's date regardless of when the test runs.
    private var wednesdayNoon: Date {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today)!
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: monday.addingTimeInterval(2 * 86_400))!
    }

    func testWeekStartIsAlwaysMonday() {
        // Walk a full week from a known Wednesday; every day must map back to
        // the same Monday 00:00 regardless of the user's firstWeekday setting.
        let wednesday = wednesdayNoon
        let monday = PandaUsageScanner.weekStart(for: wednesday)
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2) // Monday
        XCTAssertEqual(monday, calendar.startOfDay(for: monday))

        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: monday)!
            XCTAssertEqual(PandaUsageScanner.weekStart(for: day), monday,
                           "day +\(offset) of the week must map back to the same Monday")
        }
        // The day before Monday belongs to the previous week.
        let sunday = calendar.date(byAdding: .day, value: -1, to: monday)!
        XCTAssertEqual(PandaUsageScanner.weekStart(for: sunday),
                       calendar.date(byAdding: .day, value: -7, to: monday)!)
    }

    func testParseTurnMetricsLine() {
        let line = turnMetricsLine(turns: [
            (id: "t1", startedAt: wednesdayNoon, prompt: 10, completion: 20, cached: 100, cacheWrite: 5),
        ])
        let parsed = PandaUsageScanner.parseTurnMetrics(line)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.turnId, "t1")
        XCTAssertEqual(parsed.first?.usage.inputTokens, 10)
        XCTAssertEqual(parsed.first?.usage.outputTokens, 20)
        XCTAssertEqual(parsed.first?.usage.cacheReadTokens, 100)
        XCTAssertEqual(parsed.first?.usage.cacheCreationTokens, 5)
        XCTAssertEqual(parsed.first?.modelName, "m") // test fixture writes modelId:"m"

        XCTAssertTrue(PandaUsageScanner.parseTurnMetrics(#"{"type":"message"}"#).isEmpty)
        XCTAssertTrue(PandaUsageScanner.parseTurnMetrics("not json").isEmpty)
    }

    func testScanAggregatesWeekAndDedupesOnTurnId() throws {
        let now = wednesdayNoon
        let monday = PandaUsageScanner.weekStart(for: now)
        let path = home + "/projects/p1/sessions/s.jsonl"
        // Panda re-emits a FULL snapshot per line: turn t1 appears on three
        // lines (its counts settle only on the last), then an older turn from
        // earlier in the SAME week (Tuesday).
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        let lines = [
            turnMetricsLine(turns: [(id: "t1", startedAt: now.addingTimeInterval(-3600), prompt: 1, completion: 1, cached: 0, cacheWrite: 0)]),
            turnMetricsLine(turns: [(id: "t1", startedAt: now.addingTimeInterval(-3600), prompt: 50, completion: 5, cached: 0, cacheWrite: 0)]),
            turnMetricsLine(turns: [
                (id: "t1", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0),
                (id: "t2", startedAt: tuesday, prompt: 1000, completion: 50, cached: 0, cacheWrite: 0),
            ]),
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now)

        // t1 counted ONCE with the LAST snapshot's values, not 3×.
        XCTAssertEqual(snap.thisWeek.inputTokens, 1100)
        XCTAssertEqual(snap.thisWeek.outputTokens, 60)
        XCTAssertEqual(snap.thisWeek.messageCount, 2)
        XCTAssertEqual(snap.weekStart, monday)

        // Daily buckets: Wednesday (index 2) = t1's 10 out; Tuesday (1) = 50.
        XCTAssertEqual(snap.dailyOutputTokens[2], 10)
        XCTAssertEqual(snap.dailyOutputTokens[1], 50)
        XCTAssertEqual(snap.dailyOutputTokens.reduce(0, +), 60)
    }

    func testScanExcludesLastWeeksTurns() throws {
        let now = wednesdayNoon
        let monday = PandaUsageScanner.weekStart(for: now)
        let lastWeek = calendar.date(byAdding: .day, value: -3, to: monday)! // Friday last week
        let path = home + "/projects/p1/sessions/s.jsonl"
        try (turnMetricsLine(turns: [
            (id: "old", startedAt: lastWeek, prompt: 5000, completion: 900, cached: 0, cacheWrite: 0),
            (id: "new", startedAt: now.addingTimeInterval(-600), prompt: 10, completion: 2, cached: 0, cacheWrite: 0),
        ]) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now)
        XCTAssertEqual(snap.thisWeek.inputTokens, 10)
        XCTAssertEqual(snap.thisWeek.messageCount, 1)
    }

    func testIncrementalScanReadsOnlyAppendedBytes() throws {
        let now = wednesdayNoon
        let path = home + "/projects/p1/sessions/s.jsonl"
        try (turnMetricsLine(turns: [(id: "a", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0)]) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = PandaUsageScanner.FileCache()
        let first = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)
        XCTAssertEqual(first.thisWeek.inputTokens, 100)
        let consumedAfterFirst = try XCTUnwrap(cache.files[path]?.consumedBytes)
        XCTAssertGreaterThan(consumedAfterFirst, 0)

        // Append a snapshot with a second turn; rescan must read only new bytes.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((turnMetricsLine(turns: [
            (id: "a", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0),
            (id: "b", startedAt: now.addingTimeInterval(-1800), prompt: 7, completion: 3, cached: 0, cacheWrite: 0),
        ]) + "\n").utf8))
        handle.closeFile()

        let second = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)
        XCTAssertEqual(second.thisWeek.inputTokens, 107)
        XCTAssertEqual(second.thisWeek.messageCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(cache.files[path]?.consumedBytes), consumedAfterFirst)
    }

    func testIncrementalScanIgnoresPartialTrailingLine() throws {
        let now = wednesdayNoon
        let path = home + "/projects/p1/sessions/s.jsonl"
        let full = turnMetricsLine(turns: [(id: "a", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0)]) + "\n"
        let partial = #"{"type":"session_meta","field":"turnMe"#
        try (full + partial).write(toFile: path, atomically: true, encoding: .utf8)

        var cache = PandaUsageScanner.FileCache()
        let snap = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)
        XCTAssertEqual(snap.thisWeek.messageCount, 1)
        XCTAssertEqual(cache.files[path]?.consumedBytes, UInt64(full.utf8.count))
    }

    func testTruncatedFileIsRescannedFromStart() throws {
        let now = wednesdayNoon
        let path = home + "/projects/p1/sessions/s.jsonl"
        try (turnMetricsLine(turns: [(id: "a", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0)]) + "\n"
             + turnMetricsLine(turns: [(id: "b", startedAt: now.addingTimeInterval(-1800), prompt: 50, completion: 5, cached: 0, cacheWrite: 0)]) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = PandaUsageScanner.FileCache()
        _ = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)

        try (turnMetricsLine(turns: [(id: "c", startedAt: now.addingTimeInterval(-600), prompt: 1, completion: 2, cached: 0, cacheWrite: 0)]) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)
        XCTAssertEqual(snap.thisWeek.inputTokens, 1)
        XCTAssertEqual(snap.thisWeek.messageCount, 1)
    }

    func testScanReportsLiveContextOfNewestTurn() throws {
        let now = wednesdayNoon
        let path = home + "/projects/p1/sessions/s.jsonl"
        // t2 started last — its per-request footprint (prompt+cache summed
        // across the turn's LLM rounds, divided by the round count) is the
        // live context, regardless of the older turns.
        try (turnMetricsLine(turns: [
            turnDict(id: "t1", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 900, cacheWrite: 5, reactLoops: 3),
            turnDict(id: "t2", startedAt: now.addingTimeInterval(-60), prompt: 1_200, completion: 30, cached: 12_000, cacheWrite: 40, reactLoops: 4),
        ]) + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now)
        let live = try XCTUnwrap(snap.liveContext)
        // (1_200 + 12_000 + 40) accumulated across 4 rounds → 3_310 per request.
        XCTAssertEqual(live.contextTokens, 3_310)
        XCTAssertEqual(live.modelName, "m")
        XCTAssertEqual(live.updatedAt, now.addingTimeInterval(-60))
    }

    func testLiveContextPicksNewestAcrossFiles() throws {
        let now = wednesdayNoon
        try FileManager.default.createDirectory(
            atPath: home + "/projects/p2/sessions", withIntermediateDirectories: true)
        try (turnMetricsLine(turns: [
            (id: "a", startedAt: now.addingTimeInterval(-1200), prompt: 500, completion: 1, cached: 0, cacheWrite: 0),
        ]) + "\n").write(toFile: home + "/projects/p1/sessions/s.jsonl", atomically: true, encoding: .utf8)
        try (turnMetricsLine(turns: [
            (id: "b", startedAt: now.addingTimeInterval(-300), prompt: 700, completion: 1, cached: 50, cacheWrite: 0),
        ]) + "\n").write(toFile: home + "/projects/p2/sessions/other.jsonl", atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now)
        // Both fixtures use reactLoopCount=1 → sums pass through.
        XCTAssertEqual(snap.liveContext?.contextTokens, 750)
    }

    func testLiveContextReadsModelNameOverModelId() throws {
        let now = wednesdayNoon
        let path = home + "/projects/p1/sessions/s.jsonl"
        let line = #"{"type":"session_meta","field":"turnMetrics","value":[{"turnId":"t9","startedAt":\#(epochMs(now.addingTimeInterval(-120))),"completedAt":\#(epochMs(now)),"modelId":"gw-raw","modelName":"qwen3.7-plus","promptTokens":500,"completionTokens":1,"cachedTokens":100,"cacheWriteTokens":0,"reactLoopCount":2,"status":"completed"}],"updatedAt":0}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now)
        XCTAssertEqual(snap.liveContext?.modelName, "qwen3.7-plus")
        // (500 + 100 + 0) / 2 rounds = 300.
        XCTAssertEqual(snap.liveContext?.contextTokens, 300)
    }

    func testLiveContextFallsBackToFullSumWithoutRounds() throws {
        let now = wednesdayNoon
        let path = home + "/projects/p1/sessions/s.jsonl"
        // Missing/zero reactLoopCount must not zero out the estimate.
        let line = #"{"type":"session_meta","field":"turnMetrics","value":[{"turnId":"tz","startedAt":\#(epochMs(now.addingTimeInterval(-60))),"completedAt":\#(epochMs(now)),"promptTokens":480,"completionTokens":20,"cachedTokens":0,"cacheWriteTokens":0,"status":"completed"}],"updatedAt":0}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now)
        XCTAssertEqual(snap.liveContext?.contextTokens, 480)
    }

    func testScanEmptyHome() {
        let snap = PandaUsageScanner.scan(pandaHome: home + "/nonexistent", now: wednesdayNoon)
        XCTAssertTrue(snap.thisWeek.isEmpty)
        XCTAssertEqual(snap.dailyOutputTokens, [Int](repeating: 0, count: PandaUsageScanner.daysPerWeek))
    }
}
