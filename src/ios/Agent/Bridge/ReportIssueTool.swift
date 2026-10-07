import Foundation
import CryptoKit
import Security
import UIKit
import BridgeCore

/// 报问题工具（合并第 21 条）：主人在桥里张嘴说哪里有问题，小管家把
/// 问题连同发送时的小快照和相关日志打包，POST 到 GitHub 仓库
/// imcat-owo/OpenMinis 的 Issues，不用填表。
///
/// 执行端整个在 App 侧（本文件），不进 BridgeCore 内核：内核只管调度，
/// 网络与令牌都是宿主的事。敏感级（permission: .sensitive）——这是往
/// 外发东西，调度层未带主人确认标记时不会执行到这里（与第 19 条
/// 相册删除同款）。
///
/// 脱敏红线：令牌只进 Authorization 请求头，绝不进 Issue 正文、
/// 绝不进日志、绝不进报错文案。往外发的正文只有三样：主人原话、
/// 版本/时间这类环境信息、已脱敏的共享事件日志片段。
enum ReportIssueTool {
    static let toolName = "report_issue"
    static let repoFullName = "imcat-owo/OpenMinis"
    static let issuesEndpoint = "https://api.github.com/repos/imcat-owo/OpenMinis/issues"

    private static let logger = AppLogger(category: "BridgeReportIssue")

    static func register(into registry: ToolRegistry, steward: Steward) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "报问题：把 App 的问题连同发送时的情况打包发到 GitHub 问题列表",
                detail: """
                    主人说 App 哪里有问题、哪里不好用时用这个工具：把问题打包发到 \
                    GitHub 仓库 \(repoFullName) 的 Issues，主人不用填表。
                    什么时候调：主人明确说了哪里有问题、不好用、报错了才调；主人只是在问\
                    怎么用、提意见但没说"这是问题"时，先问一句再调，不要自作主张发出去。
                    参数 title（一句话问题标题，必填）：简短说清是什么问题，比如"深色模式下输入框看不清"。
                    参数 detail（主人的原话描述，可选）：尽量原样转述主人的话，别改写、别脑补；\
                    主人没细说就留空，不要编。
                    工具会自动附上发送时的小快照（App 版本、系统版本、发送时间、小管家\
                    当时在忙的任务）和最近的共享事件日志片段，不用再另外传。
                    发完之后：工具会返回 Issue 编号和链接，一定要转述给主人（比如"已发到 GitHub，\
                    编号 #123，链接 https://…"），让主人知道去哪看。
                    同一内容 15 分钟内不会重复发：超时以为没发出去时，直接重发一次就行，\
                    不会建出第二条 Issue。
                    如果设置页还没填 GitHub 令牌，工具会明确报错：这时跟主人说去"设置 > 桥·对外连接 > \
                    报问题到 GitHub"里粘贴令牌，不要反复重试。
                    这是往外发东西的敏感动作，执行前必须经主人确认（手机上弹框，主人点了"允许"才发；\
                    主人超时没点或不在手机旁就按拒绝处理）。
                    """,
                keywords: ["报问题", "反馈", "问题", "毛病", "bug", "issue", "报错", "故障", "不好用", "report"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "title":{"type":"string","description":"一句话问题标题"},
                      "detail":{"type":"string","description":"主人的原话描述（可选）"}},
                     "required":["title"]}
                    """#,
                permission: .sensitive
            )
        ) { arguments in
            guard let rawTitle = arguments.string("title") else {
                return ToolOutput(
                    text: "参数不对：需要给 title（一句话说清是什么问题）。",
                    isError: true)
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return ToolOutput(
                    text: "参数不对：title 是空的，需要一句话说清是什么问题。",
                    isError: true)
            }
            let detail = arguments.string("detail")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return await submit(
                title: String(title.prefix(200)),
                detail: (detail?.isEmpty == false) ? detail : nil,
                steward: steward)
        }
    }

    // MARK: - 去重（幂等，AI-P2-14）
    //
    // GitHub Issues API 没有幂等键：30 秒超时/网络抖动时，Issue 可能已经
    // 在 GitHub 建好了，客户端却以为失败。失败文案让主人"重发"，重发同一
    // 内容必须只得到一条 Issue，不能建第二条。
    // 做法（两层，都是客户端侧，诚实起见写清楚）：
    // ① 内存短时缓存：同一内容（标题+原话）15 分钟内只发一次；
    // ② 发之前先 GET 最近 20 条 Issues：同名且 15 分钟内建的直接复用，
    //    不再 POST——覆盖"第一次超时但 GitHub 其实建好了"的重发场景。
    private static let dedupWindow: TimeInterval = 15 * 60
    private static let dedupLock = NSLock()

    private struct SentRecord {
        let number: Int?
        let url: String?
        let at: Date
    }

    private static var recentSent: [String: SentRecord] = [:]

    /// 去重键：消毒后的标题+原话的 SHA256。
    private static func dedupKey(title: String, detail: String?) -> String {
        let raw = title + "\n" + (detail ?? "")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cachedSubmission(for key: String) -> SentRecord? {
        dedupLock.lock()
        defer { dedupLock.unlock() }
        guard let record = recentSent[key],
              Date().timeIntervalSince(record.at) < dedupWindow
        else { return nil }
        return record
    }

    private static func cacheSubmission(key: String, number: Int?, url: String?) {
        dedupLock.lock()
        defer { dedupLock.unlock() }
        recentSent[key] = SentRecord(number: number, url: url, at: Date())
        // 只留最近 50 条，防内存悄悄长大。
        if recentSent.count > 50 {
            let cutoff = Date().addingTimeInterval(-dedupWindow)
            recentSent = recentSent.filter { $0.value.at >= cutoff }
        }
    }

    private struct FoundIssue {
        let number: Int
        let url: String
    }

    /// 发之前先查重：最近 20 条 Issues 里有没有同名、且在去重窗口内建的。
    /// 查不到/查失败返回 nil，调用方照常 POST（查失败不拦正常发送）。
    private static func findRecentDuplicate(title: String, token: String) async -> FoundIssue? {
        guard let url = URL(string: issuesEndpoint + "?state=all&per_page=20") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 令牌只进请求头，和 POST 那条同口径。
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        let cutoff = Date().addingTimeInterval(-dedupWindow)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for item in list {
            guard let itemTitle = item["title"] as? String, itemTitle == title,
                  let number = item["number"] as? Int,
                  let htmlURL = item["html_url"] as? String,
                  let created = item["created_at"] as? String,
                  let createdDate = formatter.date(from: created),
                  createdDate >= cutoff
            else { continue }
            return FoundIssue(number: number, url: htmlURL)
        }
        return nil
    }

    /// 同一内容重复提交时的回话：不建新 Issue，直接给已有那条的编号/链接。
    private static func alreadySentText(number: Int?, url: String?, reused: Bool) -> ToolOutput {
        let head = reused
            ? "这条问题之前已经发到 GitHub 了，没有重复再发。"
            : "这条问题刚才已经发过一次，没有重复再发。"
        if let number, let url {
            SharedEventLog.shared.emit(
                event: "bridge.issue_reported",
                summary: "去重命中，不再重发：Issue #\(number) \(url)")
            return ToolOutput(text: """
                \(head)
                Issue 编号：#\(number)
                链接：\(url)
                请把编号和链接转述给主人。
                """)
        }
        return ToolOutput(text: "\(head)请到仓库 \(repoFullName) 的 Issues 列表里看最新一条。")
    }

    // MARK: - 执行：组装正文 → POST GitHub Issues

    private static func submit(title: String, detail: String?, steward: Steward) async -> ToolOutput {
        // 未填令牌不许假装成功：回明确提示，让主人先去设置页填。
        guard let token = BridgeGitHubTokenStore.load(), !token.isEmpty else {
            return ToolOutput(
                text: """
                    还没法发：GitHub 报问题令牌还没填。请先到 设置 > 桥·对外连接 > \
                    「报问题到 GitHub」里粘贴令牌——需要一个对 \(repoFullName) 有 \
                    Issues 写权限的 fine-grained PAT（个人访问令牌），填好后我再发。
                    """,
                isError: true)
        }

        // 标题既进 Issue 正文又进 POST 的 title 字段：先消毒再往下传。
        let safeTitle = sanitize(title)
        let safeDetail = detail.map(sanitize)

        // 去重在前：同一内容短时间内重发，不建第二条 Issue。
        let key = dedupKey(title: safeTitle, detail: safeDetail)
        if let hit = cachedSubmission(for: key) {
            return alreadySentText(number: hit.number, url: hit.url, reused: false)
        }
        if let dup = await findRecentDuplicate(title: safeTitle, token: token) {
            cacheSubmission(key: key, number: dup.number, url: dup.url)
            return alreadySentText(number: dup.number, url: dup.url, reused: true)
        }

        let body = await composeBody(title: safeTitle, detail: safeDetail, steward: steward)

        var request = URLRequest(url: URL(string: issuesEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // 令牌只在这里用：只进 Authorization 头，不进正文/日志/报错。
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["title": safeTitle, "body": body])
        } catch {
            return ToolOutput(text: "发送失败：问题内容打包出错，没能发出去。", isError: true)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 网络层错误描述不含请求头，不会带出令牌。
            logger.warning("GitHub 发 Issue 网络失败：\(error.localizedDescription)")
            return ToolOutput(
                text: "发送失败：网络连不上 GitHub（\(error.localizedDescription)）。请确认网络正常后再让我重发。超时不代表没发出去：重发同一内容时我会先查重，不会建重复的 Issue。",
                isError: true)
        }
        guard let http = response as? HTTPURLResponse else {
            return ToolOutput(text: "发送失败：GitHub 没有回正常的响应，请稍后再让我重发。", isError: true)
        }

        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if http.statusCode == 201,
           let number = parsed?["number"] as? Int,
           let htmlURL = parsed?["html_url"] as? String {
            // 成功留痕：只记编号和链接，绝不记令牌。
            cacheSubmission(key: key, number: number, url: htmlURL)
            SharedEventLog.shared.emit(
                event: "bridge.issue_reported",
                summary: "问题已发到 GitHub：Issue #\(number) \(htmlURL)")
            return ToolOutput(text: """
                已经把问题发到 GitHub 了。
                Issue 编号：#\(number)
                链接：\(htmlURL)
                请把编号和链接转述给主人。
                """)
        }

        if http.statusCode == 201 {
            // 发成功了但回执没解析出编号/链接：如实说，别误导重发造成重复。
            cacheSubmission(key: key, number: nil, url: nil)
            SharedEventLog.shared.emit(
                event: "bridge.issue_reported",
                summary: "问题已发到 GitHub（回执未解析出编号）")
            return ToolOutput(text: "已经把问题发到 GitHub 了（GitHub 回了成功，但回执里没解析出编号和链接，请到仓库 \(repoFullName) 的 Issues 列表里看最新一条）。")
        }

        logger.warning("GitHub 发 Issue 失败 status=\(http.statusCode)")
        let githubMessage = parsed?["message"] as? String
        return ToolOutput(
            text: failureText(statusCode: http.statusCode, githubMessage: githubMessage),
            isError: true)
    }

    /// 组装 Issue 正文。只有三部分：主人原话、发送时的情况（版本/时间/
    /// 小管家在忙什么）、最近共享事件日志片段。日志落盘时已脱敏，
    /// 这里再限长；正文里一切主人侧的自由文本（title/detail/
    /// 其他任务的 instruction）先过 sanitize 消毒；任何情况下
    /// 都不附令牌/口令。
    private static func composeBody(title: String, detail: String?, steward: Steward) async -> String {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = info?["CFBundleVersion"] as? String ?? "?"

        let timeFormatter = ISO8601DateFormatter()
        timeFormatter.formatOptions = [.withInternetDateTime]
        timeFormatter.timeZone = TimeZone.current
        let nowText = timeFormatter.string(from: Date())

        // 小管家当时在忙什么（排除正在执行的 report_issue 自己），
        // 外加最近终结的任务（含报错原文，AI-P1-4/AI-P2-7）。
        let otherTasks = await steward.activeTaskSummaries()
            .filter { $0.toolName != toolName }
        let finishedTasks = await steward.recentFinishedSummaries(limit: 5)
            .filter { $0.toolName != toolName }
        let activeText = otherTasks.isEmpty
            ? "当时没有其他任务在跑"
            : otherTasks.map { task in
                let name = task.toolName ?? "未定工具"
                let instruction = sanitize(String(task.instruction.prefix(80)))
                return "\(name)：\(instruction)"
            }.joined(separator: "；")
        var taskText = activeText
        if !finishedTasks.isEmpty {
            let finishedText = finishedTasks.map { task in
                let name = task.toolName ?? "未定工具"
                let instruction = sanitize(String(task.instruction.prefix(80)))
                let stateText: String = switch task.state {
                case .finished: "成功"
                case .failed: "失败"
                case .timedOut: "超时"
                case .cancelled: "已取消"
                case .interruptedByOwner: "主人打断"
                default: "终结"
                }
                var line = "\(name)（\(stateText)）：\(instruction)"
                if let err = task.errorText, !err.isEmpty {
                    line += "——报错：\(sanitize(String(err.prefix(300))))"
                }
                return line
            }.joined(separator: "；")
            taskText += "\n- 小管家最近终结的任务：\(finishedText)"
        }

        let logLines = SharedEventLog.shared.recentEntries(limit: 20)
        // 日志行落盘时已脱敏，但旧行可能是补网址遮蔽之前写的；
        // 进公开 Issue 前再过一遍 sanitize（含遮裸网址），双保险。
        let logText = logLines.isEmpty
            ? "（暂无记录）"
            : String(sanitize(logLines.joined(separator: "\n")).prefix(3000))

        var sections: [String] = []
        sections.append("## 主人反馈的问题")
        sections.append(detail.map { String($0.prefix(4000)) } ?? title)
        sections.append("## 发送时的情况")
        sections.append("""
            - 发送时间：\(nowText)
            - App 版本：\(appVersion)（build \(appBuild)）
            - 系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)（\(UIDevice.current.model)）
            - 小管家当时在忙：\(taskText)
            """)
        sections.append("## 最近的共享事件日志")
        sections.append("```\n\(logText)\n```")
        sections.append("（由桥内「报问题」自动打包发送，正文不含任何令牌/口令。）")
        return sections.joined(separator: "\n\n")
    }

    /// 本文件内的正文消毒：先过共享事件日志现成的脱敏（key=value
    /// 秘钥模式 + data URI），再把裸 http(s) 网址也遮掉。只用在
    /// 本文件的 Issue 正文组装里——不许动 SharedEventLog.redact
    /// 本体（它是全 App 共享的，动它等于改所有事件日志的行为）。
    private static let bareURLPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "https?://[^\\s)\"<>\\]]+",
            options: [.caseInsensitive])
    }()

    private static func sanitize(_ s: String) -> String {
        let redacted = SharedEventLog.redact(s)
        guard let pattern = bareURLPattern else { return redacted }
        let range = NSRange(redacted.startIndex..., in: redacted)
        return pattern.stringByReplacingMatches(
            in: redacted, range: range, withTemplate: "<url>")
    }

    /// GitHub 状态码 → 中文人话。GitHub 原话（message 字段）只在需要
    /// 定位时附上——那是 GitHub 的公开报错，不含令牌。
    private static func failureText(statusCode: Int, githubMessage: String?) -> String {
        let suffix = githubMessage.map { "（GitHub 原话：\($0)）" } ?? ""
        switch statusCode {
        case 401:
            return "发送失败：令牌不对，或者已经失效了（GitHub 回 401）。请到 设置 > 桥·对外连接 > 「报问题到 GitHub」里重新粘贴一个有效的令牌，再让我重发。"
        case 403:
            return "发送失败：这把令牌没有往 \(repoFullName) 发问题的权限（GitHub 回 403）。请确认令牌是只给这个仓库、带 Issues 读写权限的 fine-grained PAT。\(suffix)"
        case 404:
            return "发送失败：仓库找不到，或者这把令牌看不到这个仓库（GitHub 回 404）。目标仓库是 \(repoFullName)，请确认生成令牌时选对了仓库。"
        case 422:
            return "发送失败：GitHub 觉得内容有问题、拒绝接收（422）。\(suffix)"
        default:
            return "发送失败：GitHub 回了 \(statusCode)。\(suffix)请稍后再让我重发。"
        }
    }
}

// MARK: - 报问题令牌的钥匙串存取
//
// 专用条目：kSecClassGenericPassword，service "bridge.github"，
// account "issue-token"。写法沿用 BridgeRelayTokenStore 的仓内现成
// 套路：不可同步（不走 iCloud）、AfterFirstUnlock 可读。
// 令牌只存钥匙串、不进 UserDefaults、不进日志；界面只显示已填/未填。
enum BridgeGitHubTokenStore {
    static let service = "bridge.github"
    static let account = "issue-token"

    private static let log = AppLogger(category: "BridgeGitHubToken")

    /// 保存令牌。空白视为清除（与仓内其他 secret 存储同口径）。
    static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete()
            return
        }
        keychainSet(Data(trimmed.utf8))
    }

    /// 读令牌。取不到（没填 / 钥匙串异常）返回 nil；调用方据此提示
    /// 「先去设置页填令牌」，不要拿空串去撞 GitHub。
    static func load() -> String? {
        keychainGet().flatMap { String(data: $0, encoding: .utf8) }
    }

    static var hasToken: Bool {
        load().map { !$0.isEmpty } ?? false
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Keychain primitives（与 BridgeRelayTokenStore 同形）

    private static func keychainSet(_ data: Data) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // 只记状态码，绝不记令牌内容。
            log.error("[Keychain] github issue token save failed status=\(status)")
        }
    }

    private static func keychainGet() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
