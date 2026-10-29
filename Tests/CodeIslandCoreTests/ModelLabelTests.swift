import XCTest
@testable import CodeIslandCore

final class ModelLabelTests: XCTestCase {

    // MARK: - displayName: Claude ids

    func testClaudeFamilyFirstIdsBecomeFriendlyNames() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5"), "Opus 5")
    }

    func testLongContextSuffixAppends1M() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5[1m]"), "Opus 5.5 1M")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-sonnet-5[1M]"), "Sonnet 5 1M")
        XCTAssertEqual(ModelLabel.displayName(for: "opus[1m]"), "Opus 1M")
    }

    func testLegacyVersionFirstClaudeIds() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-3-opus-20240229"), "Opus 3")
    }

    func testClaudeAliasesAreCapitalized() {
        XCTAssertEqual(ModelLabel.displayName(for: "opus"), "Opus")
        XCTAssertEqual(ModelLabel.displayName(for: "sonnet"), "Sonnet")
    }

    func testProviderRoutingDecorationIsStripped() {
        XCTAssertEqual(ModelLabel.displayName(for: "anthropic/claude-sonnet-4"), "Sonnet 4")
        XCTAssertEqual(
            ModelLabel.displayName(for: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            "Sonnet 4.5"
        )
        XCTAssertEqual(ModelLabel.displayName(for: "claude-sonnet-4-5@20250929"), "Sonnet 4.5")
    }

    // MARK: - displayName: everything else

    func testNonClaudeIdsKeepTheirSpellingMinusDates() {
        XCTAssertEqual(ModelLabel.displayName(for: "gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(ModelLabel.displayName(for: "gpt-6-astra"), "gpt-6-astra")
        XCTAssertEqual(ModelLabel.displayName(for: "gpt-4o-2024-08-06"), "gpt-4o")
        XCTAssertEqual(ModelLabel.displayName(for: "some-model-20250514"), "some-model")
        XCTAssertEqual(ModelLabel.displayName(for: "github-copilot/gpt-5.4"), "gpt-5.4")
    }

    func testNamesThatMerelyEndInAVersionAreNotMangled() {
        XCTAssertEqual(ModelLabel.displayName(for: "deepseek-v3"), "deepseek-v3")
        XCTAssertEqual(ModelLabel.displayName(for: "gemini-2.5-pro-preview-05-06"), "gemini-2.5-pro-preview-05-06")
        XCTAssertEqual(ModelLabel.displayName(for: "kimi-k2"), "kimi-k2")
    }

    func testUnderscoreProviderPrefixesAreStripped() {
        // Panda's provider tags: every model of one provider shares them, so
        // on a narrow chip they are all the user would ever see.
        XCTAssertEqual(ModelLabel.displayName(for: "ecloud_glm-5.3-n"), "glm-5.3-n")
        XCTAssertEqual(ModelLabel.displayName(for: "yzt_qwen3.7-plus"), "qwen3.7-plus")
        XCTAssertEqual(ModelLabel.displayName(for: "ecloud_zhipu_glm-5.3"), "glm-5.3")
        XCTAssertEqual(ModelLabel.displayName(for: "ecloud/zhipu/glm-5.3-flash"), "glm-5.3-flash")
        XCTAssertEqual(ModelLabel.displayName(for: "meta_llama-3.3-70b"), "llama-3.3-70b")
        XCTAssertEqual(ModelLabel.label(model: "ecloud_glm-5.3-n", effort: nil), "glm-5.3-n")
    }

    func testPandaDesktopUINamesPassThroughUnchanged() {
        // turnMetrics reports the model as the desktop picker spells it —
        // provider tag suffix and custom display names included. None of the
        // id-shaping rules may touch them.
        XCTAssertEqual(ModelLabel.displayName(for: "glm-5.3-flash(ecloud)"), "glm-5.3-flash(ecloud)")
        XCTAssertEqual(ModelLabel.displayName(for: "glm-5.3(ecloud)"), "glm-5.3(ecloud)")
        XCTAssertEqual(ModelLabel.displayName(for: "deepseek-v4-flash(ecloud)"), "deepseek-v4-flash(ecloud)")
        XCTAssertEqual(ModelLabel.displayName(for: "FX-DeepSeek"), "FX-DeepSeek")
        XCTAssertEqual(ModelLabel.label(model: "FX-DeepSeek", effort: nil), "FX-DeepSeek")
    }

    func testUnderscoreNamesThatAreNotRoutesKeepTheirSpelling() {
        XCTAssertEqual(ModelLabel.displayName(for: "mistral_large"), "mistral_large")
        XCTAssertEqual(ModelLabel.displayName(for: "gpt_4o"), "gpt_4o")
        XCTAssertEqual(ModelLabel.displayName(for: "some_model"), "some_model")
    }

    func testMMDDSnapshotStampsAreStripped() {
        XCTAssertEqual(ModelLabel.displayName(for: "yzt_deepseek-v4-flash-0731"), "deepseek-v4-flash")
        // Not trailing, so not a stamp.
        XCTAssertEqual(ModelLabel.displayName(for: "kimi-k2-0905-preview"), "kimi-k2-0905-preview")
    }

    func testUnknownClaudeShapesFallBackToTheRawId() {
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5-thinking"), "claude-opus-5-5-thinking")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-2.1"), "claude-2.1")
        XCTAssertEqual(ModelLabel.displayName(for: "claude-opus-5-5-1-2"), "claude-opus-5-5-1-2")
    }

    func testEmptyAndPlaceholderIdsHaveNoName() {
        XCTAssertNil(ModelLabel.displayName(for: nil))
        XCTAssertNil(ModelLabel.displayName(for: ""))
        XCTAssertNil(ModelLabel.displayName(for: "   "))
        XCTAssertNil(ModelLabel.displayName(for: "<synthetic>"))
    }

    // MARK: - label

    func testLabelAppendsNormalizedEffort() {
        XCTAssertEqual(ModelLabel.label(model: "claude-opus-5-5", effort: "xhigh"), "Opus 5.5 · xhigh")
        XCTAssertEqual(ModelLabel.label(model: "gpt-5.6-sol", effort: " MAX "), "gpt-5.6-sol · max")
        XCTAssertEqual(ModelLabel.label(model: "claude-opus-5-5[1m]", effort: "high"), "Opus 5.5 1M · high")
    }

    func testLabelWithoutEffortIsJustTheName() {
        XCTAssertEqual(ModelLabel.label(model: "claude-sonnet-5", effort: nil), "Sonnet 5")
        XCTAssertEqual(ModelLabel.label(model: "claude-sonnet-5", effort: "  "), "Sonnet 5")
    }

    func testEffortAloneProducesNoLabel() {
        XCTAssertNil(ModelLabel.label(model: nil, effort: "xhigh"))
    }

    // MARK: - mergedModelId

    func testTranscriptIdDoesNotStripTheConfiguredContextVariant() {
        XCTAssertEqual(
            ModelLabel.mergedModelId(current: "claude-opus-5-5[1m]", observed: "claude-opus-5-5"),
            "claude-opus-5-5[1m]"
        )
    }

    func testARealModelSwitchReplacesTheCurrentId() {
        XCTAssertEqual(
            ModelLabel.mergedModelId(current: "claude-opus-5-5[1m]", observed: "claude-sonnet-5"),
            "claude-sonnet-5"
        )
        XCTAssertEqual(ModelLabel.mergedModelId(current: "opus", observed: "claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(ModelLabel.mergedModelId(current: nil, observed: "gpt-5.6-sol"), "gpt-5.6-sol")
    }

    // MARK: - ModelObservation

    func testObservationRejectsPlaceholdersAndNormalizesEffort() {
        XCTAssertNil(ModelObservation.from(model: "<synthetic>", effort: "xhigh"))
        XCTAssertNil(ModelObservation.from(model: nil, effort: "xhigh"))
        XCTAssertNil(ModelObservation.from(model: 42, effort: nil))
        XCTAssertEqual(
            ModelObservation.from(model: " claude-opus-5-5 ", effort: "XHigh"),
            ModelObservation(model: "claude-opus-5-5", effort: "xhigh")
        )
    }

    func testLatestInClaudeTranscriptReadsSidechainLinesNewestFirst() {
        let lines = [
            #"{"isSidechain":true,"type":"user","message":{"role":"user","content":"find the bug"}}"#,
            #"{"isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","role":"assistant","content":[{"type":"text","text":"a"}]},"type":"assistant","effort":"low"}"#,
            #"{"isSidechain":true,"message":{"model":"claude-sonnet-5","role":"assistant","content":[{"type":"text","text":"b"}]},"type":"assistant","effort":"high"}"#,
            #"{"isSidechain":true,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error"}]},"type":"assistant"}"#,
        ].joined(separator: "\n")

        XCTAssertEqual(
            ModelObservation.latestInClaudeTranscript(Data(lines.utf8)),
            ModelObservation(model: "claude-sonnet-5", effort: "high")
        )
        XCTAssertNil(ModelObservation.latestInClaudeTranscript(Data()))
    }

    func testObservationKeepsTheLinesTimestampWithoutChangingEquality() {
        let timed = ModelObservation.from(model: "gpt-5.6-sol", effort: "max", timestamp: "2026-09-24T09:05:19.777Z")
        XCTAssertEqual(timed?.observedAt, ClaudeUsageScanner.parseISO8601("2026-09-24T09:05:19.777Z"))
        XCTAssertEqual(timed, ModelObservation(model: "gpt-5.6-sol", effort: "max"))
        XCTAssertNil(ModelObservation.from(model: "gpt-5.6-sol", effort: nil, timestamp: "t")?.observedAt)
    }

    // MARK: - Panda turnMetrics back-search

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func pandaMetricsLine(modelName: String, modelId: String) -> String {
        let payload: [String: Any] = [
            "type": "session_meta", "field": "turnMetrics",
            "value": [["turnId": UUID().uuidString, "modelId": modelId, "modelName": modelName, "status": "completed"]],
        ]
        return jsonString(payload)
    }

    private func writeTranscript(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-panda-search-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testLatestPandaTurnMetricsFindsTheNewestRowBeyondTheTailWindow() throws {
        let filler = jsonString([
            "type": "assistant", "message": ["content": [["type": "text", "text": String(repeating: "x", count: 300_000)]]],
        ])
        let path = try writeTranscript([
            pandaMetricsLine(modelName: "qwen3.7-plus", modelId: "yzt_qwen3.7-plus"),
            filler,
            pandaMetricsLine(modelName: "glm-5.3-flash(ecloud)", modelId: "ecloud_glm-5.3-n"),
        ])
        XCTAssertEqual(
            ModelObservation.latestPandaTurnMetrics(path: path)?.model,
            "glm-5.3-flash(ecloud)",
            "the newest completed turn wins, even 300 KB above the attach window"
        )
    }

    func testLatestPandaTurnMetricsHonoursTheEndOffsetAndTheSearchBound() throws {
        let first = pandaMetricsLine(modelName: "qwen3.7-plus", modelId: "yzt_qwen3.7-plus")
        let second = pandaMetricsLine(modelName: "glm-5.3-flash(ecloud)", modelId: "ecloud_glm-5.3-n")
        let head = (first + "\n").utf8.count
        let path = try writeTranscript([first, second])

        XCTAssertEqual(
            ModelObservation.latestPandaTurnMetrics(path: path, endOffset: UInt64(head))?.model,
            "qwen3.7-plus",
            "bytes past the tailer's start offset are the tailer's"
        )
        XCTAssertNil(
            ModelObservation.latestPandaTurnMetrics(path: path, maxBytes: 10),
            "the search stops at its bound"
        )
        XCTAssertNil(ModelObservation.latestPandaTurnMetrics(path: path + ".missing"))
    }

    func testLatestPandaTurnMetricsHandlesRowSpanningChunkBoundaries() throws {
        // A cumulative row grows with the turn count: make one wide enough to
        // straddle several small chunks and keep the back-search correct.
        let turns: [[String: Any]] = (0..<600).map {
            ["turnId": "t\($0)", "modelId": "ecloud_glm-5.3", "modelName": "glm-5.3(ecloud)", "status": "completed"]
        }
        let wide = jsonString(["type": "session_meta", "field": "turnMetrics", "value": turns])
        let path = try writeTranscript([wide])
        XCTAssertEqual(
            ModelObservation.latestPandaTurnMetrics(path: path, chunkSize: 16 * 1024)?.model,
            "glm-5.3(ecloud)"
        )
    }

    // MARK: - Codex turn_context search

    private func turnContext(effort: String, turn: String) -> String {
        #"{"timestamp":"2026-09-24T09:05:19.777Z","ordinal":1,"type":"turn_context","payload":{"turn_id":"\#(turn)","cwd":"/repo","model":"gpt-5.6-sol","effort":"\#(effort)","summary":"auto"}}"#
    }

    private func toolOutput(_ bytes: Int) -> String {
        #"{"timestamp":"2026-09-24T09:05:20.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"\#(String(repeating: "o", count: bytes))"}}"#
    }

    private func writeRollout(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-turn-context-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testLatestCodexTurnContextSearchesBackPastTheTailWindow() throws {
        let path = try writeRollout(
            [turnContext(effort: "low", turn: "t1"), turnContext(effort: "max", turn: "t2")]
                + Array(repeating: toolOutput(3_000), count: 60)
        )
        // Small chunks, so the row straddles chunk boundaries on the way back.
        let found = ModelObservation.latestCodexTurnContext(path: path, chunkSize: 1_000)
        XCTAssertEqual(found, ModelObservation(model: "gpt-5.6-sol", effort: "max"))
        XCTAssertNotNil(found?.observedAt)
        XCTAssertEqual(ModelObservation.latestCodexTurnContext(path: path), found)
    }

    func testLatestCodexTurnContextHonoursTheEndOffsetAndTheSearchBound() throws {
        let head = [turnContext(effort: "low", turn: "t1"), toolOutput(500)].joined(separator: "\n") + "\n"
        let path = try writeRollout([
            turnContext(effort: "low", turn: "t1"), toolOutput(500),
            turnContext(effort: "max", turn: "t2"), toolOutput(20_000),
        ])
        XCTAssertEqual(
            ModelObservation.latestCodexTurnContext(path: path, endOffset: UInt64(head.utf8.count), chunkSize: 256)?.effort,
            "low",
            "rows past the tailer's start offset are the tailer's"
        )
        XCTAssertNil(
            ModelObservation.latestCodexTurnContext(path: path, maxBytes: 10_000, chunkSize: 4_096),
            "the search stops at its bound"
        )
        XCTAssertNil(ModelObservation.latestCodexTurnContext(path: path + ".missing"))
    }
}
