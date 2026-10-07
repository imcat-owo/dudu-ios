import Foundation

// MARK: - 联网搜索（GAP 第 18 条）：搜索服务商抽象
//
// 借 Kelivo 的做法：
//   ① 一家服务商一个实现文件（本协议 + BraveSearchProvider.swift /
//      TavilySearchProvider.swift 各自实现）；
//   ② 引用靠 `[cite:id]` 标记——工具返回的结果带编号 id，模型在引用处
//      就地打 `[cite:id]`，渲染层再把标记换成来源角标（渲染增强还没做，
//      标记先透传，见 WebSearchService.formatForModel）。
//
// key 只进钥匙串（见 WebSearchKeys.swift），绝不进日志、不进报错文案。

/// 单条搜索结果。id 是本次搜索内的编号（"1"…"n"）。
struct WebSearchResult: Sendable {
    let id: String
    let title: String
    let url: String
    let snippet: String
    let publishedDate: String?
}

/// 一次搜索的产出。
struct WebSearchOutcome: Sendable {
    let providerId: String
    let providerName: String
    let results: [WebSearchResult]
    /// 有些服务商附带 AI 总结（Tavily 的 answer），有就原样带回。
    let answer: String?
}

/// 搜索执行中的错误。`invalidKey` 专供轮换器识别——这把 key 坏了，
/// 换下一把。所有 userMessage 都不带 key 明文。
enum WebSearchError: Error, Sendable {
    case invalidKey(providerId: String)
    case rateLimited
    case network(String)
    case badResponse(String)
    case noKeysConfigured(providerId: String)
    case allKeysExhausted(providerId: String)

    var userMessage: String {
        switch self {
        case .invalidKey:
            return "搜索服务商的 key 无效（401/403）。请到 设置 > 联网搜索 里检查这把 key 是否填对、是否还有额度。"
        case .rateLimited:
            return "搜索服务商限流了（429），稍等一会儿再试。"
        case .network(let why):
            return "联网搜索请求失败：\(why)"
        case .badResponse(let why):
            return "搜索服务商返回异常：\(why)"
        case .noKeysConfigured:
            return "联网搜索还没配好：这家服务商的 key 还没填。请先到 设置 > 联网搜索 里粘贴 key。"
        case .allKeysExhausted:
            return "这家服务商填的几把 key 全都无效（401/403），请到 设置 > 联网搜索 里换有效 key。"
        }
    }
}

protocol WebSearchProvider: Sendable {
    var providerId: String { get }
    var displayName: String { get }
    /// 申请 key 的入口（官网），给设置页展示。
    var keySignupURL: String { get }
    /// 执行一次搜索。key 由调度层按轮换给进来（内存轮换，见 WebSearchService）。
    func search(query: String, count: Int, apiKey: String) async throws -> WebSearchOutcome
}

/// 本次施工接的两家（[s2-search]：先接常用、稳妥、有公开 API 的）。
enum WebSearchProviderID {
    static let brave = "brave"
    static let tavily = "tavily"
}
