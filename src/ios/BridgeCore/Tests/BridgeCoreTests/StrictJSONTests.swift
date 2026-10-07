import XCTest

@testable import BridgeCore

final class StrictJSONTests: XCTestCase {

    func testParseObjectHappyPath() throws {
        let object = try StrictJSON.parseObject(#"{"name":"桥","count":3}"#)
        XCTAssertEqual(object.string("name"), "桥")
        XCTAssertEqual(object.int("count"), 3)
    }

    func testTopLevelArrayRejected() {
        XCTAssertThrowsError(try StrictJSON.parseObject("[1,2,3]")) { error in
            guard case StrictJSONError.topLevelNotObject = error else {
                return XCTFail("应报 topLevelNotObject，实际：\(error)")
            }
        }
    }

    func testTopLevelScalarRejected() {
        XCTAssertThrowsError(try StrictJSON.parseObject("42")) { error in
            guard case StrictJSONError.topLevelNotObject = error else {
                return XCTFail("应报 topLevelNotObject，实际：\(error)")
            }
        }
    }

    func testInvalidJSONThrowsWithDetail() {
        XCTAssertThrowsError(try StrictJSON.parseObject(#"{"a": }"#)) { error in
            guard case StrictJSONError.invalidJSON(let detail) = error else {
                return XCTFail("应报 invalidJSON，实际：\(error)")
            }
            XCTAssertFalse(detail.isEmpty)
        }
    }

    /// 严格边界核心：true 不许被读成数字 1，数字 1 不许被读成布尔。
    func testBoolAndNumberStrictlyDistinguished() throws {
        let object = try StrictJSON.parseObject(#"{"flag":true,"count":1,"ratio":1.5}"#)
        XCTAssertEqual(object.bool("flag"), true)
        XCTAssertNil(object.int("flag"))
        XCTAssertNil(object.double("flag"))
        XCTAssertNil(object.bool("count"))
        XCTAssertEqual(object.int("count"), 1)
        XCTAssertEqual(object.double("ratio") ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertNil(object.int("ratio"), "1.5 有小数部分，不许当整数读")
    }

    func testStringNotCoercedFromNumber() throws {
        let object = try StrictJSON.parseObject(#"{"n":7}"#)
        XCTAssertNil(object.string("n"))
        XCTAssertThrowsError(try object.requireString("n")) { error in
            guard case StrictJSONError.typeMismatch = error else {
                return XCTFail("应报 typeMismatch，实际：\(error)")
            }
        }
    }

    func testMissingKey() throws {
        let object = try StrictJSON.parseObject("{}")
        XCTAssertNil(object.string("nope"))
        XCTAssertThrowsError(try object.requireString("nope")) { error in
            guard case StrictJSONError.missingKey("nope") = error else {
                return XCTFail("应报 missingKey，实际：\(error)")
            }
        }
    }

    func testNestedObjectAndArray() throws {
        let object = try StrictJSON.parseObject(#"{"inner":{"x":2},"list":[1,2]}"#)
        XCTAssertEqual(object.object("inner")?.int("x"), 2)
        XCTAssertEqual(object.array("list")?.count, 2)
        XCTAssertNil(object.object("list"))
    }

    func testRoundTripSortedKeys() throws {
        let object = try StrictJSON.parseObject(#"{"b":1,"a":2}"#)
        let data = try StrictJSON.data(from: object)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"a":2,"b":1}"#)
    }

    // MARK: - 语法错误定位（给用户填错的自定义请求体报位置）

    func testSyntaxErrorOffsets() {
        XCTAssertNil(StrictJSON.firstSyntaxErrorOffset(#"{"a":1,"b":[true,null,"x"]}"#))
        XCTAssertNil(StrictJSON.firstSyntaxErrorOffset("  { }  "))
        // {"a": } —— 值的位置（下标 6）是 }
        XCTAssertEqual(StrictJSON.firstSyntaxErrorOffset(#"{"a": }"#), 6)
        // {"a":1,} —— 逗号后期望键，下标 7 是 }
        XCTAssertEqual(StrictJSON.firstSyntaxErrorOffset(#"{"a":1,}"#), 7)
        // [1,2 —— 未闭合，错误在结尾
        XCTAssertEqual(StrictJSON.firstSyntaxErrorOffset("[1,2"), 4)
        // {"a" 1} —— 缺冒号，下标 5 是 1
        XCTAssertEqual(StrictJSON.firstSyntaxErrorOffset(#"{"a" 1}"#), 5)
        // tru —— 字面量没写完
        XCTAssertEqual(StrictJSON.firstSyntaxErrorOffset("tru"), 3)
        // {"a":01} —— 数字前导 0 后面不许再跟数字，错误在下标 6
        XCTAssertEqual(StrictJSON.firstSyntaxErrorOffset(#"{"a":01}"#), 6)
        // 合法转义与 Unicode 转义
        XCTAssertNil(StrictJSON.firstSyntaxErrorOffset(#"{"s":"a\nbé"}"#))
        // 文档后面多东西
        XCTAssertEqual(StrictJSON.firstSyntaxErrorOffset("{} {}"), 3)
    }
}
