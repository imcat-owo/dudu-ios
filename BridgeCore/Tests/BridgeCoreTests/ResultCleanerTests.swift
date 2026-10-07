import XCTest

@testable import BridgeCore

final class ResultCleanerTests: XCTestCase {
    private let cleaner = ResultCleaner()

    // MARK: - 规则 1：ANSI 与控制字符

    func testStripANSICodes() {
        let raw = "\u{1B}[31m红色\u{1B}[0m 普通 \u{1B}[1;32m加粗绿\u{1B}[0m"
        XCTAssertEqual(cleaner.stripControlSequences(raw), "红色 普通 加粗绿")
    }

    func testStripOSCAndControlChars() {
        let raw = "标题\u{1B}]0;窗口标题\u{07}正文\u{07}\u{01}\u{7F}结束\r\n下一行"
        XCTAssertEqual(cleaner.stripControlSequences(raw), "标题正文结束\n下一行")
    }

    func testStripKeepsNewlineAndTab() {
        XCTAssertEqual(cleaner.stripControlSequences("a\tb\nc"), "a\tb\nc")
    }

    func testStripLoneEscapeAtEnd() {
        XCTAssertEqual(cleaner.stripControlSequences("abc\u{1B}"), "abc")
    }

    // MARK: - 规则 2：折叠重复行

    func testCollapseRepeatedLines() {
        let raw = "进度 50%\n进度 50%\n进度 50%\n完成"
        XCTAssertEqual(cleaner.collapseRepeatedLines(raw), "进度 50%（重复 3 次）\n完成")
    }

    func testCollapseSingleOccurrenceUntouched() {
        let raw = "第一行\n第二行\n第一行"
        XCTAssertEqual(cleaner.collapseRepeatedLines(raw), raw, "不相邻的相同行不折叠")
    }

    func testCollapseBlankLinesWithoutAnnotation() {
        let raw = "a\n\n\n\nb"
        XCTAssertEqual(cleaner.collapseRepeatedLines(raw), "a\n\nb")
    }

    // MARK: - 规则 3：JSON 关键字段

    func testFilterJSONObjectKeepsOnlyListedKeys() {
        let raw = #"{"name":"任务","status":"ok","debug":"一堆细节","trace":[1,2,3]}"#
        XCTAssertEqual(cleaner.filterJSONKeys(raw), #"{"name":"任务","status":"ok"}"#)
    }

    func testFilterJSONArrayOfObjects() {
        let raw = #"[{"id":1,"junk":"x"},{"id":2,"junk":"y"}]"#
        XCTAssertEqual(cleaner.filterJSONKeys(raw), #"[{"id":1},{"id":2}]"#)
    }

    func testFilterLeavesNonJSONAlone() {
        let raw = "这不是 JSON {只有一边括号"
        XCTAssertEqual(cleaner.filterJSONKeys(raw), raw)
    }

    func testFilterNeverEmptiesObject() {
        let raw = #"{"unlisted":"只有没列进保留集的键"}"#
        XCTAssertEqual(cleaner.filterJSONKeys(raw), raw, "过滤后会掏空对象时保持原样")
    }

    func testFilterBrokenJSONLeftAlone() {
        let raw = #"{"name": }"#
        XCTAssertEqual(cleaner.filterJSONKeys(raw), raw)
    }

    func testFilterJSONLineInsidePlainText() {
        let raw = "任务日志一行\n{\"status\":\"完成\",\"debugTrace\":\"x\"}\n普通结尾"
        XCTAssertEqual(
            cleaner.filterJSONKeys(raw),
            "任务日志一行\n{\"status\":\"完成\"}\n普通结尾")
    }

    // MARK: - 规则 4：截断

    func testTruncateHeadTail() {
        let small = ResultCleaner(configuration: .init(maxLength: 100))
        let text = String(repeating: "头", count: 100) + String(repeating: "尾", count: 100)
        let result = small.truncateHeadTail(text)
        XCTAssertLessThanOrEqual(result.count, 100)
        XCTAssertTrue(result.hasPrefix("头"))
        XCTAssertTrue(result.hasSuffix("尾"))
        XCTAssertTrue(result.contains("已截断"))
        XCTAssertTrue(result.contains("字符"))
    }

    func testTruncateUnderLimitUntouched() {
        XCTAssertEqual(cleaner.truncateHeadTail("短文本"), "短文本")
    }

    func testTruncateReportsRemovedCount() {
        let small = ResultCleaner(configuration: .init(maxLength: 50))
        let text = String(repeating: "x", count: 1000)
        let result = small.truncateHeadTail(text)
        // 截断数应在结果里能读到，且头尾+标注恰好不超预算
        XCTAssertLessThanOrEqual(result.count, 50)
        XCTAssertTrue(result.contains("（中间已截断 "))
    }

    // MARK: - 流水线

    func testCleanPipelineCombinesRules() {
        let raw = "\u{1B}[36m工作中\u{1B}[0m\n进度 99%\n进度 99%\n进度 99%"
        let cleaned = cleaner.clean(raw)
        XCTAssertEqual(cleaned, "工作中\n进度 99%（重复 3 次）")
    }

    func testCleanPlainTextPassesThrough() {
        XCTAssertEqual(cleaner.clean("普通结果文本"), "普通结果文本")
    }
}
