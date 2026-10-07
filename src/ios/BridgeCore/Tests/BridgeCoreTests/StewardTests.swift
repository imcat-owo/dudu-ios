import XCTest

@testable import BridgeCore

final class StewardTests: XCTestCase {

    private func makeSteward() async throws -> Steward {
        let registry = ToolRegistry()
        try await FakeTools.registerAll(into: registry)
        return Steward(registry: registry)
    }

    func testHappyPathNamedTool() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(
                instruction: "复述一下",
                toolName: FakeTools.echoName,
                arguments: try StrictJSON.parseObject(#"{"text":"你好，桥"}"#)))
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.toolName, FakeTools.echoName)
        XCTAssertEqual(result.cleanedText, "你好，桥")
        XCTAssertEqual(result.rawText, "你好，桥")
        XCTAssertFalse(result.isError)
        let history = await steward.stateHistory(of: result.id)
        XCTAssertEqual(
            history,
            [
                .queued,
                .dispatched(toolName: FakeTools.echoName),
                .executing(toolName: FakeTools.echoName),
                .cleaning,
                .finished,
            ])
    }

    func testAutoRouteByInstruction() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(StewardRequest(instruction: "现在几点"))
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.toolName, FakeTools.currentTimeName)
        XCTAssertTrue(result.cleanedText?.contains("现在是") ?? false)
    }

    func testNoMatchingToolFails() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(StewardRequest(instruction: "变个魔术给我看 xyz123"))
        guard case .failed(let reason) = result.state else {
            return XCTFail("应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("找不到"))
        XCTAssertTrue(result.isError)
    }

    func testUnknownNamedToolFails() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(instruction: "执行", toolName: "ghost_tool"))
        guard case .failed(let reason) = result.state else {
            return XCTFail("应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("未在册"))
    }

    func testToolErrorPreservedNotSwallowed() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(instruction: "执行", toolName: FakeTools.alwaysFailName))
        guard case .failed(let reason) = result.state else {
            return XCTFail("应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("FAKE_TOOL_FAILURE"), "错误原文必须保留：\(reason)")
        XCTAssertTrue(result.cleanedText?.contains("FAKE_TOOL_FAILURE") ?? false)
        XCTAssertTrue(result.isError)
    }

    func testNoiseOutputCleanedEndToEnd() async throws {
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(instruction: "执行", toolName: FakeTools.noiseName))
        XCTAssertEqual(result.state, .finished)
        let cleaned = try XCTUnwrap(result.cleanedText)
        XCTAssertFalse(cleaned.contains("\u{1B}"), "ANSI 应被洗掉")
        XCTAssertTrue(cleaned.contains("进度 50%（重复 5 次）"))
        XCTAssertTrue(cleaned.contains("噪声任务结束"))
        XCTAssertFalse(cleaned.contains("internalNote"), "JSON 冗余字段应被滤掉")
        XCTAssertFalse(cleaned.contains("debugTrace"))
        // 原文保留备查
        XCTAssertTrue(result.rawText?.contains("internalNote") ?? false)
    }

    func testQueueIsSerial() async throws {
        let steward = try await makeSteward()
        let slowID = await steward.submit(
            StewardRequest(
                instruction: "等一下",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":800}"#),
                timeoutSeconds: 10))
        let echoID = await steward.submit(
            StewardRequest(
                instruction: "复述",
                toolName: FakeTools.echoName,
                arguments: try StrictJSON.parseObject(#"{"text":"排队中"}"#)))
        let echoStateWhileSlowRuns = await steward.state(of: echoID)
        XCTAssertEqual(echoStateWhileSlowRuns, .queued, "前一个没跑完，后一个必须排队")
        let slowResult = await steward.waitForCompletion(slowID)
        let echoResult = await steward.waitForCompletion(echoID)
        XCTAssertEqual(slowResult.state, .finished)
        XCTAssertEqual(echoResult.state, .finished)
        XCTAssertEqual(echoResult.cleanedText, "排队中")
    }

    func testCancelRunningTask() async throws {
        let steward = try await makeSteward()
        let id = await steward.submit(
            StewardRequest(
                instruction: "等很久",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":30000}"#),
                timeoutSeconds: 60))
        // 给它一点时间进入执行
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        await steward.cancel(id)
        let result = await steward.waitForCompletion(id)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.state, .cancelled)
        XCTAssertLessThan(elapsed, 5, "取消应很快收尾，不该等满 30 秒")
    }

    func testCancelQueuedTask() async throws {
        let steward = try await makeSteward()
        let slowID = await steward.submit(
            StewardRequest(
                instruction: "等一下",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":600}"#),
                timeoutSeconds: 10))
        let queuedID = await steward.submit(
            StewardRequest(instruction: "复述", toolName: FakeTools.echoName))
        await steward.cancel(queuedID)
        let queuedResult = await steward.waitForCompletion(queuedID)
        XCTAssertEqual(queuedResult.state, .cancelled)
        let slowResult = await steward.waitForCompletion(slowID)
        XCTAssertEqual(slowResult.state, .finished, "取消排队任务不影响正在跑的")
    }

    func testInterruptRunningTaskByOwner() async throws {
        let steward = try await makeSteward()
        let id = await steward.submit(
            StewardRequest(
                instruction: "等很久",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":30000}"#),
                timeoutSeconds: 60))
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        await steward.interruptByOwner(id)
        let result = await steward.waitForCompletion(id)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.state, .interruptedByOwner, "主人打断必须单列终态，不能混进一般取消")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.cleanedText?.contains("主人打断") ?? false,
            "回给外部调用方的文案必须能区分主人打断：\(result.cleanedText ?? "nil")")
        XCTAssertLessThan(elapsed, 5, "主人打断应很快收尾，不该等满 30 秒")
    }

    func testInterruptQueuedTaskByOwner() async throws {
        let steward = try await makeSteward()
        let slowID = await steward.submit(
            StewardRequest(
                instruction: "等一下",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":600}"#),
                timeoutSeconds: 10))
        let queuedID = await steward.submit(
            StewardRequest(instruction: "复述", toolName: FakeTools.echoName))
        await steward.interruptByOwner(queuedID)
        let queuedResult = await steward.waitForCompletion(queuedID)
        XCTAssertEqual(queuedResult.state, .interruptedByOwner)
        let slowResult = await steward.waitForCompletion(slowID)
        XCTAssertEqual(slowResult.state, .finished, "打断排队任务不影响正在跑的")
    }

    func testActiveTaskSummaries() async throws {
        let steward = try await makeSteward()
        let slowID = await steward.submit(
            StewardRequest(
                instruction: "等一下",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":800}"#),
                timeoutSeconds: 10))
        let queuedID = await steward.submit(
            StewardRequest(instruction: "复述一下", toolName: FakeTools.echoName))
        let summaries = await steward.activeTaskSummaries()
        XCTAssertEqual(summaries.map(\.id), [slowID, queuedID], "在跑的在前、排队的在后")
        XCTAssertEqual(summaries.first?.toolName, FakeTools.delayName)
        XCTAssertEqual(summaries.first?.instruction, "等一下")
        _ = await steward.waitForCompletion(slowID)
        _ = await steward.waitForCompletion(queuedID)
        let after = await steward.activeTaskSummaries()
        XCTAssertTrue(after.isEmpty, "全部终结后不应再有活动任务")
    }

    func testHugeTimeoutDoesNotCrashProcess() async throws {
        // 回归：timeoutSeconds 传超大值（外部 JSON 的 1e999 解析为 Double.inf）时，
        // 旧代码 UInt64(max(timeout, 0) * 1e9) 直接 trap 崩进程（可远程触发）。
        // 修后应钳制到上界，工具正常返回。
        let steward = try await makeSteward()
        let result = await steward.execute(
            StewardRequest(
                instruction: "复述一下",
                toolName: FakeTools.echoName,
                arguments: try StrictJSON.parseObject(#"{"text":"超时钳制"}"#),
                timeoutSeconds: Double.infinity))
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.cleanedText, "超时钳制")
    }

    func testRecentFinishedSummariesIncludeErrorText() async throws {
        // AI-P1-4/AI-P2-7：最近终结的任务摘要要带上报错原文，新的在前。
        let steward = try await makeSteward()
        let okResult = await steward.execute(
            StewardRequest(instruction: "复述", toolName: FakeTools.echoName,
                           arguments: try StrictJSON.parseObject(#"{"text":"好"}"#)))
        let failResult = await steward.execute(
            StewardRequest(instruction: "执行", toolName: FakeTools.alwaysFailName))
        XCTAssertEqual(okResult.state, .finished)
        guard case .failed = failResult.state else {
            return XCTFail("应失败，实际：\(failResult.state)")
        }
        let summaries = await steward.recentFinishedSummaries(limit: 5)
        XCTAssertEqual(summaries.count, 2)
        // 新的在前：失败的那个排第一，且带报错原文。
        XCTAssertEqual(summaries[0].toolName, FakeTools.alwaysFailName)
        XCTAssertTrue(summaries[0].errorText?.contains("FAKE_TOOL_FAILURE") ?? false)
        // 成功的那个不带报错文本。
        XCTAssertEqual(summaries[1].toolName, FakeTools.echoName)
        XCTAssertNil(summaries[1].errorText)
        // 正在跑/排队的任务不应出现在终结摘要里。
        XCTAssertTrue((await steward.activeTaskSummaries()).isEmpty)
    }

    func testTimeoutFuse() async throws {
        let steward = try await makeSteward()
        let started = Date()
        let result = await steward.execute(
            StewardRequest(
                instruction: "等很久",
                toolName: FakeTools.delayName,
                arguments: try StrictJSON.parseObject(#"{"ms":30000}"#),
                timeoutSeconds: 0.3))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.state, .timedOut)
        XCTAssertTrue(result.cleanedText?.contains("超时") ?? false)
        XCTAssertLessThan(elapsed, 5, "超时熔断应很快收尾")
    }

    func testSensitiveToolNeedsPhoneApproval() async throws {
        // 审批门桩：三种裁决各一扇。
        struct DenyGate: SensitiveApprovalGate {
            func requestApproval(toolName: String, instruction: String) async -> SensitiveApprovalDecision {
                .denied
            }
        }
        struct ApproveGate: SensitiveApprovalGate {
            func requestApproval(toolName: String, instruction: String) async -> SensitiveApprovalDecision {
                .approved
            }
        }
        struct AwayGate: SensitiveApprovalGate {
            func requestApproval(toolName: String, instruction: String) async -> SensitiveApprovalDecision {
                .ownerAway
            }
        }
        func makeStewardWithGate(_ gate: (any SensitiveApprovalGate)?) async throws -> Steward {
            let registry = ToolRegistry()
            try await registry.register(
                descriptor: ToolDescriptor(
                    name: "danger_op", summary: "敏感操作假工具", permission: .sensitive)
            ) { _ in ToolOutput(text: "已执行敏感操作") }
            return Steward(registry: registry, approvalGate: gate)
        }

        // 没装门：默认拒绝，不执行。
        let noGate = await (try makeStewardWithGate(nil)).execute(
            StewardRequest(instruction: "执行", toolName: "danger_op"))
        guard case .failed(let noGateReason) = noGate.state else {
            return XCTFail("没装审批门时敏感工具应失败，实际：\(noGate.state)")
        }
        XCTAssertTrue(noGateReason.contains("已拒绝"))

        // 主人拒绝：失败，不执行。
        let denied = await (try makeStewardWithGate(DenyGate())).execute(
            StewardRequest(instruction: "执行", toolName: "danger_op"))
        guard case .failed(let deniedReason) = denied.state else {
            return XCTFail("主人拒绝时敏感工具应失败，实际：\(denied.state)")
        }
        XCTAssertTrue(deniedReason.contains("已拒绝"))

        // 主人不在手机旁：失败，文案明确告知。
        let away = await (try makeStewardWithGate(AwayGate())).execute(
            StewardRequest(instruction: "执行", toolName: "danger_op"))
        guard case .failed(let awayReason) = away.state else {
            return XCTFail("主人不在时敏感工具应失败，实际：\(away.state)")
        }
        XCTAssertTrue(awayReason.contains("主人未在手机旁"))

        // 主人批准：执行。
        let approved = await (try makeStewardWithGate(ApproveGate())).execute(
            StewardRequest(instruction: "执行", toolName: "danger_op"))
        XCTAssertEqual(approved.state, .finished)
        XCTAssertEqual(approved.cleanedText, "已执行敏感操作")
    }

    func testDisabledToolRejectedBySteward() async throws {
        let registry = ToolRegistry()
        try await FakeTools.registerAll(into: registry)
        try await registry.setEnabled(false, for: FakeTools.echoName)
        let steward = Steward(registry: registry)
        let result = await steward.execute(
            StewardRequest(instruction: "复述", toolName: FakeTools.echoName))
        guard case .failed(let reason) = result.state else {
            return XCTFail("停用工具应失败，实际：\(result.state)")
        }
        XCTAssertTrue(reason.contains("已停用"))
    }
}
