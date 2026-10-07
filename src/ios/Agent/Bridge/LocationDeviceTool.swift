import Foundation
import BridgeCore

/// 定位工具（合并第 19 条）：接 NativeOffloads 的 `apple-location` 现成实现。
/// 子命令：current（当前位置）/ geocode（经纬度→地址）/ forward（地址→经纬度）。
///
/// 拆两个工具：`device_location` 只做坐标与地址互换（geocode / forward），
/// 标准级；`device_location_current` 查当前 GPS 位置——精确位置属隐私，
/// 标敏感级，未经主人确认不执行。
enum LocationDeviceTool {
    static let toolName = "device_location"
    static let currentToolName = "device_location_current"
    static let commandName = "apple-location"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "定位换算：在地址与经纬度之间换算",
                detail: """
                    参数 action：geocode 把经纬度换成地址（需 lat、lng），
                    forward 把地址换成经纬度（需 address）。
                    查手机当前位置请用 device_location_current 工具（需主人确认）。
                    执行上限 45 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
                    """,
                keywords: ["定位", "经纬度", "地址", "location", "gps", "geocode", "坐标"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["geocode","forward"],"description":"动作"},
                      "lat":{"type":"number","description":"geocode 的纬度"},
                      "lng":{"type":"number","description":"geocode 的经度"},
                      "address":{"type":"string","description":"forward 要换算的地址文字"}},
                     "required":["action"]}
                    """#
            )
        ) { arguments in
            let action = arguments.string("action") ?? ""
            var tokens: [String] = [action]
            switch action {
            case "geocode":
                guard arguments.double("lat") != nil, arguments.double("lng") != nil else {
                    return ToolOutput(
                        text: "参数不对：geocode 需要同时给 lat（纬度）和 lng（经度）。",
                        isError: true)
                }
                OffloadToolRunner.appendDouble(&tokens, flag: "--lat", from: arguments, key: "lat")
                OffloadToolRunner.appendDouble(&tokens, flag: "--lng", from: arguments, key: "lng")
            case "forward":
                guard let address = arguments.string("address"), !address.isEmpty else {
                    return ToolOutput(
                        text: "参数不对：forward 需要给 address（要换算的地址文字）。",
                        isError: true)
                }
                tokens.append("--address")
                tokens.append(address)
            default:
                return ToolOutput(
                    text: "参数不对：action 只能是 geocode / forward（查当前位置请用 device_location_current）。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 45)
        }

        // 查当前位置：敏感级，调度层未带主人确认标记时不会执行到这里。
        try await registry.register(
            descriptor: ToolDescriptor(
                name: currentToolName,
                summary: "当前位置：查手机当前 GPS 位置（敏感动作，需主人确认）",
                detail: """
                    查当前 GPS 位置。可带 accuracy：best（默认）/ near / km。
                    精确位置是隐私，执行前必须经主人确认。
                    地址与经纬度互换用 device_location 工具。
                    执行上限 45 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
                    """,
                keywords: ["当前位置", "我在哪", "gps 位置", "current location", "定位", "坐标"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "accuracy":{"type":"string","enum":["best","near","km"],"description":"精度，默认 best"}}}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            var tokens: [String] = ["current"]
            OffloadToolRunner.appendString(&tokens, flag: "--accuracy", from: arguments, key: "accuracy")
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 45)
        }
    }
}
