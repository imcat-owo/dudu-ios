import Foundation
import BridgeCore

/// 桥工具 → `apple-*` 沙箱命令的统一执行管线（合并第 19 条）。
///
/// 五样设备能力（剪贴板/定位/通知/相册/蓝牙）在 OpenMinis 里早有现成实现：
/// NativeOffloads 里的 `apple-*` 命令，输出统一 JSON 信封
/// `{ok, tool, action, data}` / `{ok:false, error:{code, message}}`。
/// 本管线只做接线，不重写任何实现：
///   1. 权限关卡——照 App 内对话的现行做法（AIChatViewModel+ConcurrentTools）：
///      命令在 OffloadPermissionManager 登记表内时先过 `checkPermission`，
///      被拒直接回中文提示，不执行；
///   2. 经 ISHExecutionCoordinator 在专用会话里执行命令（非聊天调用方的
///      现行做法，参考 MCPStore 的固定会话 id）；
///   3. 解析 JSON 信封：成功回 data，失败按错误码翻成中文友好提示，
///      原始 message 附在后面方便定位，绝不静默吞错。
enum OffloadToolRunner {

    /// 桥工具专用的沙箱会话 id（与聊天会话隔离，权限的 Ask Once 授权也独立记账）。
    static let bridgeSessionId = "bridge-device-tools"

    private static let logger = AppLogger(category: "BridgeDeviceTools")

    /// POSIX sh 单引号引用：token 里有单引号时用 '\'' 转义。
    static func shellQuote(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 参数 → token 的小工具（各工具文件共用）

    static func appendString(_ tokens: inout [String], flag: String, from args: StrictJSONObject, key: String) {
        if let value = args.string(key), !value.isEmpty {
            tokens.append(flag)
            tokens.append(value)
        }
    }

    static func appendInt(_ tokens: inout [String], flag: String, from args: StrictJSONObject, key: String) {
        if let value = args.int(key) {
            tokens.append(flag)
            tokens.append(String(value))
        }
    }

    static func appendDouble(_ tokens: inout [String], flag: String, from args: StrictJSONObject, key: String) {
        if let value = args.double(key) {
            tokens.append(flag)
            tokens.append(String(value))
        }
    }

    /// 布尔参数为 true 时才加的无值 flag（如 --all、--repeat）。
    static func appendSwitch(_ tokens: inout [String], flag: String, from args: StrictJSONObject, key: String) {
        if args.bool(key) == true {
            tokens.append(flag)
        }
    }

    /// 执行一条 apple-* 命令。
    /// - Parameters:
    ///   - commandName: 命令名，如 "apple-clipboard"。
    ///   - tokens: 子命令与参数 token（原值，管线负责逐个 shell 引用）。
    ///   - timeout: 超时秒数；扫描/订阅类长动作由调用方按时长给足。
    static func run(commandName: String, tokens: [String], timeout: TimeInterval = 60) async -> ToolOutput {
        // 每个 token 都单引号引用（引号不改变 flag/子命令的含义，
        // 但能挡住值里的空格、引号与以 -- 开头的值被 shell 误解析）。
        let commandLine = ([commandName] + tokens.map(shellQuote) + ["--compact"])
            .joined(separator: " ")

        // 1. 权限关卡：只对登记表内的命令生效（与聊天流的判断完全一致——
        //    extractOffloadCommand 命中才查。[batch7 用户-P2-1] apple-bluetooth
        //    已登记进权限表（隐私类），这里和聊天流都会走权限关卡。
        if await OffloadPermissionManager.extractOffloadCommand(from: commandName) != nil {
            let permission = await OffloadPermissionManager.shared.checkPermission(
                for: commandName, sessionId: bridgeSessionId, fullCommand: commandLine)
            if case .denied(let message) = permission {
                logger.info("权限被拒：\(commandName) — \(message)")
                return ToolOutput(
                    text: "权限不足，这次没有执行。\(chinesePermissionHint(message))",
                    isError: true)
            }
        }

        // 2. 执行。
        let result: ISHCommandResult
        do {
            result = try await ISHExecutionCoordinator.shared.execute(
                sessionId: bridgeSessionId,
                command: commandLine,
                timeout: timeout,
                lineCallback: { _ in },
                pidCallback: { _ in })
        } catch ISHCoordinatorError.kernelNotBooted {
            return ToolOutput(
                text: "沙箱还没启动：请先在 App 里打开一次终端页，等沙箱初始化完成后再试。",
                isError: true)
        } catch {
            logger.warning("命令执行失败 \(commandName)：\(error.localizedDescription)")
            return ToolOutput(
                text: "命令执行失败：\(error.localizedDescription)",
                isError: true)
        }

        // 3. 解析信封。
        return parseEnvelope(output: result.output, exitCode: result.exitCode, commandName: commandName)
    }

    /// 把 OffloadPermissionManager 的英文拒绝文案翻成中文提示（原意不变，
    /// 设置入口的深链保留在文案末尾，方便主人点开改权限）。
    private static func chinesePermissionHint(_ original: String) -> String {
        if original.contains("has disabled") {
            return "主人在设置里把这项能力关掉了。要开启：设置 > 权限，或点开 [打开权限设置](minis-clone://settings/permissions)"
        }
        if original.contains("timed out") {
            return "刚才的授权询问超时了，请重试一次并在弹窗里确认。要改设置：[打开权限设置](minis-clone://settings/permissions)"
        }
        if original.contains("declined") {
            return "主人刚才在授权弹窗里拒绝了这一次。要改设置：[打开权限设置](minis-clone://settings/permissions)"
        }
        return original
    }

    /// 解析 apple-* 命令的 JSON 信封输出。
    static func parseEnvelope(output: String, exitCode: Int, commandName: String) -> ToolOutput {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start <= end,
              let data = String(output[start...end]).data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = dict["ok"] as? Bool
        else {
            // 没有信封：原样回输出（清洗层会再处理），非零退出码按失败报。
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if exitCode != 0 {
                return ToolOutput(
                    text: trimmed.isEmpty ? "命令 \(commandName) 执行失败（退出码 \(exitCode)，无输出）" : trimmed,
                    isError: true)
            }
            return ToolOutput(text: trimmed.isEmpty ? "（命令执行成功，无输出）" : trimmed)
        }

        if ok {
            guard let payload = dict["data"] else {
                return ToolOutput(text: "（执行成功，无返回数据）")
            }
            if let text = payload as? String {
                return ToolOutput(text: text)
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let text = String(data: jsonData, encoding: .utf8) {
                return ToolOutput(text: text)
            }
            return ToolOutput(text: "\(payload)")
        }

        let errorDict = dict["error"] as? [String: Any]
        let code = errorDict?["code"] as? String ?? "internal_error"
        let message = errorDict?["message"] as? String ?? "未知错误"
        return ToolOutput(text: friendlyError(code: code, message: message), isError: true)
    }

    /// 信封错误码 → 中文友好提示，原始 message 随后附上（不吞关键信息）。
    private static func friendlyError(code: String, message: String) -> String {
        switch code {
        case "authorization_denied":
            return "系统权限被拒绝：\(message)（请在 iOS 设置里给本 App 开启对应权限后重试）"
        case "authorization_not_determined":
            return "系统权限还没授权：\(message)（请先在 App 里用一次这项功能、完成授权弹窗后重试）"
        case "not_available":
            return "这项能力现在不可用：\(message)"
        case "invalid_args":
            return "参数不对：\(message)"
        case "no_data":
            return "没有查到数据：\(message)"
        default:
            return "执行失败（\(code)）：\(message)"
        }
    }
}
