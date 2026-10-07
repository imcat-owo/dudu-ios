import Foundation
import BridgeCore

/// 剪贴板工具（合并第 19 条）：接 NativeOffloads 的 `apple-clipboard` 现成实现。
/// 子命令：get / set / clear / status。
///
/// 拆两个工具：`device_clipboard` 是写入与管理（set / clear / status），
/// 标准级；`device_clipboard_read` 只做 get 读剪贴板——读可能撞见主人刚
/// 复制的密码、验证码这类敏感内容，标敏感级，未经主人确认不执行。
enum ClipboardDeviceTool {
    static let toolName = "device_clipboard"
    static let readToolName = "device_clipboard_read"
    static let commandName = "apple-clipboard"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "剪贴板：写入、清空或查看手机剪贴板状态",
                detail: """
                    参数 action：set 写入，clear 清空，status 看剪贴板里有什么类型的内容。
                    set 时 text 必填；set 可带 image（沙箱内图片路径）把该路径的图片复制进剪贴板。
                    读剪贴板内容请用 device_clipboard_read 工具（需主人确认）。
                    执行上限 30 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
                    """,
                keywords: ["剪贴板", "粘贴", "复制", "clipboard", "pasteboard", "拷贝"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["set","clear","status"],"description":"动作，默认 status"},
                      "text":{"type":"string","description":"set 时要写入剪贴板的文字"},
                      "image":{"type":"string","description":"set：沙箱内图片路径，如 /var/minis/attachments/a.png"}},
                     "required":["action"]}
                    """#
            )
        ) { arguments in
            let action = arguments.string("action") ?? "status"
            var tokens: [String] = [action]
            switch action {
            case "set":
                OffloadToolRunner.appendString(&tokens, flag: "--text", from: arguments, key: "text")
                OffloadToolRunner.appendString(&tokens, flag: "--image", from: arguments, key: "image")
                if arguments.string("text") == nil, arguments.string("image") == nil {
                    return ToolOutput(
                        text: "参数不对：set 需要给 text（要写入的文字）或 image（图片路径）至少一个。",
                        isError: true)
                }
            case "clear", "status":
                break
            default:
                return ToolOutput(
                    text: "参数不对：action 只能是 set / clear / status（读剪贴板请用 device_clipboard_read）。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }

        // 读剪贴板：敏感级，调度层未带主人确认标记时不会执行到这里。
        try await registry.register(
            descriptor: ToolDescriptor(
                name: readToolName,
                summary: "剪贴板读取：读手机剪贴板里的文字（敏感动作，需主人确认）",
                detail: """
                    读剪贴板当前内容。可带 image（沙箱内图片路径）：把剪贴板里的图片存到该路径。
                    剪贴板里可能有主人刚复制的密码、验证码，执行前必须经主人确认。
                    写入/清空/看状态用 device_clipboard 工具。
                    执行上限 30 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
                    """,
                keywords: ["读剪贴板", "剪贴板内容", "clipboard read", "粘贴板", "复制的内容"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "image":{"type":"string","description":"沙箱内图片路径：把剪贴板里的图片存到该路径"}}}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            var tokens: [String] = ["get"]
            OffloadToolRunner.appendString(&tokens, flag: "--image", from: arguments, key: "image")
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }
    }
}
