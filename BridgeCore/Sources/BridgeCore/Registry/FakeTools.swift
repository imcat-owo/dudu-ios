import Foundation

public enum FakeToolError: Error, CustomStringConvertible {
    case deliberate

    public var description: String {
        "假工具按设计抛错：FAKE_TOOL_FAILURE"
    }
}

/// 内置假工具组：心脏阶段先用它们把「注册→搜索→调度→清洗→返回」整条链跑通，
/// 之后真实工具（本地能力、外部 MCP）按同一声明格式逐个换进来。
public enum FakeTools {
    public static let echoName = "echo"
    public static let currentTimeName = "current_time"
    public static let noiseName = "noise"
    public static let delayName = "delay"
    public static let alwaysFailName = "always_fail"

    public static func registerAll(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: echoName,
                summary: "回声：把给它的文字原样返回",
                detail: "参数 text 为要复述的文字；不给 text 时把全部参数序列化后返回。用于打通链路与隔离测试。",
                keywords: ["回声", "复述", "原样返回", "echo", "测试"],
                parameterSchemaJSON:
                    #"{"type":"object","properties":{"text":{"type":"string","description":"要复述的文字"}}}"#
            )
        ) { arguments in
            if let text = arguments.string("text") {
                return ToolOutput(text: text)
            }
            if arguments.raw.isEmpty {
                return ToolOutput(text: "（空参数）")
            }
            let data = try StrictJSON.data(from: arguments)
            return ToolOutput(text: String(data: data, encoding: .utf8) ?? "（参数无法序列化）")
        }

        try await registry.register(
            descriptor: ToolDescriptor(
                name: currentTimeName,
                summary: "报当前时间：返回 ISO 8601 时间与 Unix 秒",
                detail: "无参数。返回执行那一刻的时间。",
                keywords: ["时间", "几点", "现在", "日期", "time", "now", "clock"]
            )
        ) { _ in
            let now = Date()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return ToolOutput(
                text: "现在是 \(formatter.string(from: now))（Unix \(Int(now.timeIntervalSince1970))）")
        }

        try await registry.register(
            descriptor: ToolDescriptor(
                name: noiseName,
                summary: "噪声发生器：产出带 ANSI、重复进度行与冗余字段 JSON 的输出，专供验证清洗",
                detail: "无参数。输出故意很脏，清洗后应只剩状态、简讯与折叠后的进度。",
                keywords: ["噪声", "脏输出", "noise", "清洗测试"]
            )
        ) { _ in
            var text = "\u{1B}[33m噪声任务开始\u{1B}[0m\n"
            for _ in 0..<5 {
                text += "进度 50%\n"
            }
            text +=
                #"{"status":"完成","message":"噪声任务结束","debugTrace":"x1-x2-x3","internalNote":"不应出现在清洗结果里","retryCountInternal":9}"#
            return ToolOutput(text: text)
        }

        try await registry.register(
            descriptor: ToolDescriptor(
                name: delayName,
                summary: "等待指定的毫秒数后返回（验证超时与取消用）",
                detail: "参数 ms 为整数毫秒，范围 0–60000。等待可被取消打断。",
                keywords: ["等待", "延时", "睡眠", "delay", "sleep", "慢"],
                parameterSchemaJSON:
                    #"{"type":"object","properties":{"ms":{"type":"integer","description":"等待毫秒数"}},"required":["ms"]}"#
            )
        ) { arguments in
            guard let ms = arguments.int("ms") else {
                throw StrictJSONError.typeMismatch(key: "ms", expected: "整数", actual: "缺失或非整数")
            }
            let clamped = min(max(ms, 0), 60_000)
            try await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
            return ToolOutput(text: "已等待 \(clamped) 毫秒")
        }

        try await registry.register(
            descriptor: ToolDescriptor(
                name: alwaysFailName,
                summary: "永远抛错的假工具，验证错误透传不被吞",
                detail: "无参数。每次调用都抛 FakeToolError.deliberate。",
                keywords: ["失败", "报错", "fail", "error"]
            )
        ) { _ in
            throw FakeToolError.deliberate
        }
    }
}
