import XCTest
import CodeIslandCore
@testable import CodeIsland

final class SessionTitleStoreTests: XCTestCase {
    func testCodexThreadNameLookupReturnsLatestMatchingTitle() throws {
        let lines = [
            #"{"id":"019d6330-beed-7a13-b61e-cacf03d3cefe","thread_name":"Old title","updated_at":"2026-04-06T14:20:00Z"}"#,
            #"{"id":"019d6330-beed-7a13-b61e-cacf03d3cefe","thread_name":"充分探索项目找到通用问题","updated_at":"2026-04-06T14:28:21Z"}"#
        ].joined(separator: "\n")

        let title = try SessionTitleStore.codexThreadName(
            sessionId: "019d6330-beed-7a13-b61e-cacf03d3cefe",
            indexContents: lines
        )

        XCTAssertEqual(title, "充分探索项目找到通用问题")
    }

    func testCodexThreadNameLookupIgnoresBlankTitlesAndBadLines() throws {
        let lines = [
            #"{"id":"019d6331-3593-7b53-9513-c1dd25d708b0","thread_name":"","updated_at":"2026-04-06T14:28:38Z"}"#,
            "not-json"
        ].joined(separator: "\n")

        let title = try SessionTitleStore.codexThreadName(
            sessionId: "019d6331-3593-7b53-9513-c1dd25d708b0",
            indexContents: lines
        )

        XCTAssertNil(title)
    }

    // MARK: - Panda session titles

    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "panda-title-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home + "/desktop/projects/proj/sessions", withIntermediateDirectories: true)
        SessionTitleStore.resetPandaTitleCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        SessionTitleStore.resetPandaTitleCache()
        super.tearDown()
    }

    private func writeTranscript(_ lines: [String], sessionId: String = "s1") throws {
        try lines.joined(separator: "\n").appending("\n")
            .write(toFile: home + "/desktop/projects/proj/sessions/\(sessionId).jsonl",
                   atomically: true, encoding: .utf8)
    }

    private func appendToTranscript(_ line: String, sessionId: String = "s1") throws {
        let data = (line + "\n").data(using: .utf8)!
        let url = URL(fileURLWithPath: home + "/desktop/projects/proj/sessions/\(sessionId).jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { handle.closeFile() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    func testPandaTitleFallsBackToHeadDefaultTitle() throws {
        try writeTranscript([
            #"{"type":"session","conversationId":"s1","title":"对话 9/15/2026, 2:35:10 PM"}"#,
            #"{"type":"message","role":"user"}"#,
        ])

        let resolved = SessionTitleStore.pandaTitle(sessionId: "s1", pandaHome: home)

        XCTAssertEqual(resolved?.title, "对话 9/15/2026, 2:35:10 PM")
        XCTAssertEqual(resolved?.source, .pandaSessionTitle)
    }

    func testPandaTitlePrefersLatestSessionMetaTitle() throws {
        try writeTranscript([
            #"{"type":"session","conversationId":"s1","title":"对话 9/15/2026, 2:35:10 PM"}"#,
            #"{"type":"session_meta","field":"title","value":"@页面截图v1 中的图片为当前渝慧学…","updatedAt":1}"#,
            #"{"type":"session_meta","field":"turnRanges","value":[],"updatedAt":2}"#,
            #"{"type":"session_meta","field":"title","value":"渝慧学UI优化","updatedAt":3}"#,
        ])

        let resolved = SessionTitleStore.pandaTitle(sessionId: "s1", pandaHome: home)

        XCTAssertEqual(resolved?.title, "渝慧学UI优化")
    }

    /// A rename can land deep in a multi-megabyte transcript, far past the
    /// head window — the scan must reach it.
    func testPandaTitleFindsRenameBeyondTheHeadWindow() throws {
        let filler = String(repeating: #"{"type":"message","role":"user","content":"filler"}"#, count: 2000)
        try writeTranscript([
            #"{"type":"session","conversationId":"s1","title":"对话 9/15/2026, 2:35:10 PM"}"#,
            filler,
            #"{"type":"session_meta","field":"title","value":"渝慧学UI优化","updatedAt":3}"#,
        ])

        let resolved = SessionTitleStore.pandaTitle(sessionId: "s1", pandaHome: home)

        XCTAssertEqual(resolved?.title, "渝慧学UI优化")
    }

    /// Renames land at the file's growing end while the app runs — a second
    /// look must pick up only the appended bytes (incremental cache).
    func testPandaTitlePicksUpRenameAppendedAfterFirstLook() throws {
        try writeTranscript([
            #"{"type":"session","conversationId":"s1","title":"对话 9/15/2026, 2:35:10 PM"}"#,
            #"{"type":"session_meta","field":"title","value":"自动标题","updatedAt":1}"#,
        ])
        XCTAssertEqual(SessionTitleStore.pandaTitle(sessionId: "s1", pandaHome: home)?.title, "自动标题")

        try appendToTranscript(#"{"type":"session_meta","field":"title","value":"渝慧学UI优化","updatedAt":2}"#)

        XCTAssertEqual(SessionTitleStore.pandaTitle(sessionId: "s1", pandaHome: home)?.title, "渝慧学UI优化")
    }

    func testPandaTitleIgnoresMarkerInsideAMessageLine() throws {
        try writeTranscript([
            #"{"type":"session","conversationId":"s1","title":"对话 9/15/2026, 2:35:10 PM"}"#,
            #"{"type":"message","role":"user","content":"讨论一下 {\"field\":\"title\",\"value\":\"假标题\"} 这个字段"}"#,
        ])

        let resolved = SessionTitleStore.pandaTitle(sessionId: "s1", pandaHome: home)

        XCTAssertEqual(resolved?.title, "对话 9/15/2026, 2:35:10 PM")
    }

    func testPandaTitleIgnoresBlankMetaTitleValues() throws {
        try writeTranscript([
            #"{"type":"session","conversationId":"s1","title":"对话 9/15/2026, 2:35:10 PM"}"#,
            #"{"type":"session_meta","field":"title","value":"  ","updatedAt":1}"#,
        ])

        let resolved = SessionTitleStore.pandaTitle(sessionId: "s1", pandaHome: home)

        XCTAssertEqual(resolved?.title, "对话 9/15/2026, 2:35:10 PM")
    }

    func testPandaTitleReturnsNilForUnknownSession() throws {
        try writeTranscript([
            #"{"type":"session","conversationId":"s1","title":"对话 9/15/2026, 2:35:10 PM"}"#,
        ])

        XCTAssertNil(SessionTitleStore.pandaTitle(sessionId: "nope", pandaHome: home))
    }
}
