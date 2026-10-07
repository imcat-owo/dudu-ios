import Foundation
import BridgeCore

/// 蓝牙工具（合并第 19 条）：接 NativeOffloads 的 `apple-bluetooth` 现成实现（BLE）。
/// 子命令：status / scan / connect / disconnect / services / read / write / notify。
///
/// 现有实现的能力边界（如实）：它管理的是「经这个工具连上的那一台 BLE 设备」——
/// status 里的已连接设备指它自己连着的那台，不是系统蓝牙设置里所有已配对/
/// 已连接设备（经典蓝牙耳机音箱之类不在 BLE 这套接口里）。scan 能扫到的是
/// 附近在广播的 BLE 设备。
enum BluetoothDeviceTool {
    static let toolName = "device_bluetooth"
    static let commandName = "apple-bluetooth"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "蓝牙（BLE）：扫描附近蓝牙设备、连接并读写设备数据",
                detail: """
                    参数 action：
                    status 看蓝牙开关状态与当前连接的设备；
                    scan 扫描附近 BLE 设备（duration 秒数默认 5，service 可按服务 UUID 过滤）；
                    connect 用扫描到的 uuid 连接一台设备；disconnect 断开；
                    services 列已连接设备的服务与特征（uuid 可省，省了用当前连接的那台）；
                    read 读特征值（uuid、service、characteristic）；write 写特征值（再加 value 十六进制或 value_string 文本）；
                    notify 订阅特征的通知一段时间（duration 秒数默认 10，必须大于 0）。
                    注意：这里管的是低功耗蓝牙（BLE）设备，不是蓝牙耳机/音箱这类经典蓝牙设备。
                    执行上限：默认 60 秒；scan/notify 按 duration 秒数＋45 秒。
                    """,
                keywords: ["蓝牙", "bluetooth", "ble", "扫描设备", "蓝牙设备", "连接设备"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["status","scan","connect","disconnect","services","read","write","notify"],"description":"动作"},
                      "duration":{"type":"integer","description":"scan/notify 的秒数（scan 默认 5，notify 默认 10）"},
                      "uuid":{"type":"string","description":"设备 UUID（connect 必填，其余动作可选）"},
                      "service":{"type":"string","description":"服务 UUID"},
                      "characteristic":{"type":"string","description":"特征 UUID（read/write/notify 必填）"},
                      "value":{"type":"string","description":"write：十六进制值，如 0100"},
                      "value_string":{"type":"string","description":"write：文本值（与 value 二选一）"}},
                     "required":["action"]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            let action = arguments.string("action") ?? ""
            var tokens: [String] = [action]
            var timeout: TimeInterval = 60
            switch action {
            case "status":
                break
            case "scan":
                let duration = arguments.int("duration") ?? 5
                tokens.append("--duration")
                tokens.append(String(duration))
                OffloadToolRunner.appendString(&tokens, flag: "--service", from: arguments, key: "service")
                timeout = TimeInterval(duration) + 45
            case "connect":
                guard arguments.string("uuid") != nil else {
                    return ToolOutput(
                        text: "参数不对：connect 需要给 uuid（先用 scan 扫到设备的 UUID）。",
                        isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--uuid", from: arguments, key: "uuid")
            case "disconnect":
                OffloadToolRunner.appendString(&tokens, flag: "--uuid", from: arguments, key: "uuid")
            case "services":
                OffloadToolRunner.appendString(&tokens, flag: "--uuid", from: arguments, key: "uuid")
            case "read", "notify":
                guard arguments.string("service") != nil, arguments.string("characteristic") != nil else {
                    return ToolOutput(
                        text: "参数不对：\(action) 需要给 service（服务 UUID）和 characteristic（特征 UUID），可先用 services 查。",
                        isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--uuid", from: arguments, key: "uuid")
                OffloadToolRunner.appendString(&tokens, flag: "--service", from: arguments, key: "service")
                OffloadToolRunner.appendString(&tokens, flag: "--characteristic", from: arguments, key: "characteristic")
                if action == "notify" {
                    let duration = arguments.int("duration") ?? 10
                    guard duration > 0 else {
                        return ToolOutput(
                            text: "参数不对：notify 的 duration 必须大于 0（一直订阅到手动中断的模式在桥工具里不支持）。",
                            isError: true)
                    }
                    tokens.append("--duration")
                    tokens.append(String(duration))
                    timeout = TimeInterval(duration) + 45
                }
            case "write":
                guard arguments.string("service") != nil, arguments.string("characteristic") != nil else {
                    return ToolOutput(
                        text: "参数不对：write 需要给 service（服务 UUID）和 characteristic（特征 UUID），可先用 services 查。",
                        isError: true)
                }
                if arguments.string("value") == nil, arguments.string("value_string") == nil {
                    return ToolOutput(
                        text: "参数不对：write 需要给 value（十六进制）或 value_string（文本）其中一个。",
                        isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--uuid", from: arguments, key: "uuid")
                OffloadToolRunner.appendString(&tokens, flag: "--service", from: arguments, key: "service")
                OffloadToolRunner.appendString(&tokens, flag: "--characteristic", from: arguments, key: "characteristic")
                OffloadToolRunner.appendString(&tokens, flag: "--value", from: arguments, key: "value")
                OffloadToolRunner.appendString(&tokens, flag: "--value-string", from: arguments, key: "value_string")
            default:
                return ToolOutput(
                    text: "参数不对：action 只能是 status / scan / connect / disconnect / services / read / write / notify。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: timeout)
        }
    }
}
