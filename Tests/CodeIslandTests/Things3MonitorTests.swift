import XCTest
@testable import CodeIsland

final class Things3MonitorTests: XCTestCase {
    private let sep = "\u{1F}"

    func testParseSectionsAndFields() {
        let output = """
        TODAY
        T\(sep)清风惠学校项目申报方案\(sep)2026年10月8日 09:00\(sep)工作
        T\(sep)买牛奶\(sep)\(sep)
        PLAN
        U\(sep)季度回顾\(sep)2026年10月15日 14:00\(sep)
        """
        let parsed = Things3Monitor.parse(output)
        XCTAssertEqual(parsed.today.count, 2)
        XCTAssertEqual(parsed.today[0].title, "清风惠学校项目申报方案")
        XCTAssertEqual(parsed.today[0].dueText, "2026年10月8日 09:00")
        XCTAssertEqual(parsed.today[0].tags, "工作")
        XCTAssertEqual(parsed.today[1].title, "买牛奶")
        XCTAssertEqual(parsed.today[1].dueText, "")
        XCTAssertEqual(parsed.upcoming.count, 1)
        XCTAssertEqual(parsed.upcoming[0].title, "季度回顾")
    }

    func testParseSkipsEmptyTitlesAndForeignLines() {
        // The live transcript showed an empty-name row in the Today list, and
        // the script echoes nothing else — noise lines must be ignored.
        let output = """
        TODAY
        T\(sep)\(sep)\(sep)
        T\(sep)real task\(sep)\(sep)
        NOTE this is not an item
        """
        let parsed = Things3Monitor.parse(output)
        XCTAssertEqual(parsed.today.count, 1)
        XCTAssertEqual(parsed.today[0].title, "real task")
        XCTAssertEqual(parsed.upcoming.count, 0)
    }

    func testParseEmptyOutput() {
        let parsed = Things3Monitor.parse("")
        XCTAssertEqual(parsed.today.count, 0)
        XCTAssertEqual(parsed.upcoming.count, 0)
    }

    func testParseTitleStartingWithMarkerLetter() {
        // "T" or "U" as the FIRST LETTER of a title must survive — only the
        // section markers TODAY/PLAN switch sections.
        let output = """
        TODAY
        T\(sep)Update the docs\(sep)\(sep)
        """
        let parsed = Things3Monitor.parse(output)
        XCTAssertEqual(parsed.today.first?.title, "Update the docs")
    }
}
