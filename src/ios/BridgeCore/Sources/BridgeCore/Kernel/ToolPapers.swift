import Foundation

/// 工具纸条库（AI 能力说明书 · 纸条版）的运行时映射。
///
/// 内容来源：`src/ios/Agent/Bridge/ToolPapers.md`（F-manual 维护，那是源）。
/// 改纸条文字时两边同步：先改 md，再把正文抄到这里。
/// 选内嵌字典、不运行时解析 md：编译期保证按工具名可取，md 格式变了也不崩不丢。
/// 纸条 1（搜和命令的用法）没有对应工具名，v1 不参与按工具触发，故不在此映射。
enum ToolPapers {
    // MARK: - 纸条正文（逐字抄自 ToolPapers.md，去掉标题行与"相关话题"软提示行）

    /// 纸条 2：报问题 report_issue
    private static let reportIssue = """
        什么时候调：主人明确说了哪里有问题/不好用、报错了才调。主人只是在问怎么用、提意见但没说"这是问题"时，先问一句再调，不要自作主张发出去。

        分 3 步：
        1. 调 report_issue：title 必填（一句话说清是什么问题，比如"深色模式下输入框看不清"）；detail 可选（主人原话，尽量原样转述，别改写、别脑补；主人没细说就留空，不要编）。
        2. 工具自动附上发送时的小快照（App 版本、系统版本、发送时间、小管家当时在忙的任务）和最近的共享事件日志片段，不用另外传。同一内容 15 分钟内不会重复发——超时以为没发出去时，直接重发一次就行，不会建出第二条 Issue。
        3. 发完之后：工具会返回 Issue 编号和链接，一定要转述给主人（比如"已发到 GitHub，编号 #123，链接 https://…"），让主人知道去哪看。

        办不成时跟主人说什么：
        - 工具报"令牌还没填"：跟主人说去"设置 > 桥·对外连接 > 报问题到 GitHub"里粘贴令牌（需要对 imcat-owo/OpenMinis 有 Issues 写权限的 fine-grained PAT），不要反复重试。
        - 这是敏感动作：执行前手机上会弹框，主人点了"允许"才发；主人超时没点或不在手机旁就按拒绝处理（见本工具附带的第二条纸条：敏感工具审批流）。
        """

    /// 纸条 3：敏感工具审批流（device_photos_delete、report_issue 共用）
    private static let sensitiveApproval = """
        哪些工具是敏感的：device_photos_delete（删照片）、report_issue（发 Issue）。简介里写了"敏感动作，需主人确认"的就是。

        外部 AI 发起敏感动作后会发生什么（按已合并的手机侧签发口径）：
        1. 你调「命令」让小管家执行敏感工具，小管家不会直接执行，先请手机侧审批。
        2. 主人在手机前台：手机上弹框"小管家请求执行敏感操作"，主人点"允许"才执行，点"拒绝"就不执行；120 秒没点按拒绝处理。
        3. 主人不在手机旁（App 不在前台）：直接按"主人不在"拒绝，不排队、不等待。
        4. 传 sensitiveApproved=true 没用——这个参数已作废，真正的确认只能由手机侧弹框签发，防外部 AI 自己给自己批。

        AI 该怎么跟主人说：
        - 动手前先告诉主人："我要做 X（比如删这几张照片／把这个问题发到 GitHub），需要你在手机上点一下确认。"让主人有预期去看手机。
        - 收到"未获批准，已拒绝"：停手，如实说"主人没在手机上确认，这事没办"，不要反复重试刷屏。
        - 收到"主人未在手机旁，已拒绝"：跟主人说"我刚才想做 X，但你不在手机旁，系统按拒绝处理了；你在手机旁时跟我说一声，我再办。"

        执行上限 120 秒（中继转发上限说明同 device_photos）。
        """

    /// 纸条 4：device_bluetooth 蓝牙
    private static let bluetooth = """
        先知道：这里管的是低功耗蓝牙（BLE）设备，**不是**蓝牙耳机/音箱这类经典蓝牙设备。想连耳机音箱别用这个。

        分步（每步调一次，action 换值）：
        1. `action=status`：看蓝牙开关状态和当前连着的设备。
        2. `action=scan`：扫附近 BLE 设备（duration 秒数，默认 5）。先扫，才能拿到设备的 uuid。
        3. `action=connect`：用扫到的 uuid 连一台设备（uuid 必填）。
        4. `action=services`：列已连设备的服务和特征（uuid 可省，省了就用当前连的那台；先查，才能拿到 service 和 characteristic 的 UUID）。
        5. `action=read`：读特征值（service＋characteristic 必填）；`action=write`：写特征值（再加 value 十六进制或 value_string 文本，二选一）；`action=notify`：订阅特征通知一段时间（duration 默认 10 秒）。
        6. `action=disconnect`：断开（uuid 可省）。

        参数速查：action（必填，上面 8 个值）；uuid（connect 必填）；service、characteristic（read/write/notify 必填）；duration（整数，scan 默认 5，notify 默认 10）；value（十六进制文本）/value_string（普通文本）写操作二选一。

        执行上限：默认 60 秒；scan/notify 按 duration 秒数＋45 秒。
        """

    /// 纸条 5：device_clipboard 剪贴板
    private static let clipboard = """
        4 个动作，一次调一个：
        - `action=get`（默认）：读剪贴板。带 image（沙箱内图片路径，如 /var/minis/attachments/a.png）就是把剪贴板里的图片存到该路径。
        - `action=set`：写入。text（要写的文字）和 image（该路径的图片复制进剪贴板）至少给一个。
        - `action=clear`：清空。`action=status`：看剪贴板里有什么类型的内容。

        已知小坑（已报给 F-device）：参数表把 action 标成"必填"，但不传默认就是 get——传了最稳，别被"必填"两个字吓住。

        执行上限 30 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
        """

    /// 纸条 6：device_location 定位
    private static let location = """
        3 个动作：
        - `action=current`（默认）：查当前 GPS 位置。可带 accuracy：best（最准，默认）/near/km。
        - `action=geocode`：经纬度换成地址。lat（纬度）＋lng（经度）必填，两个都要给。
        - `action=forward`：地址换成经纬度。address（地址文字）必填。

        注意：这里经度叫 **lng**；相册按位置找照片（device_photos 的 near）里经度叫 **lon**，别混了，照各工具的参数名填。

        执行上限 45 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
        """

    /// 纸条 7：device_notification 本地通知
    private static let notification = """
        查看类（直接调）：`action=pending` 看待触发的通知；`action=delivered` 看已送达的；`action=settings` 看通知授权状态。

        安排一条（`action=schedule`）：
        - title（标题）/body（正文）至少给一个；after（多少秒后，整数）或 at（ISO 时间，如 2026-10-01T09:00:00）至少给一个。
        - repeat=true 是重复提醒：配 at 就是每天该时刻响，配 after 就是每 N 秒响（N 最短 60）。
        - action_spec 可带交互按钮，格式"按钮名:id"逗号分隔，如 "继续:continue,停止:stop"。

        取消（`action=cancel`）：id 指定取消一条，或 all=true 全部取消。id 从哪来：先调 pending 看待触发列表（F-device 确认 schedule 返回是否带 id 后，这里同步更新）。

        排完后跟主人说一声什么时候会响、内容是什么，让主人心里有数。

        执行上限 30 秒：「命令」口的 timeoutSeconds 传更大也不会延长，以这个为准。
        """

    /// 纸条 8：device_photos 相册
    private static let photos = """
        查：
        - `action=list`：列最近照片/视频（limit 上限默认 100；type=photo/video/all；start/end 日期；days 最近 N 天）。
        - `action=near`：找某经纬度附近的照片（lat＋lon 必填，radius 半径公里默认 1；注意这里经度叫 lon）。
        - `action=albums`：列相册（type=user/smart/all）；`action=album`：看某个相册里的内容（id 或 name，limit）。
        - `action=stats`：相册统计。

        导进导出：
        - `action=export`：导出一张到 /var/minis/offloads/（id 必填，size=thumb/medium/original 默认 original）。导出后拿那个路径去用（发给主人看、接着处理）。
        - `action=import`：把沙箱里的图片/视频文件存进相册（path 必填，可带 album 或 album_name，没有会新建）。
        - `action=create-album`：新建相册（name 必填）。
        - `action=add-to-album`：把已有照片（assets 逗号分隔 id）或文件（paths 逗号分隔路径）加进相册（album 或 album_name 必填其一）。
        - `action=favorite`：收藏/取消收藏一张（id 必填）。

        删照片不用这个，用 device_photos_delete（有单独纸条，要主人确认）。

        id 从哪来：先调 list 或 albums 查到 id，再拿 id 办后面的事。

        执行上限 120 秒；注意「命令」口的中继转发上限是 60 秒，传超 60 秒的超时第一次必吃 504。
        """

    /// 纸条 9：device_photos_delete 删照片
    private static let photosDelete = """
        分 3 步：
        1. 先用 device_photos 的 list 查到要删的照片 id，跟主人核对一遍删哪几张（别删错，删了进系统删除流程）。
        2. 调 device_photos_delete，ids 填逗号分隔的照片 id。
        3. 这是敏感动作，走审批流（见本工具附带的第二条纸条：敏感工具审批流）：主人要在手机上点"允许"才真删；被拒绝就停手，如实跟主人说。

        跟主人说什么：动手前说"我准备删这几张（把标题/时间列出来），需要你在手机上点确认"；删完说"删好了"；被拒绝就说"没删，你没确认/不在手机旁"。
        """

    // MARK: - 工具名 → 纸条

    /// 工具名 → 该工具的纸条（按顺序）。敏感工具带两条：本工具纸条＋审批流纸条
    /// （纸条正文里写了"见审批流纸条"，不附会断裂）。
    private static let papersByTool: [String: [String]] = [
        "report_issue": [reportIssue, sensitiveApproval],
        "device_photos_delete": [photosDelete, sensitiveApproval],
        "device_bluetooth": [bluetooth],
        "device_clipboard": [clipboard],
        "device_location": [location],
        "device_notification": [notification],
        "device_photos": [photos],
    ]

    /// 取某工具的纸条正文（按顺序）。没有纸条返回空数组——调用方行为零变化。
    static func papers(for toolName: String) -> [String] {
        papersByTool[toolName] ?? []
    }

    /// 附在「搜」结果 / 「命令」报错后面的纸条块。没有纸条返回 nil。
    /// 格式：每条纸条一个【纸条·工具名】块，多条之间空行分隔。
    static func paperBlock(for toolName: String) -> String? {
        let list = papers(for: toolName)
        guard !list.isEmpty else { return nil }
        return list.map { "【纸条·\(toolName)】\n\($0)" }.joined(separator: "\n\n")
    }
}
