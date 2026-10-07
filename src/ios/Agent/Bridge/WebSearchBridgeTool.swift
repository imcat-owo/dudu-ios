import Foundation
import BridgeCore

/// 联网搜索工具（桥审计 B）：把 GAP 第 18 条的 WebSearchService
/// 包一层挂进桥的小管家注册中心，对外经「搜」被外部 AI 查到、经
/// 「命令」点名调用。写法照 DeviceTools 的声明格式。
///
/// key 走钥匙串 `bridge.websearch`（WebSearchKeys），多 key 内存轮换
/// 现成复用；没配 key 时诚实报错、指引去 设置 > 联网搜索 里填，
/// 不静默失败。取消信号（CancellationError / URLError.cancelled）
/// 透传出去，不吞成"搜索失败"。
enum WebSearchBridgeTool {
    static let toolName = "web_search"

    static func register(into registry: ToolRegistry) async throws {
        try await registry.register(
            descriptor: ToolDescriptor(
                name: toolName,
                summary: "联网搜索：让手机替你上网查资料（新闻、价格、文档、实时信息）",
                detail: """
                    参数 query：搜索关键词（必填），英文关键词通常覆盖更好；
                    count：要几条结果，1–20，默认 8。
                    结果按 [1]..[N] 编号，带标题、链接、摘要；引用某条结果时在结论后打 [cite:编号]（如 [cite:2]），只用输出里的编号、不许自编。
                    需要先在 设置 > 联网搜索 里填好搜索服务商的 key，没填会明确报错告诉你去哪填。
                    """,
                keywords: ["搜索", "联网", "查资料", "web search", "search", "新闻", "价格", "实时", "上网"],
                parameterSchemaJSON: #"""
                    {"type":"object","properties":{
                      "query":{"type":"string","description":"搜索关键词"},
                      "count":{"type":"integer","description":"要几条结果，1-20，默认 8"}},
                     "required":["query"]}
                    """#
            )
        ) { arguments in
            guard let query = arguments.string("query")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !query.isEmpty
            else {
                return ToolOutput(
                    text: "参数不对：query 必填（要搜的关键词）。",
                    isError: true)
            }
            let count = min(max(arguments.int("count") ?? 8, 1), 20)
            do {
                let outcome = try await WebSearchService.search(query: query, count: count)
                return ToolOutput(text: WebSearchService.formatForModel(outcome, query: query))
            } catch let err as WebSearchError {
                return ToolOutput(text: err.userMessage, isError: true)
            } catch let cancel as CancellationError {
                throw cancel
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw CancellationError()
            } catch {
                return ToolOutput(text: "联网搜索失败：\(error)", isError: true)
            }
        }
    }
}
