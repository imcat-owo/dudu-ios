import Foundation

/// 小管家专用 MCP 管理工具（对话侧）：`add_mcp` / `list_mcp` / `remove_mcp` / `toggle_mcp`。
///
/// 给小管家（MCP 小助手人设）管 MCP 的脏活工具 —— 她发个链接，小管家自己
/// 走完接入流程。做法借鉴（功课二 `F-steward-persona.md`）：
/// - sensai 的 `mcp add`：URL → 鉴权 → 拉工具清单 → 确认。
/// - giantswarm/muster 的 core_mcpserver_*：增删改查走工具，命令走 stderr。
///
/// 安全口径（她定的）：陌生 MCP ＝ 陌生代码执行权，落盘前必须她点头。
/// `add_mcp` / `remove_mcp` 都是两段式：第一段探一下/列出来，
/// 第二段带 `confirm=true` 才真干。
///
/// 挂载方式：定义与分发都在这里；调用方在
/// `AIChatViewModel+ToolDefinitions.swift` 的 `makeAgentTools()` 里加
/// `MCPManagementTools.dialogDefinitions()`，在
/// `AIChatViewModel+ConcurrentTools.swift` 的 switch 里调
/// `MCPManagementTools.handleDialogCall(name:args:)`。
/// skill 白名单门控在人设层做（隔离层施工员负责）。
enum MCPManagementTools {
    // MARK: - 对话侧工具定义

    static func dialogDefinitions() -> [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "add_mcp",
                description: "给小管家接入一个新的 MCP 服务器（MCP 聚合点专用）。两段式：第一段先探一下 MCP 的 URL、鉴权、能拉到哪些工具，并把清单列出来请主人确认；主人点头后第二段带 confirm=true 再调一次——这时手机上会弹框，必须主人亲手点「允许」才真落盘（confirm 参数只是回执，不当权限）。陌生链接必须先确认再接。确认接入后，这家 MCP 的工具会进小管家的「搜」和「命令」，外部 AI 也能调。鉴权信息绝不许传明文 key：如需鉴权，先请主人去「设置 → 环境变量」新建变量（值由主人亲自填写，只进钥匙串），再把 \"Key: $$变量名\" 传给我（如 \"Authorization: $$MY_MCP_KEY\"）。",
                parameters: [
                    "url": AgentToolParam(type: .string, description: "MCP 服务器地址（http/https，必填）"),
                    "name": AgentToolParam(type: .string, description: "给这家 MCP 起的名字（只允许字母数字 _.-；不填就用域名）"),
                    "note": AgentToolParam(type: .string, description: "备注（给主人看的，比如这是谁家的服务）"),
                    "authHeaderRef": AgentToolParam(type: .string, description: "鉴权头引用，\"Key: $$变量名\" 格式（如 \"Authorization: $$MY_MCP_KEY\"）；变量必须是「设置 → 环境变量」里已建好的。不需要鉴权就空着。传明文 key 会被直接拒绝。"),
                    "confirm": AgentToolParam(type: .boolean, description: "确认接入。第一次调不传（只探、只列清单）；主人点头后再调一次并传 confirm=true——这时手机会弹框，必须主人亲手点允许才真落盘"),
                ],
                required: ["url"]),
            AgentToolDefinition(
                name: "list_mcp",
                description: "列出小管家已接入的 MCP 服务器：名字、地址、启用状态、工具数。",
                parameters: [:],
                required: []),
            AgentToolDefinition(
                name: "remove_mcp",
                description: "移除小管家已接入的 MCP 服务器。两段式：第一次调先列出这家 MCP 的工具清单请主人确认；主人点头后带 confirm=true 再调一次——这时手机上会弹框，必须主人亲手点「允许」才真删（confirm 参数只是回执，不当权限）。删掉后这家的工具会从「搜」和「命令」里下掉。",
                parameters: [
                    "name": AgentToolParam(type: .string, description: "要删的 MCP 名字（必填）"),
                    "confirm": AgentToolParam(type: .boolean, description: "确认删除。第一次调不传（只列清单）；主人点头后再调一次并传 confirm=true——这时手机会弹框，必须主人亲手点允许才真删"),
                ],
                required: ["name"]),
            AgentToolDefinition(
                name: "toggle_mcp",
                description: "启用/停用一家 MCP。停用后它的工具暂时从「搜」和「命令」里下掉，配置保留，随时可再启用。",
                parameters: [
                    "name": AgentToolParam(type: .string, description: "MCP 名字（必填）"),
                    "enabled": AgentToolParam(type: .boolean, description: "true=启用，false=停用（必填）"),
                ],
                required: ["name", "enabled"]),
        ]
    }

    // MARK: - 对话侧分发

    /// - Returns: (输出文本, 是否成功)
    static func handleDialogCall(name: String, args: [String: Any]) async -> (String, Bool) {
        switch name {
        case "add_mcp": return await addMCP(args: args)
        case "list_mcp": return await listMCP()
        case "remove_mcp": return await removeMCP(args: args)
        case "toggle_mcp": return await toggleMCP(args: args)
        default: return ("Error: 未知的 MCP 管理工具：\(name)", false)
        }
    }

    // MARK: - 实现

    /// 只允许字母数字 `_.-`，其余换成 `_`（远端输入不可信）。
    private static func sanitizeServerName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return String(raw.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : Character("_")
        })
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 在沙箱里跑一条 minis-mcp-cli 命令（工具清单/探针/管理都走这条）。
    private static func runCLI(_ command: String, timeout: TimeInterval = 60) async throws -> String {
        let result = try await ISHExecutionCoordinator.shared.execute(
            sessionId: "mcp-settings",
            command: command,
            timeout: timeout,
            lineCallback: { _ in },
            pidCallback: { _ in })
        return result.output
    }

    /// 解析 CLI 的 JSON 信封：{"ok":..,"result":..} 或 {"error":..}。
    private static func parseEnvelope(_ output: String) throws -> [String: Any] {
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"),
                  let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let err = obj["error"] as? String { throw MCPManagementError.cli(err) }
            return (obj["result"] as? [String: Any]) ?? obj
        }
        throw MCPManagementError.cli("CLI 没有返回可解析的结果")
    }

    enum MCPManagementError: Error, LocalizedError {
        case cli(String)
        var errorDescription: String? {
            if case .cli(let m) = self { return m }
            return nil
        }
    }

    /// 探针：add → ping → tools，返回工具清单；探针失败或不需要时把 server 撤掉。
    private static func probe(serverName: String, toolsTimeout: TimeInterval = 60) async throws -> [[String: Any]] {
        _ = try await runCLI("minis-mcp-cli ping \(shellQuote(serverName))", timeout: 60)
        let toolsOut = try await runCLI("minis-mcp-cli tools \(shellQuote(serverName))", timeout: toolsTimeout)
        let envelope = try parseEnvelope(toolsOut)
        return (envelope["tools"] as? [[String: Any]]) ?? []
    }

    private static func describeTools(_ tools: [[String: Any]]) -> String {
        if tools.isEmpty { return "（这家 MCP 没有暴露任何工具）" }
        return tools.prefix(30).map { t in
            let n = (t["name"] as? String) ?? "?"
            let d = ((t["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? "- \(n)" : "- \(n)：\(d.prefix(60))"
        }.joined(separator: "\n")
        + (tools.count > 30 ? "\n……共 \(tools.count) 个工具" : "")
    }

    /// 变更落盘后：刷新 MCPStore 快照 → 触发小管家重聚合。
    private static func afterChange() async {
        await MainActor.run { MCPStore.shared.scanExternalChanges() }
        BridgeExternalMCPService.shared.resyncMCPTools()
    }

    // MARK: add_mcp

    private static func addMCP(args: [String: Any]) async -> (String, Bool) {
        guard let url = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty,
              let comps = URLComponents(string: url),
              let scheme = comps.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              comps.host != nil
        else {
            return ("Error: url 必填，必须是 http(s) 链接。", false)
        }
        var name = ((args["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = comps.host ?? "mcp" }
        name = sanitizeServerName(name)
        guard !name.isEmpty else { return ("Error: 名字不合法。", false) }
        let note = ((args["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let confirm = (args["confirm"] as? Bool) ?? false

        // P1-1：鉴权信息绝不许走明文。旧参数名 authHeader 若还被传值，
        // 一律按明文 key 拒绝——key 只许以 $$变量名 引用的形式来。
        if let legacy = args["authHeader"] as? String,
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("Error: 鉴权信息不许传明文 key。请主人去「设置 → 环境变量」新建一个变量（值由主人亲自填写，只进钥匙串），再把 \"Key: $$变量名\" 传给我。", false)
        }
        // 鉴权头引用：必须是 "Key: $$VARNAME" 形状，值原样进 servers.json，
        // 运行时由 minis-mcp-cli 从 App 环境变量（钥匙串）解析，明文永不落盘。
        var headerArg: String? = nil
        let authHeaderRef = ((args["authHeaderRef"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !authHeaderRef.isEmpty {
            guard let colon = authHeaderRef.firstIndex(of: ":") else {
                return ("Error: authHeaderRef 格式不对，要 \"Key: $$变量名\" 这样，比如 \"Authorization: $$MY_MCP_KEY\"。", false)
            }
            let hKey = authHeaderRef[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let hVal = authHeaderRef[authHeaderRef.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hKey.isEmpty, hVal.hasPrefix("$$"), hVal.count > 2 else {
                return ("Error: authHeaderRef 必须是 \"Key: $$变量名\" 形状（如 \"Authorization: $$MY_MCP_KEY\"），不许传明文 key。", false)
            }
            let varName = String(hVal.dropFirst(2))
            guard varName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                return ("Error: 变量名「\(varName)」不合法，只要字母数字下划线。", false)
            }
            let varExists = await MainActor.run {
                EnvVarStore.shared.entries.contains(where: { $0.key == varName })
            }
            guard varExists else {
                return ("Error: 环境变量「\(varName)」还没建。请主人去「设置 → 环境变量」新建它（值由主人亲自填写），建好后我再调一次 add_mcp，参数完全一样。", false)
            }
            headerArg = "\(hKey): \(hVal)"
        }

        let exists = await MainActor.run {
            MCPStore.shared.servers.contains(where: { $0.id == name })
        }
        if exists {
            return ("Error: 已经有一家叫「\(name)」的 MCP 了。换个名字，或先用 remove_mcp 删掉旧的。", false)
        }

        var addCmd = "minis-mcp-cli add --name \(shellQuote(name)) --url \(shellQuote(url))"
        if !note.isEmpty { addCmd += " --note \(shellQuote(note))" }
        if let headerArg {
            // 存的是 $$VARNAME 引用原文，明文 key 永不出现在这条命令里。
            addCmd += " --header \(shellQuote(headerArg))"
        }

        do {
            _ = try await runCLI(addCmd, timeout: 60)
        } catch {
            return ("接入失败：\(errorMessage(error))\n（add 这一步就没过去，链接或参数可能有问题。）", false)
        }

        let tools: [[String: Any]]
        do {
            tools = try await probe(serverName: name)
        } catch {
            _ = try? await runCLI("minis-mcp-cli remove \(shellQuote(name))")
            return ("这家 MCP 连不上：\(errorMessage(error))\n已撤掉刚才的添加，没有落盘。", false)
        }

        if !confirm {
            // 探完就撤：确认环节必须主人点头，不默认落盘。
            _ = try? await runCLI("minis-mcp-cli remove \(shellQuote(name))")
            let list = describeTools(tools)
            return ("""
            已探到这家 MCP，可以接，但还没落盘：
            名字：\(name)
            地址：\(url)
            工具（\(tools.count) 个）：
            \(list)

            请主人确认：接吗？主人点头后，我再调一次 add_mcp（参数完全一样，再加 confirm=true）——那时手机上会弹框，还必须主人亲手点「允许」才真接入。
            """, true)
        }

        // P1-3：confirm=true 只是回执，不当权限。落盘前必须主人亲手确认。
        let ok = await ownerConfirm(
            toolName: "add_mcp",
            instruction: "接入 MCP「\(name)」(\(url))，\(tools.count) 个工具")
        if !ok {
            _ = try? await runCLI("minis-mcp-cli remove \(shellQuote(name))")
            return ("主人没点头（拒绝/超时/人不在手机旁），这家 MCP 没有落盘，已撤掉。", false)
        }

        await afterChange()
        return ("已接入 MCP「\(name)」（\(tools.count) 个工具）。小管家的「搜」现在能搜到它们，外部 AI 经「命令」也能点名调用（敏感工具执行前会弹框请主人确认）。", true)
    }

    // MARK: list_mcp

    private static func listMCP() async -> (String, Bool) {
        let servers = await MainActor.run { MCPStore.shared.servers }
        if servers.isEmpty {
            return ("小管家还没接入任何 MCP。主人发个 MCP 链接，我来走接入流程（先探、请主人确认再接）。", true)
        }
        var lines: [String] = []
        for s in servers {
            var toolCount = 0
            if s.enabled {
                // 工具数走缓存/daemon，不强制刷，列个大概。
                if let tools = try? await MCPAggregator().fetchTools(serverId: s.id) {
                    toolCount = tools.count
                }
            }
            let state = s.enabled ? "启用中" : "已停用"
            lines.append("- \(s.id)（\(state)，\(toolCount) 个工具）\n  地址：\(s.url)")
        }
        return ("小管家已接入的 MCP（\(servers.count) 家）：\n" + lines.joined(separator: "\n"), true)
    }

    // MARK: remove_mcp

    private static func removeMCP(args: [String: Any]) async -> (String, Bool) {
        let name = ((args["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty
        else { return ("Error: name 必填。", false) }
        let confirm = (args["confirm"] as? Bool) ?? false

        let known = await MainActor.run {
            MCPStore.shared.servers.contains(where: { $0.id == name })
        }
        guard known else { return ("Error: 没有叫「\(name)」的 MCP。用 list_mcp 看看都接了谁。", false) }

        if !confirm {
            var tools: [[String: Any]] = []
            if let out = try? await runCLI("minis-mcp-cli tools \(shellQuote(name))"),
               let env = try? parseEnvelope(out) {
                tools = (env["tools"] as? [[String: Any]]) ?? []
            }
            return ("""
            准备移除 MCP「\(name)」，但还没删：
            它的工具（\(tools.count) 个）：
            \(describeTools(tools))

            请主人确认：删吗？删掉后这家的工具会从「搜」和「命令」里下掉。主人点头后，我再调一次 remove_mcp（name=\(name)，再加 confirm=true）——那时手机上会弹框，还必须主人亲手点「允许」才真删。
            """, true)
        }

        // P1-3：confirm=true 只是回执，不当权限。删除前必须主人亲手确认。
        let ok = await ownerConfirm(
            toolName: "remove_mcp",
            instruction: "移除 MCP「\(name)」")
        if !ok {
            return ("主人没点头（拒绝/超时/人不在手机旁），这家 MCP 还在，没删。", false)
        }

        do {
            _ = try await runCLI("minis-mcp-cli remove \(shellQuote(name))")
        } catch {
            return ("删除失败：\(errorMessage(error))", false)
        }
        await afterChange()
        return ("已移除 MCP「\(name)」，它的工具已从「搜」和「命令」里下掉。", true)
    }

    // MARK: toggle_mcp

    private static func toggleMCP(args: [String: Any]) async -> (String, Bool) {
        let name = ((args["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty
        else { return ("Error: name 必填。", false) }
        guard let enabled = args["enabled"] as? Bool else {
            return ("Error: enabled 必填（true=启用，false=停用）。", false)
        }
        let known = await MainActor.run {
            MCPStore.shared.servers.contains(where: { $0.id == name })
        }
        guard known else { return ("Error: 没有叫「\(name)」的 MCP。用 list_mcp 看看都接了谁。", false) }

        do {
            _ = try await runCLI("minis-mcp-cli \(enabled ? "enable" : "disable") \(shellQuote(name))")
        } catch {
            return ("切换失败：\(errorMessage(error))", false)
        }
        await afterChange()
        if enabled {
            return ("已启用 MCP「\(name)」，它的工具回到「搜」和「命令」里了。", true)
        } else {
            return ("已停用 MCP「\(name)」，它的工具暂时从「搜」和「命令」里下掉了（配置保留，随时可再启用）。", true)
        }
    }

    // MARK: - 小杂项

    /// 手机侧确认：落盘/删除这类不可逆操作，`confirm` 参数只是模型说
    /// "主人点了头"的回执，不当权限。真正的权限必须主人亲手在手机上
    /// 点「允许」——模型自己传 confirm=true 也过不了这道门。
    /// App 不在前台（弹不出框）按"主人不在"拒绝。
    private static func ownerConfirm(toolName: String, instruction: String) async -> Bool {
        let decision = await StewardSensitiveApprovalGate().requestApproval(
            toolName: toolName, instruction: instruction, caller: "对话 AI")
        return decision == .approved
    }

    private static func errorMessage(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return error.localizedDescription
    }
}
