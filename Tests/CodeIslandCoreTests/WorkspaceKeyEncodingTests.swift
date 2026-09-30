import XCTest
@testable import CodeIslandCore

/// Panda's workspace-key encoding must match what Panda itself writes to
/// `state_kv`, or per-workspace model detection silently never matches
/// (verified against real db keys: slashes become `-`, non-ASCII stays
/// percent-encoded).
final class WorkspaceKeyEncodingTests: XCTestCase {
    func testPlainASCIIPath() {
        XCTAssertEqual(
            PandaTokenProvider.encodeWorkspaceKey("/Users/kenshin/project/CodeIsland"),
            "-Users-kenshin-project-CodeIsland"
        )
    }

    func testNonASCIIStaysPercentEncoded() {
        // 中移（成都）产业研究院 → %E4%B8%AD%E7%A7%BB%EF%BC%88%E6%88%90%E9%83%BD%EF%BC%89%E4%BA%A7%E4%B8%9A%E7%A0%94%E7%A9%B6%E9%99%A2
        let encoded = PandaTokenProvider.encodeWorkspaceKey(
            "/Users/kenshin/中移（成都）产业研究院/project/Superisland"
        )
        XCTAssertEqual(
            encoded,
            "-Users-kenshin-%E4%B8%AD%E7%A7%BB%EF%BC%88%E6%88%90%E9%83%BD%EF%BC%89%E4%BA%A7%E4%B8%9A%E7%A0%94%E7%A9%B6%E9%99%A2-project-Superisland"
        )
    }

    func testNoPercentEncodedSlashesRemain() {
        // A plain percent-encoding would emit %2F separators — the exact bug
        // that disabled workspace detection.
        let encoded = PandaTokenProvider.encodeWorkspaceKey("/a/b/c")
        XCTAssertFalse(encoded.contains("%2F"))
        XCTAssertFalse(encoded.contains("%2f"))
        XCTAssertEqual(encoded, "-a-b-c")
    }

    func testSpacesAreEncodedAndHalfWidthParensAreNot() {
        // encodeURIComponent leaves ! * ' ( ) unescaped, so half-width parens
        // pass through while spaces become %20. (Full-width CJK parens （） are
        // non-ASCII and DO get percent-encoded — see the non-ASCII case.)
        let encoded = PandaTokenProvider.encodeWorkspaceKey("/Users/me/My Project (v2)")
        XCTAssertEqual(encoded, "-Users-me-My%20Project%20(v2)")
    }

    func testDotDashTildePassThrough() {
        XCTAssertEqual(
            PandaTokenProvider.encodeWorkspaceKey("/Users/me/a.b-c_d~e"),
            "-Users-me-a.b-c_d~e"
        )
    }
}
