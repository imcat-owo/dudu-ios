import Foundation
import BridgeCore

/// 相册工具（合并第 19 条）：接 NativeOffloads 的 `apple-photos` 现成实现。
///
/// 拆三个工具：
/// - `device_photos`：只读查询（list / near / albums / album / stats），标准级；
/// - `device_photos_write`：写动作（export / import / create-album /
///   add-to-album / favorite），敏感级——按定稿安全规矩，改动用户数据的动作
///   未经主人确认（调度层带确认标记）不执行；
/// - `device_photos_delete`：删除，敏感级（原有）。
enum PhotosDeviceTool {
    static let toolName = "device_photos"
    static let writeToolName = "device_photos_write"
    static let deleteToolName = "device_photos_delete"
    static let commandName = "apple-photos"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "相册查询：查照片视频、相册列表与统计",
                detail: """
                    只读动作，参数 action：
                    list 列最近照片/视频（limit 上限、type photo/video/all、start/end 日期、days 最近 N 天）；
                    near 找某经纬度附近的照片（lat、lon 必填，radius 半径公里，limit）；
                    albums 列相册（type user/smart/all）；album 列某个相册里的内容（id 或 name，limit）；
                    stats 相册统计。
                    写动作（导出/导入/建相册/加进相册/收藏）请用 device_photos_write 工具（需主人确认）；
                    删除照片用 device_photos_delete 工具（需主人确认）。
                    执行上限 120 秒；注意「命令」口的中继转发上限是 60 秒，传超 60 秒的超时第一次必吃 504。
                    """,
                keywords: ["相册", "照片", "图片", "视频", "photos", "album", "图库"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["list","near","albums","album","stats"],"description":"动作"},
                      "limit":{"type":"integer","description":"最多返回条数，默认 100"},
                      "type":{"type":"string","description":"list：photo/video/all；albums：user/smart/all"},
                      "start":{"type":"string","description":"list：起始日期时间"},
                      "end":{"type":"string","description":"list：结束日期时间"},
                      "days":{"type":"integer","description":"list：最近 N 天"},
                      "lat":{"type":"number","description":"near：纬度"},
                      "lon":{"type":"number","description":"near：经度"},
                      "radius":{"type":"number","description":"near：半径（公里），默认 1"},
                      "id":{"type":"string","description":"album：目标标识"},
                      "name":{"type":"string","description":"album 按名找"}},
                     "required":["action"]}
                    """#
            )
        ) { arguments in
            let action = arguments.string("action") ?? ""
            var tokens: [String] = [action]
            switch action {
            case "list":
                OffloadToolRunner.appendInt(&tokens, flag: "--limit", from: arguments, key: "limit")
                OffloadToolRunner.appendString(&tokens, flag: "--type", from: arguments, key: "type")
                OffloadToolRunner.appendString(&tokens, flag: "--start", from: arguments, key: "start")
                OffloadToolRunner.appendString(&tokens, flag: "--end", from: arguments, key: "end")
                OffloadToolRunner.appendInt(&tokens, flag: "--days", from: arguments, key: "days")
            case "near":
                guard arguments.double("lat") != nil, arguments.double("lon") != nil else {
                    return ToolOutput(
                        text: "参数不对：near 需要同时给 lat（纬度）和 lon（经度）。",
                        isError: true)
                }
                OffloadToolRunner.appendDouble(&tokens, flag: "--lat", from: arguments, key: "lat")
                OffloadToolRunner.appendDouble(&tokens, flag: "--lon", from: arguments, key: "lon")
                OffloadToolRunner.appendDouble(&tokens, flag: "--radius", from: arguments, key: "radius")
                OffloadToolRunner.appendInt(&tokens, flag: "--limit", from: arguments, key: "limit")
            case "albums":
                OffloadToolRunner.appendString(&tokens, flag: "--type", from: arguments, key: "type")
            case "album":
                if arguments.string("id") == nil, arguments.string("name") == nil {
                    return ToolOutput(
                        text: "参数不对：album 需要给 id（相册标识）或 name（相册名）至少一个。",
                        isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--id", from: arguments, key: "id")
                OffloadToolRunner.appendString(&tokens, flag: "--name", from: arguments, key: "name")
                OffloadToolRunner.appendInt(&tokens, flag: "--limit", from: arguments, key: "limit")
            case "stats":
                break
            default:
                return ToolOutput(
                    text: "参数不对：action 不在只读列表内（写动作请用 device_photos_write，删除照片请用 device_photos_delete）。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 120)
        }

        // 写动作：敏感级，调度层未带主人确认标记时不会执行到这里。
        // export 导出原图虽不改动图库，但会把原图拷出沙箱外，属于隐私外泄类动作，一并收紧。
        try await registry.register(
            descriptor: ToolDescriptor(
                name: writeToolName,
                summary: "相册写入：导出原图、导入图片、建相册、收藏（敏感动作，需主人确认）",
                detail: """
                    参数 action：
                    export 导出一张到 /var/minis/offloads/（id 必填，size thumb/medium/original）；
                    import 把沙箱里的图片/视频文件存进相册（path 必填，可带 album 或 album_name）；
                    create-album 新建相册（name 必填）；
                    add-to-album 把已有照片（assets 逗号分隔 id）或文件（paths 逗号分隔路径）加进相册（album 或 album_name 必填其一）；
                    favorite 收藏/取消收藏一张（id 必填）。
                    只读查询用 device_photos 工具；删除用 device_photos_delete 工具。
                    执行上限 120 秒；注意「命令」口的中继转发上限是 60 秒，传超 60 秒的超时第一次必吃 504。
                    """,
                keywords: ["相册写入", "导入照片", "导出原图", "建相册", "收藏照片", "photos write", "导入", "导出"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "action":{"type":"string","enum":["export","import","create-album","add-to-album","favorite"],"description":"动作"},
                      "id":{"type":"string","description":"export/favorite：目标标识"},
                      "size":{"type":"string","enum":["thumb","medium","original"],"description":"export 的尺寸，默认 original"},
                      "path":{"type":"string","description":"import：要存进相册的文件路径"},
                      "album":{"type":"string","description":"import/add-to-album：目标相册 id"},
                      "album_name":{"type":"string","description":"import/add-to-album：目标相册名（没有会新建）"},
                      "assets":{"type":"string","description":"add-to-album：逗号分隔的照片 id"},
                      "paths":{"type":"string","description":"add-to-album：逗号分隔的文件路径"},
                      "name":{"type":"string","description":"create-album 的相册名"}},
                     "required":["action"]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            let action = arguments.string("action") ?? ""
            var tokens: [String] = [action]
            switch action {
            case "export":
                guard arguments.string("id") != nil else {
                    return ToolOutput(text: "参数不对：export 需要给 id（照片标识）。", isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--id", from: arguments, key: "id")
                OffloadToolRunner.appendString(&tokens, flag: "--size", from: arguments, key: "size")
            case "import":
                guard arguments.string("path") != nil else {
                    return ToolOutput(text: "参数不对：import 需要给 path（文件路径）。", isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--path", from: arguments, key: "path")
                OffloadToolRunner.appendString(&tokens, flag: "--album", from: arguments, key: "album")
                OffloadToolRunner.appendString(&tokens, flag: "--album-name", from: arguments, key: "album_name")
            case "create-album":
                guard arguments.string("name") != nil else {
                    return ToolOutput(text: "参数不对：create-album 需要给 name（相册名）。", isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--name", from: arguments, key: "name")
            case "add-to-album":
                if arguments.string("album") == nil, arguments.string("album_name") == nil {
                    return ToolOutput(
                        text: "参数不对：add-to-album 需要给 album（相册 id）或 album_name（相册名）。",
                        isError: true)
                }
                if arguments.string("assets") == nil, arguments.string("paths") == nil {
                    return ToolOutput(
                        text: "参数不对：add-to-album 需要给 assets（照片 id）或 paths（文件路径）至少一个。",
                        isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--album", from: arguments, key: "album")
                OffloadToolRunner.appendString(&tokens, flag: "--album-name", from: arguments, key: "album_name")
                OffloadToolRunner.appendString(&tokens, flag: "--assets", from: arguments, key: "assets")
                OffloadToolRunner.appendString(&tokens, flag: "--paths", from: arguments, key: "paths")
            case "favorite":
                guard arguments.string("id") != nil else {
                    return ToolOutput(text: "参数不对：favorite 需要给 id（照片标识）。", isError: true)
                }
                OffloadToolRunner.appendString(&tokens, flag: "--id", from: arguments, key: "id")
            default:
                return ToolOutput(
                    text: "参数不对：action 不在写动作列表内（只读查询请用 device_photos，删除请用 device_photos_delete）。",
                    isError: true)
            }
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 120)
        }

        // 删除：敏感级，调度层未带主人确认标记时不会执行到这里。
        try await registry.register(
            descriptor: ToolDescriptor(
                name: deleteToolName,
                summary: "相册删除：删除指定照片/视频（敏感动作，需主人确认）",
                detail: """
                    参数 ids：逗号分隔的照片/视频标识（先用 device_photos 的 list 查到 id）。
                    删除会进系统相册的删除流程，执行前必须经主人确认。
                    执行上限 120 秒；注意「命令」口的中继转发上限是 60 秒，传超 60 秒的超时第一次必吃 504。
                    """,
                keywords: ["删除照片", "删图", "delete photo", "相册删除", "照片删除"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "ids":{"type":"string","description":"逗号分隔的照片/视频标识"}},
                     "required":["ids"]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            guard let ids = arguments.string("ids"), !ids.isEmpty else {
                return ToolOutput(
                    text: "参数不对：需要给 ids（逗号分隔的照片/视频标识）。",
                    isError: true)
            }
            // --confirm 是底层命令的必填确认标记：能执行到这里说明调度层
            // 已拿到主人确认（敏感级规矩），在此补上底层要求的那道锁。
            let tokens = ["delete", "--ids", ids, "--confirm"]
            return await OffloadToolRunner.run(commandName: commandName, tokens: tokens, timeout: 120)
        }
    }
}
