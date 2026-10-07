import Foundation
import MCP

/// 桥对外只暴露的两个元工具——「搜」与「命令」（架构定稿锁死）。
/// 内部几百个工具怎么组织是桥自己的事，外部 AI 永远只看见这两个口。
public enum BridgeMetaTools {
    public static let searchName = "搜"
    public static let commandName = "命令"

    /// 造一台只挂这两个元工具的 MCP Server。
    /// 每会话调用一次（会话工厂语义），Server 不跨会话共享。
    /// handler 注册完才返回，调用方随后 start，不存在「先开服后挂 handler」的竞态。
    public static func makeServer(registry: ToolRegistry, steward: Steward) async -> Server {
        let server = Server(
            name: BridgeKernel.serverName,
            version: BridgeKernel.serverVersion,
            title: "桥",
            instructions: """
                你连上的是「桥」。桥对外只有两个工具：
                先用「搜」按关键词找到能干活的工具（返回名字、一句话简介与参数简述），
                再用「命令」下指令让桥里的小管家执行，只回清洗后的高密度结果。
                """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        let searchTool = Tool(
            name: searchName,
            description: "在桥的工具库里按关键词搜索可用工具，返回短清单（名字 + 一句话简介 + 参数简述）。先搜再执行。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("要找什么能力，用中文关键词说，比如：蓝牙、剪贴板、定位、通知、相册、报问题"),
                    ])
                ]),
                "required": .array([.string("query")]),
            ])
        )
        let commandTool = Tool(
            name: commandName,
            description: "下达一条指令，桥里的小管家负责找工具、执行、清洗，只回高密度结果。可点名 tool 指定工具，不点名则由管家按指令智能路由。敏感动作（如删照片、发 GitHub Issue）执行前会弹框请主人在手机上确认，主人超时未确认或不在手机旁则默认拒绝。",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "instruction": .object([
                        "type": .string("string"),
                        "description": .string("一句话告诉小管家要干什么，比如：帮我查一下手机现在的位置。小管家会自己找工具办。"),
                    ]),
                    "tool": .object([
                        "type": .string("string"),
                        "description": .string("可选：点名要用哪个工具（名字先用「搜」查到）；不填小管家就按指令自己挑"),
                    ]),
                    "arguments": .object([
                        "type": .string("object"),
                        "description": .string("可选：点名工具时一起传的参数（JSON 对象）；参数名和必填项看「搜」返回的参数简述"),
                    ]),
                    "timeoutSeconds": .object([
                        "type": .string("number"),
                        "description": .string(
                            "可选：超时秒数，默认 30。不要超过 60（中继转发上限），超过 60 第一次必吃 504。"),
                    ]),
                    "sensitiveApproved": .object([
                        "type": .string("boolean"),
                        // 已作废：兼容保留，实际审批只能由手机侧弹框签发，
                        // 传任何值都不会被信任（防外部 AI 自批）。
                        "description": .string("已作废：兼容保留。敏感审批由手机侧弹框完成，传 true 也不会被信任。"),
                    ]),
                ]),
                "required": .array([.string("instruction")]),
            ])
        )
        let tools = [searchTool, commandTool]

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await handleCall(params: params, registry: registry, steward: steward)
        }
        return server
    }

    // MARK: - 调用处理

    private static func handleCall(
        params: CallTool.Parameters, registry: ToolRegistry, steward: Steward
    ) async -> CallTool.Result {
        switch params.name {
        case searchName:
            return await handleSearch(params: params, registry: registry)
        case commandName:
            return await handleCommand(params: params, steward: steward)
        default:
            return errorResult("未知工具：\(params.name)。桥对外只提供「搜」和「命令」。")
        }
    }

    private static func handleSearch(
        params: CallTool.Parameters, registry: ToolRegistry
    ) async -> CallTool.Result {
        let arguments: StrictJSONObject
        switch strictArguments(of: params) {
        case .success(let parsed): arguments = parsed
        case .failure(let error): return errorResult("「搜」参数解析失败：\(error.description)")
        }
        guard let query = try? arguments.requireString("query") else {
            return errorResult("「搜」缺少必填参数 query（字符串）")
        }
        let hits = await registry.search(query)
        guard !hits.isEmpty else {
            return textResult("没有找到与「\(query)」匹配的工具。")
        }
        let lines = hits.map { hit -> String in
            var line = "- \(hit.name)：\(hit.summary)"
            if !hit.parameterBrief.isEmpty {
                line += "\n  参数：\(hit.parameterBrief)"
            }
            // 纸条 v1：命中的工具有纸条就附上。只给命中且有纸条的，不全量下发。
            if let paperBlock = ToolPapers.paperBlock(for: hit.name) {
                line += "\n\(paperBlock)"
            }
            return line
        }
        return textResult("找到 \(hits.count) 个工具：\n" + lines.joined(separator: "\n"))
    }

    private static func handleCommand(
        params: CallTool.Parameters, steward: Steward
    ) async -> CallTool.Result {
        let arguments: StrictJSONObject
        switch strictArguments(of: params) {
        case .success(let parsed): arguments = parsed
        case .failure(let error): return errorResult("「命令」参数解析失败：\(error.description)")
        }
        guard let instruction = try? arguments.requireString("instruction") else {
            return errorResult("「命令」缺少必填参数 instruction（字符串）")
        }
        // 类型写错不许静默回默认值：传了字符串 "60" 调用方会以为生效、
        // 实际跑 30 秒——和 query 缺必填一样，明确报错。
        let timeoutSeconds: Double
        if arguments.contains("timeoutSeconds") {
            guard let parsed = arguments.double("timeoutSeconds") else {
                let actual = StrictJSON.typeName(
                    of: arguments.value("timeoutSeconds") ?? NSNull())
                return errorResult(
                    "「命令」timeoutSeconds 类型不对：需要数字（秒），你传了\(actual)")
            }
            timeoutSeconds = parsed
        } else {
            timeoutSeconds = 30
        }
        // 桥口这一层的校验上限是 60 秒（中继转发上限），与工具说明对齐。
        // Steward.maxTimeoutSeconds（3600）是内部上限，本体不动。
        guard timeoutSeconds <= 60 else {
            return errorResult(
                "「命令」timeoutSeconds 不能超过 60 秒（中继转发上限，超了第一次必吃 504；你传了 \(timeoutSeconds)），已拒绝。")
        }
        let request = StewardRequest(
            instruction: instruction,
            toolName: arguments.string("tool"),
            arguments: arguments.object("arguments") ?? StrictJSONObject(raw: [:]),
            timeoutSeconds: timeoutSeconds)
        let result = await steward.execute(request)
        var text = result.cleanedText ?? "（没有返回内容）"
        // 纸条 v1：实际执行的工具因参数错误被拒 → 附该工具的纸条。
        // "参数不对："是全工具统一的参数错误文案；超时/拒绝/未在册等其他失败不附。
        // 没纸条的工具 paperBlock 为 nil，行为零变化。
        if case .failed(let reason) = result.state,
            reason.hasPrefix("参数不对"),
            let toolName = result.toolName,
            let paperBlock = ToolPapers.paperBlock(for: toolName)
        {
            text += "\n\n\(paperBlock)"
        }
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: result.isError)
    }

    // MARK: - 严格参数解析

    /// 严格解析调用参数：优先走原始 HTTP body（`Server.currentHandlerContext`
    /// 暴露的 httpContext），绕开 SDK `Value` 可能的宽松数值/布尔混读；
    /// 拿不到原始 body 时回退到把已解出的 Value 重新序列化再严格解析。
    static func strictArguments(
        of params: CallTool.Parameters
    ) -> Result<StrictJSONObject, StrictJSONError> {
        if let httpContext = Server.currentHandlerContext?.httpContext,
            let body = httpContext.body
        {
            do {
                let root = try StrictJSON.parseObject(body)
                guard let rpcParams = root.object("params") else {
                    return .success(StrictJSONObject(raw: [:]))
                }
                if rpcParams.raw["arguments"] == nil {
                    return .success(StrictJSONObject(raw: [:]))
                }
                guard let arguments = rpcParams.object("arguments") else {
                    return .failure(
                        .typeMismatch(
                            key: "arguments", expected: "对象",
                            actual: StrictJSON.typeName(of: rpcParams.raw["arguments"] ?? NSNull())))
                }
                return .success(arguments)
            } catch let error as StrictJSONError {
                return .failure(error)
            } catch {
                return .failure(.invalidJSON("\(error)"))
            }
        }
        if let arguments = params.arguments {
            do {
                let data = try JSONEncoder().encode(Value.object(arguments))
                return .success(try StrictJSON.parseObject(data))
            } catch let error as StrictJSONError {
                return .failure(error)
            } catch {
                return .failure(.invalidJSON("\(error)"))
            }
        }
        return .success(StrictJSONObject(raw: [:]))
    }

    private static func textResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private static func errorResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
    }
}
