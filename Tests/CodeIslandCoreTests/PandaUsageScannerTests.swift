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
            {"turnId":"\(t.id)","startedAt":\(epochMs(t.startedAt)),"completedAt":\(epochMs(t.startedAt) + 60_000),"modelId":"m","promptTokens":\(t.prompt),"completionTokens":\(t.completion),"totalTokens":\(t.prompt + t.completion),"cachedTokens":\(t.cached),"cacheWriteTokens":\(t.cacheWrite),"status":"completed"}
            """
        }.joined(separator: ",")
        return #"{"type":"session_meta","field":"turnMetrics","value":[\#(entries)],"updatedAt":0}"#
    }

    /// Noon local time keeps "1h ago" and "8h ago" unambiguously on today's
    /// date regardless of when the test runs.
    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func testParseTurnMetricsLine() {
        let line = turnMetricsLine(turns: [
            (id: "t1", startedAt: noon, prompt: 10, completion: 20, cached: 100, cacheWrite: 5),
        ])
        let parsed = PandaUsageScanner.parseTurnMetrics(line)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.turnId, "t1")
        XCTAssertEqual(parsed.first?.usage.inputTokens, 10)
        XCTAssertEqual(parsed.first?.usage.outputTokens, 20)
        XCTAssertEqual(parsed.first?.usage.cacheReadTokens, 100)
        XCTAssertEqual(parsed.first?.usage.cacheCreationTokens, 5)

        XCTAssertTrue(PandaUsageScanner.parseTurnMetrics(#"{"type":"message"}"#).isEmpty)
        XCTAssertTrue(PandaUsageScanner.parseTurnMetrics("not json").isEmpty)
    }

    func testScanAggregatesWindowsAndDedupesOnTurnId() throws {
        let now = noon
        let path = home + "/projects/p1/sessions/s.jsonl"
        // Panda re-emits a FULL snapshot per line: turn t1 appears on three
        // lines (its counts settle only on the last), then an older turn.
        let lines = [
            turnMetricsLine(turns: [(id: "t1", startedAt: now.addingTimeInterval(-3600), prompt: 1, completion: 1, cached: 0, cacheWrite: 0)]),
            turnMetricsLine(turns: [(id: "t1", startedAt: now.addingTimeInterval(-3600), prompt: 50, completion: 5, cached: 0, cacheWrite: 0)]),
            turnMetricsLine(turns: [
                (id: "t1", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0),
                (id: "t2", startedAt: now.addingTimeInterval(-8 * 3600), prompt: 1000, completion: 50, cached: 0, cacheWrite: 0),
            ]),
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now)

        // t1 counted ONCE with the LAST snapshot's values, not 3×.
        XCTAssertEqual(snap.last5h.inputTokens, 100)
        XCTAssertEqual(snap.last5h.outputTokens, 10)
        XCTAssertEqual(snap.last5h.messageCount, 1)
        // t2 is today but outside the 5h window.
        XCTAssertEqual(snap.today.inputTokens, 1100)
        XCTAssertEqual(snap.today.outputTokens, 60)
        XCTAssertEqual(snap.today.messageCount, 2)

        let last = PandaUsageScanner.sparklineHours - 1
        XCTAssertEqual(snap.hourlyOutputTokens[last - 1], 10)
        XCTAssertEqual(snap.hourlyOutputTokens[last - 8], 50)
        XCTAssertEqual(snap.hourlyOutputTokens.reduce(0, +), 60)
    }

    func testIncrementalScanReadsOnlyAppendedBytes() throws {
        let now = noon
        let path = home + "/projects/p1/sessions/s.jsonl"
        try (turnMetricsLine(turns: [(id: "a", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0)]) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = PandaUsageScanner.FileCache()
        let first = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)
        XCTAssertEqual(first.last5h.inputTokens, 100)
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
        XCTAssertEqual(second.last5h.inputTokens, 107)
        XCTAssertEqual(second.last5h.messageCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(cache.files[path]?.consumedBytes), consumedAfterFirst)
    }

    func testIncrementalScanIgnoresPartialTrailingLine() throws {
        let now = noon
        let path = home + "/projects/p1/sessions/s.jsonl"
        let full = turnMetricsLine(turns: [(id: "a", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0)]) + "\n"
        let partial = #"{"type":"session_meta","field":"turnMe"#
        try (full + partial).write(toFile: path, atomically: true, encoding: .utf8)

        var cache = PandaUsageScanner.FileCache()
        let snap = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)
        XCTAssertEqual(snap.last5h.messageCount, 1)
        XCTAssertEqual(cache.files[path]?.consumedBytes, UInt64(full.utf8.count))
    }

    func testTruncatedFileIsRescannedFromStart() throws {
        let now = noon
        let path = home + "/projects/p1/sessions/s.jsonl"
        try (turnMetricsLine(turns: [(id: "a", startedAt: now.addingTimeInterval(-3600), prompt: 100, completion: 10, cached: 0, cacheWrite: 0)]) + "\n"
             + turnMetricsLine(turns: [(id: "b", startedAt: now.addingTimeInterval(-1800), prompt: 50, completion: 5, cached: 0, cacheWrite: 0)]) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = PandaUsageScanner.FileCache()
        _ = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)

        try (turnMetricsLine(turns: [(id: "c", startedAt: now.addingTimeInterval(-600), prompt: 1, completion: 2, cached: 0, cacheWrite: 0)]) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let snap = PandaUsageScanner.scan(pandaHome: home, now: now, cache: &cache)
        XCTAssertEqual(snap.last5h.inputTokens, 1)
        XCTAssertEqual(snap.last5h.messageCount, 1)
    }

    func testScanEmptyHome() {
        let snap = PandaUsageScanner.scan(pandaHome: home + "/nonexistent", now: noon)
        XCTAssertTrue(snap.last5h.isEmpty)
        XCTAssertTrue(snap.today.isEmpty)
    }
}
