import XCTest

@testable import BridgeCore

final class ToolRegistryTests: XCTestCase {

    private func makeRegistry() async throws -> ToolRegistry {
        let registry = ToolRegistry()
        try await FakeTools.registerAll(into: registry)
        return registry
    }

    func testRegisterAndDescribe() async throws {
        let registry = try await makeRegistry()
        let descriptors = await registry.allDescriptors()
        XCTAssertEqual(descriptors.count, 5)
        let echo = await registry.descriptor(for: FakeTools.echoName)
        XCTAssertEqual(echo?.summary, "回声：把给它的文字原样返回")
        XCTAssertEqual(echo?.permission, .standard)
        XCTAssertEqual(echo?.isEnabled, true)
    }

    func testDuplicateRegistrationRejected() async throws {
        let registry = try await makeRegistry()
        do {
            try await registry.register(
                descriptor: ToolDescriptor(name: FakeTools.echoName, summary: "又一个回声")
            ) { _ in ToolOutput(text: "") }
            XCTFail("重复注册应抛错")
        } catch let error as ToolRegistryError {
            guard case .duplicateName = error else {
                return XCTFail("应报 duplicateName，实际：\(error)")
            }
        }
    }

    func testInvalidSchemaRejected() async throws {
        let registry = ToolRegistry()
        do {
            try await registry.register(
                descriptor: ToolDescriptor(
                    name: "bad", summary: "坏工具", parameterSchemaJSON: "[1,2]")
            ) { _ in ToolOutput(text: "") }
            XCTFail("Schema 顶层是数组应被拒")
        } catch let error as ToolRegistryError {
            guard case .invalidDescriptor = error else {
                return XCTFail("应报 invalidDescriptor，实际：\(error)")
            }
        } catch {
            XCTFail("不应抛其他错误：\(error)")
        }
        do {
            try await registry.register(
                descriptor: ToolDescriptor(
                    name: "bad2", summary: "坏工具", parameterSchemaJSON: "{不是json")
            ) { _ in ToolOutput(text: "") }
            XCTFail("Schema 不是合法 JSON 应被拒")
        } catch let error as ToolRegistryError {
            guard case .invalidDescriptor = error else {
                return XCTFail("应报 invalidDescriptor，实际：\(error)")
            }
        } catch {
            XCTFail("不应抛其他错误：\(error)")
        }
    }

    func testSearchFindsByKeyword() async throws {
        let registry = try await makeRegistry()
        let hits = await registry.search("回声")
        XCTAssertEqual(hits.first?.name, FakeTools.echoName)
        let timeHits = await registry.search("现在几点")
        XCTAssertEqual(timeHits.first?.name, FakeTools.currentTimeName)
        let empty = await registry.search("完全不存在的能力xyz")
        XCTAssertTrue(empty.isEmpty)
    }

    func testSearchScoringNameBeatsSummary() async throws {
        let registry = ToolRegistry()
        try await registry.register(
            descriptor: ToolDescriptor(
                name: "alpha", summary: "和 beta 有关的工具", keywords: [])
        ) { _ in ToolOutput(text: "") }
        try await registry.register(
            descriptor: ToolDescriptor(name: "beta", summary: "另一个工具", keywords: [])
        ) { _ in ToolOutput(text: "") }
        let hits = await registry.search("beta")
        XCTAssertEqual(hits.first?.name, "beta")
        XCTAssertGreaterThan(hits.first?.score ?? 0, hits.last?.score ?? 0)
    }

    func testSearchResultCarriesShortSummary() async throws {
        let registry = try await makeRegistry()
        let hits = await registry.search("等待")
        XCTAssertEqual(hits.first?.name, FakeTools.delayName)
        XCTAssertEqual(hits.first?.summary, "等待指定的毫秒数后返回（验证超时与取消用）")
    }

    func testSearchHitCarriesParameterBrief() async throws {
        // AI-P1-6：搜索命中要带参数简述（参数名/类型/必填），保持短。
        let registry = ToolRegistry()
        try await registry.register(
            descriptor: ToolDescriptor(
                name: "brief_tool", summary: "参数简述假工具",
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "title":{"type":"string"},
                      "count":{"type":"integer"},
                      "verbose":{"type":"boolean"}},
                     "required":["title"]}
                    """#)
        ) { _ in ToolOutput(text: "ok") }
        let hits = await registry.search("简述")
        let brief = try XCTUnwrap(hits.first?.parameterBrief)
        XCTAssertTrue(brief.contains("title(字符串,必填)"), "实际：\(brief)")
        XCTAssertTrue(brief.contains("count(整数)"), "实际：\(brief)")
        XCTAssertTrue(brief.contains("verbose(布尔)"), "实际：\(brief)")
        XCTAssertFalse(brief.contains("description"), "不能把完整 schema 倒出来")
    }

    func testSearchHitParameterBriefEmptyWhenNoSchema() async throws {
        // 没有 properties 的 schema：简述为空，不污染结果。
        let registry = try await makeRegistry()
        let hits = await registry.search("回声")
        XCTAssertEqual(hits.first?.parameterBrief, "")
    }

    func testDisableHidesFromSearchAndInvoke() async throws {
        let registry = try await makeRegistry()
        try await registry.setEnabled(false, for: FakeTools.echoName)
        let hits = await registry.search("回声")
        XCTAssertFalse(hits.contains { $0.name == FakeTools.echoName })
        do {
            _ = try await registry.invoke(
                name: FakeTools.echoName,
                arguments: try StrictJSON.parseObject(#"{"text":"hi"}"#))
            XCTFail("停用工具调用应抛错")
        } catch let error as ToolRegistryError {
            guard case .disabled = error else {
                return XCTFail("应报 disabled，实际：\(error)")
            }
        }
        // includeDisabled 时还能搜到
        let all = await registry.search("回声", includeDisabled: true)
        XCTAssertTrue(all.contains { $0.name == FakeTools.echoName })
        // 重新启用恢复
        try await registry.setEnabled(true, for: FakeTools.echoName)
        let output = try await registry.invoke(
            name: FakeTools.echoName,
            arguments: try StrictJSON.parseObject(#"{"text":"hi"}"#))
        XCTAssertEqual(output.text, "hi")
    }

    func testSetEnabledUnknownToolThrows() async throws {
        let registry = ToolRegistry()
        do {
            try await registry.setEnabled(true, for: "ghost")
            XCTFail("不存在的工具应抛错")
        } catch let error as ToolRegistryError {
            guard case .notFound = error else {
                return XCTFail("应报 notFound，实际：\(error)")
            }
        } catch {
            XCTFail("不应抛其他错误：\(error)")
        }
    }

    func testUnregister() async throws {
        let registry = try await makeRegistry()
        let removed = await registry.unregister(name: FakeTools.noiseName)
        XCTAssertTrue(removed)
        let removedAgain = await registry.unregister(name: FakeTools.noiseName)
        XCTAssertFalse(removedAgain)
        let descriptor = await registry.descriptor(for: FakeTools.noiseName)
        XCTAssertNil(descriptor)
    }

    func testInvokePropagatesHandlerError() async throws {
        let registry = try await makeRegistry()
        do {
            _ = try await registry.invoke(
                name: FakeTools.alwaysFailName,
                arguments: try StrictJSON.parseObject("{}"))
            XCTFail("假工具应抛错")
        } catch let error as FakeToolError {
            XCTAssertEqual(error.description, "假工具按设计抛错：FAKE_TOOL_FAILURE")
        }
    }
}
