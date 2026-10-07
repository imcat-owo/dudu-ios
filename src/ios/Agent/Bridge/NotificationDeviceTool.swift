import Foundation
import BridgeCore

/// 通知工具（合并第 19 条）：接 NativeOffloads 的 `apple-notification` 现成实现。
/// 子命令：pending / delivered / settings / schedule / cancel。
///
/// 拆三个工具：`device_notification` 只做查看（pending / delivered /
/// settings），标准级；`device_notification_schedule` 只做安排本地通知——
/// 会在主人手机上弹出提醒、打扰主人，标敏感级；`device_notification_cancel`
/// 只做取消——删掉她设好的提醒是破坏性动作（尤其 all=true 全清），标敏感级。
/// 两个敏感工具未经主人确认不执行。
enum NotificationDeviceTool {
    static let toolName = "device_notification"
    static let scheduleToolName = "device_notification_schedule"
    static let cancelToolName = "device_notification_cancel"
    static let commandName = "apple-notification"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "本地通知：查看手机本地通知（待触发/已送达/授权状态）",
                detail: """
                    参数 action：pending 看待触发的通知，delivered 看已送达的，settings 看通知授权状态。
                    取消通知请用 device_notification_cancel 工具（需主人确认）。
                    安排新通知请用 device_notification_schedule 工具（需主人确认）。
                    执行上限 30 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
                    """,
                keywords: ["通知", "提醒", "notification"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["pending","delivered","settings"],"description":"动作"}},
                     "required":["action"]}
                    """#
            )
        ) { arguments in
            let action = arguments.string("action") ?? ""
            switch action {
            case "pending", "delivered", "settings":
                break
            default:
                return ToolOutput(
                    text: "参数不对：action 只能是 pending / delivered / settings（取消请用 device_notification_cancel，安排请用 device_notification_schedule）。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: [action], timeout: 30)
        }

        // 取消通知：敏感级。删掉她设好的提醒是破坏性动作，尤其 all=true
        // 会清空全部待触发通知，必须经主人确认。调度层未带主人确认标记时不会执行到这里。
        try await registry.register(
            descriptor: ToolDescriptor(
                name: cancelToolName,
                summary: "取消通知：取消一条或全部待触发本地通知（敏感动作，需主人确认）",
                detail: """
                    取消本地通知。id 指定取消一条（先用 device_notification 的 pending 查到 id），
                    all=true 取消全部待触发通知。删掉设好的提醒不可恢复，执行前必须经主人确认。
                    执行上限 30 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
                    """,
                keywords: ["取消通知", "取消提醒", "删除提醒", "cancel notification"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "id":{"type":"string","description":"要取消的通知标识（用 device_notification 查）"},
                      "all":{"type":"boolean","description":"true 时取消全部待触发通知"}},
                     "required":[]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            if arguments.string("id") == nil, arguments.bool("all") != true {
                return ToolOutput(
                    text: "参数不对：cancel 需要给 id（通知标识）或 all=true（全部取消）。",
                    isError: true)
            }
            var tokens: [String] = ["cancel"]
            OffloadToolRunner.appendString(&tokens, flag: "--id", from: arguments, key: "id")
            OffloadToolRunner.appendSwitch(&tokens, flag: "--all", from: arguments, key: "all")
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }

        // 安排通知：敏感级，调度层未带主人确认标记时不会执行到这里。
        try await registry.register(
            descriptor: ToolDescriptor(
                name: scheduleToolName,
                summary: "安排通知：在手机上安排一条本地通知提醒（敏感动作，需主人确认）",
                detail: """
                    安排一条本地通知。title/body 至少给一个；时间给 after（多少秒后）或 at（ISO 时间）至少一个，
                    repeat=true 为重复提醒（配合 at 为每天该时刻，配合 after 为每 N 秒、最短 60），
                    action_spec 可带交互按钮，格式 "按钮名:id" 逗号分隔。
                    会在主人手机上弹出提醒，执行前必须经主人确认。
                    查看通知用 device_notification 工具，取消通知用 device_notification_cancel 工具。
                    执行上限 30 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
                    """,
                keywords: ["安排通知", "定时提醒", "schedule 通知", "闹钟提醒", "notification schedule"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "title":{"type":"string","description":"通知标题"},
                      "body":{"type":"string","description":"通知正文"},
                      "after":{"type":"integer","description":"多少秒后触发"},
                      "at":{"type":"string","description":"ISO 时间，如 2026-10-01T09:00:00"},
                      "repeat":{"type":"boolean","description":"是否重复（配合 at 为每天该时刻，配合 after 为每 N 秒、最短 60）"},
                      "action_spec":{"type":"string","description":"交互按钮，如 Continue:continue,Stop:stop"}},
                     "required":[]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            if arguments.string("title") == nil, arguments.string("body") == nil {
                return ToolOutput(
                    text: "参数不对：schedule 需要至少给 title（标题）或 body（正文）一个。",
                    isError: true)
            }
            if arguments.int("after") == nil, arguments.string("at") == nil {
                return ToolOutput(
                    text: "参数不对：schedule 需要给时间：after（多少秒后）或 at（ISO 时间）至少一个。",
                    isError: true)
            }
            var tokens: [String] = ["schedule"]
            OffloadToolRunner.appendString(&tokens, flag: "--title", from: arguments, key: "title")
            OffloadToolRunner.appendString(&tokens, flag: "--body", from: arguments, key: "body")
            OffloadToolRunner.appendInt(&tokens, flag: "--after", from: arguments, key: "after")
            OffloadToolRunner.appendString(&tokens, flag: "--at", from: arguments, key: "at")
            OffloadToolRunner.appendSwitch(&tokens, flag: "--repeat", from: arguments, key: "repeat")
            OffloadToolRunner.appendString(&tokens, flag: "--action", from: arguments, key: "action_spec")
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 30)
        }
    }
}
