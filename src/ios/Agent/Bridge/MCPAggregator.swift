import Foundation
import BridgeCore

/// MCP 聚合点（桥）：把她在 App 里接入并启用的 MCP 服务器的工具，
/// 聚合进小管家的 ToolRegistry —— 外部 AI 经「搜」能按关键词找到，
/// 经「命令」点名调用，小管家执行完走统一清洗返回。
///
/// 做法借鉴（功课二 `F-steward-persona.md`）：
/// - ameshkov/mcp-compress-router（MIT）：多 server 压成一个对外的口，
///   每个 server 一段描述供路由 —— 对应「搜」返回的一句话简介。
/// - giantswarm/muster（思路）：工具名加 server 前缀防串话。
///
/// 执行复用现成链路：in-guest `minis-mcp-cli`（与对话侧 AI 调 MCP
/// 是同一套 CLI、同一个 daemon），不另起 MCP 客户端。
actor MCPAggregator {
    /// 工具名前缀分隔符：`<serverId>.<toolName>`
    static let prefixSeparator = "."

    /// 允许出现在聚合工具名里的字符（白名单）。
    /// 远端工具名不可信，不让它把指令藏进名字里（功课二⑤）。
    private static let nameAllowed =
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))

    /// 每个 server 缓存的工具清单（daemon 侧也有会话缓存，这层只是
    /// 避免每次同步都调一次 CLI；server 增删/启停时由调用方清掉）。
    private var toolCache: [String: [MCPToolDesc]] = [:]

    /// 工具描述：name/description/inputSchema 从 daemon 的 tools/list 原样拿。
    struct MCPToolDesc: Sendable {
        let name: String
        let description: String
        /// inputSchema 的 JSON 原文（MCP 规范自带）；拿不到时为 `{}`。
        let inputSchemaJSON: String
    }

    enum AggregationError: Error, LocalizedError {
        case kernelNotBooted
        case cliFailed(String)
        var errorDescription: String? {
            switch self {
            case .kernelNotBooted: return "沙箱还没启动"
            case .cliFailed(let m): return m
            }
        }
    }

    private static let logger = AppLogger(category: "MCPAggregator")

    // MARK: - 工具名

    /// 聚合工具名：`<serverId>.<toolName>`，两边都按白名单清洗；
    /// 洗完有空的直接丢掉（不注册）。
    static func qualifiedName(serverId: String, toolName: String) -> String? {
        let s = sanitizeName(serverId)
        let t = sanitizeName(toolName)
        guard !s.isEmpty, !t.isEmpty else { return nil }
        return s + prefixSeparator + t
    }

    /// 白名单清洗：只留字母数字 `_.-`，其余换成 `_`。
    nonisolated static func sanitizeName(_ raw: String) -> String {
        String(raw.unicodeScalars.map {
            nameAllowed.contains($0) ? Character($0) : Character("_")
        })
    }

    // MARK: - 拉工具清单

    /// 经 in-guest CLI 拉某 server 的工具清单（daemon 缓存会话，不强制 refresh）。
    func fetchTools(serverId: String) async throws -> [MCPToolDesc] {
        if let cached = toolCache[serverId] { return cached }
        let result: ISHCommandResult
        do {
            result = try await ISHExecutionCoordinator.shared.execute(
                sessionId: "mcp-settings",
                command: "minis-mcp-cli tools \(Self.shellQuote(serverId))",
                timeout: 120,
                lineCallback: { _ in },
                pidCallback: { _ in })
        } catch ISHCoordinatorError.kernelNotBooted {
            throw AggregationError.kernelNotBooted
        }
        let tools = try Self.parseTools(from: result.output)
        toolCache[serverId] = tools
        return tools
    }

    /// 解析 `tools` 的 JSON 信封，取 tools 数组（name/description/inputSchema）。
    /// 与 MCPStore.refreshTools 同一解析口径，多拿一份 inputSchema。
    nonisolated static func parseTools(from output: String) throws -> [MCPToolDesc] {
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"),
                  let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let err = obj["error"] as? String { throw AggregationError.cliFailed(err) }
            let root = (obj["result"] as? [String: Any]) ?? obj
            guard let tools = root["tools"] as? [[String: Any]] else { continue }
            return tools.compactMap { dict -> MCPToolDesc? in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                let desc = (dict["description"] as? String) ?? ""
                var schemaJSON = #"{"type":"object"}"#
                if let schema = dict["inputSchema"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: schema),
                   let s = String(data: data, encoding: .utf8), !s.isEmpty {
                    schemaJSON = s
                }
                return MCPToolDesc(name: name, description: desc, inputSchemaJSON: schemaJSON)
            }
        }
        throw AggregationError.cliFailed("拉工具清单失败：CLI 没有返回可解析的结果")
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 清掉指定 server 的工具缓存（server 被删/停用/强制刷新时调）。
    func evictCache(serverId: String) {
        toolCache.removeValue(forKey: serverId)
    }

    // MARK: - 同步进注册表

    /// 按 MCPStore 当前状态把聚合工具与注册表对齐。
    /// - Parameter previouslyManaged: 上次同步时管理的 `[聚合名: 指纹]`。
    /// - Returns: 本次同步后管理的 `[聚合名: 指纹]`（调用方存下来）。
    ///
    /// 单个 server 拉清单失败不挡别的（记日志，下次同步再试）；
    /// 审批口径：`toolApprovals[tool]` 未登记 → 默认需要批准（敏感级），
    /// 与确认关卡那批定的规矩一致。
    func sync(into registry: ToolRegistry, previouslyManaged: [String: String]) async -> [String: String] {
        let servers: [MCPServerConfig] = await MainActor.run {
            MCPStore.shared.servers.filter(\.enabled)
        }
        let liveIds = Set(servers.map(\.id))
        let staleCacheIds = toolCache.keys.filter { !liveIds.contains($0) }
        for id in staleCacheIds { toolCache.removeValue(forKey: id) }

        var desired: [String: (fingerprint: String, descriptor: ToolDescriptor, serverId: String, toolName: String)] = [:]
        for server in servers {
            let tools: [MCPToolDesc]
            do {
                tools = try await fetchTools(serverId: server.id)
            } catch {
                Self.logger.warning("拉 \(server.id) 的工具清单失败（下次同步再试）：\(error.localizedDescription)")
                continue
            }
            for tool in tools {
                guard let qname = Self.qualifiedName(serverId: server.id, toolName: tool.name) else { continue }
                // 同名撞车（极少）：先到的赢。
                guard desired[qname] == nil else { continue }
                let needsApproval = server.toolApprovals?[tool.name] ?? true
                let descriptor = ToolDescriptor(
                    name: qname,
                    summary: Self.summary(serverId: server.id, tool: tool),
                    detail: Self.detail(serverId: server.id, qualifiedName: qname, tool: tool, needsApproval: needsApproval),
                    keywords: Self.keywords(serverId: server.id, tool: tool),
                    parameterSchemaJSON: tool.inputSchemaJSON,
                    permission: needsApproval ? .sensitive : .standard)
                let fingerprint = "\(tool.name)|\(tool.description)|\(tool.inputSchemaJSON)"
                desired[qname] = (fingerprint, descriptor, server.id, tool.name)
            }
        }

        // 清掉不在 desired 里的旧聚合工具（server 被删/停用/工具下线）。
        for qname in previouslyManaged.keys where desired[qname] == nil {
            _ = await registry.unregister(name: qname)
        }
        // 注册新增的；指纹变了的先注销再注册（描述/参数更新）。
        for (qname, entry) in desired {
            if previouslyManaged[qname] == entry.fingerprint { continue }
            _ = await registry.unregister(name: qname)
            let serverId = entry.serverId
            let toolName = entry.toolName
            do {
                try await registry.register(descriptor: entry.descriptor) { arguments in
                    try await Self.call(serverId: serverId, toolName: toolName, arguments: arguments)
                }
            } catch {
                Self.logger.warning("注册聚合工具 \(qname) 失败：\(error)")
            }
        }
        return Dictionary(uniqueKeysWithValues: desired.map { ($0.key, $0.value.fingerprint) })
    }

    // MARK: - 描述文本

    /// 一句话简介：「搜」返回给外部 AI 的就是它，必须短、说清归属和能干什么。
    nonisolated static func summary(serverId: String, tool: MCPToolDesc) -> String {
        let desc = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = desc.isEmpty ? "MCP 工具 \(tool.name)" : String(desc.prefix(100))
        return "[\(serverId)] \(head)"
    }

    nonisolated static func detail(serverId: String, qualifiedName: String, tool: MCPToolDesc, needsApproval: Bool) -> String {
        var parts: [String] = []
        let desc = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { parts.append(desc) }
        parts.append("这是 MCP 服务器「\(serverId)」上的工具 \(tool.name)，由小管家聚合进来。")
        parts.append("点名调用时 tool 填完整名 `\(qualifiedName)`，arguments 按参数 schema 传。")
        if needsApproval {
            parts.append("敏感动作：执行前需主人在手机上确认，未确认不执行。")
        }
        return parts.joined(separator: "\n")
    }

    /// 搜索关键词：server 名、工具名（含切分）、描述词，中英文都留。
    nonisolated static func keywords(serverId: String, tool: MCPToolDesc) -> [String] {
        var kws: Set<String> = ["mcp", serverId, tool.name]
        let descWords = tool.description.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
        for w in descWords.prefix(10) { kws.insert(w) }
        let nameParts = tool.name.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "_.-"))
            .filter { $0.count > 1 }
        for p in nameParts.prefix(6) { kws.insert(p) }
        return Array(kws)
    }

    // MARK: - 执行

    /// 执行聚合工具：`minis-mcp-cli call <server> <tool> --input '<json>'`。
    /// 取消信号透传（不吞成失败），与 WebSearchBridgeTool 同口径。
    nonisolated static func call(
        serverId: String, toolName: String, arguments: StrictJSONObject
    ) async throws -> ToolOutput {
        let qname = "\(serverId).\(toolName)"
        let json: String
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments.raw, options: [.sortedKeys])
            json = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return ToolOutput(text: "参数不是合法 JSON：\(error.localizedDescription)", isError: true)
        }
        let command = "minis-mcp-cli call \(shellQuote(serverId)) \(shellQuote(toolName)) --input \(shellQuote(json))"
        let result: ISHCommandResult
        do {
            result = try await ISHExecutionCoordinator.shared.execute(
                sessionId: OffloadToolRunner.bridgeSessionId,
                command: command,
                timeout: 120,
                lineCallback: { _ in },
                pidCallback: { _ in })
        } catch ISHCoordinatorError.kernelNotBooted {
            return ToolOutput(text: "沙箱还没启动：请先在 App 里打开一次终端页，等沙箱初始化完成后再试。", isError: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw CancellationError()
        } catch {
            return ToolOutput(text: "MCP 调用失败（\(qname)）：\(error.localizedDescription)", isError: true)
        }
        return formatCallResult(output: result.output, exitCode: result.exitCode, qualifiedName: qname)
    }

    /// 解析 `call` 的 JSON 信封：MCP 的 content 数组拼成文本；
    /// 报错原样回，不吞。
    nonisolated static func formatCallResult(output: String, exitCode: Int, qualifiedName: String) -> ToolOutput {
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"),
                  let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let err = obj["error"] as? String {
                return ToolOutput(text: "MCP 调用失败（\(qualifiedName)）：\(err)", isError: true)
            }
            let ok = (obj["ok"] as? Bool) ?? true
            let result = (obj["result"] as? [String: Any]) ?? obj
            if !ok {
                let msg = (result["message"] as? String) ?? "未知错误"
                return ToolOutput(text: "MCP 调用失败（\(qualifiedName)）：\(msg)", isError: true)
            }
            // MCP tools/call 结果：{content: [{type: text, text: ...}], isError}
            if let content = result["content"] as? [[String: Any]] {
                let texts = content.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
                let isErr = (result["isError"] as? Bool) ?? false
                let body = texts.joined(separator: "\n")
                return ToolOutput(text: body.isEmpty ? "（调用成功，无文本输出）" : body, isError: isErr)
            }
            // 非标准形状：压成一行 JSON 原样回（清洗层会再处理）。
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8), !s.isEmpty {
                return ToolOutput(text: String(s.prefix(8000)))
            }
            return ToolOutput(text: "（调用成功，无输出）")
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode != 0 {
            return ToolOutput(
                text: trimmed.isEmpty
                    ? "MCP 调用失败（\(qualifiedName)，退出码 \(exitCode)，无输出）" : trimmed,
                isError: true)
        }
        return ToolOutput(text: trimmed.isEmpty ? "（调用成功，无输出）" : trimmed)
    }
}
