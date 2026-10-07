import Foundation

// MARK: - 联网搜索调度（GAP 第 18 条，[s2-search]）
//
// 借 Kelivo 的三样：
//   ① "一家一个适配文件"的接法（见各 Provider 文件）；
//   ② 多 key 轮换：按顺序轮着用，游标只存内存（App 重启归零）；
//      某把 key 返回 401/403（invalidKey）时自动换下一把接着搜；
//   ③ 引用标记：工具返回的结果带编号 id，工具说明书要求模型在引用处
//      打 `[cite:id]`，渲染层再换成来源角标（渲染增强还没做，标记先透传）。

enum WebSearchService {

    static let selectedProviderKey = "websearch.provider.selected"
    static let log = AppLogger(category: "WebSearch")

    /// 当前选中的服务商 id。默认 Brave（免费额度最大、最稳）。
    static var selectedProviderId: String {
        get { UserDefaults.standard.string(forKey: selectedProviderKey) ?? WebSearchProviderID.brave }
        set { UserDefaults.standard.set(newValue, forKey: selectedProviderKey) }
    }

    /// 本次施工接好的全部服务商（固定两家，不开放手填新家——新家要新写
    /// 适配文件，加一家是一件施工活，不让用户自己填 URL 糊弄）。
    static let providers: [any WebSearchProvider] = [
        BraveSearchProvider(),
        TavilySearchProvider(),
    ]

    static func provider(for id: String) -> (any WebSearchProvider)? {
        providers.first { $0.providerId == id }
    }

    /// 某服务商配好 key 了吗（工具注册时用这个门禁：没配好就不挂工具）。
    static func isConfigured(_ providerId: String) -> Bool {
        WebSearchKeys.hasKeys(for: providerId)
    }

    // MARK: - 多 key 内存轮换

    private static let rotatorLock = NSLock()
    /// providerId -> 下一把 key 的下标。只在内存里（Kelivo 同款口径）。
    private static var cursors: [String: Int] = [:]

    /// 用选中的服务商搜。`providerId` 留给设置页的"测试"按钮测别家用。
    static func search(
        query: String,
        count: Int = 8,
        as providerId: String? = nil
    ) async throws -> WebSearchOutcome {
        let pid = providerId ?? selectedProviderId
        guard let provider = provider(for: pid) else {
            throw WebSearchError.badResponse("未知的搜索服务商：\(pid)")
        }
        let keys = WebSearchKeys.keys(for: provider.providerId)
        guard !keys.isEmpty else {
            throw WebSearchError.noKeysConfigured(providerId: provider.providerId)
        }

        // 每把 key 最多试一次：invalidKey 就换下一把；别的错直接抛
        // （网络抖、限流都不是换 key 能解决的，换了也是白烧额度）。
        for _ in keys {
            let key = rotatorLock.withLock { () -> String in
                let i = (cursors[provider.providerId] ?? 0) % keys.count
                cursors[provider.providerId] = (i + 1) % keys.count
                return keys[i]
            }
            do {
                var outcome = try await provider.search(query: query, count: count, apiKey: key)
                outcome = renumber(outcome)
                log.info("[WebSearch] ok provider=\(provider.providerId) results=\(outcome.results.count)")
                return outcome
            } catch let err as WebSearchError {
                if case .invalidKey = err {
                    log.error("[WebSearch] key rejected, rotating provider=\(provider.providerId)")
                    continue
                }
                throw err
            }
        }
        throw WebSearchError.allKeysExhausted(providerId: provider.providerId)
    }

    /// 各家返回的 id 口径统一成 1…n（与 [cite:id] 的编号对齐）。
    private static func renumber(_ outcome: WebSearchOutcome) -> WebSearchOutcome {
        let results = outcome.results.enumerated().map { i, r in
            WebSearchResult(id: "\(i + 1)", title: r.title, url: r.url,
                            snippet: r.snippet, publishedDate: r.publishedDate)
        }
        return WebSearchOutcome(providerId: outcome.providerId,
                                providerName: outcome.providerName,
                                results: results, answer: outcome.answer)
    }

    // MARK: - 给模型看的成品文本

    /// 工具返回给模型的文本：编号结果 + 来源列表 + 引用格式提醒。
    static func formatForModel(_ outcome: WebSearchOutcome, query: String) -> String {
        if outcome.results.isEmpty {
            return "Web search for \"\(query)\" via \(outcome.providerName) returned no results. Tell the user nothing relevant was found rather than guessing."
        }
        var lines: [String] = []
        lines.append("Web search results for \"\(query)\" (via \(outcome.providerName)):")
        lines.append("")
        for r in outcome.results {
            lines.append("[\(r.id)] \(r.title)")
            lines.append("    \(r.url)")
            let snippet = r.snippet.isEmpty ? "(no snippet)" : r.snippet
            lines.append("    \(snippet)")
            if let date = r.publishedDate, !date.isEmpty {
                lines.append("    (published: \(date))")
            }
            lines.append("")
        }
        if let answer = outcome.answer, !answer.isEmpty {
            lines.append("Provider summary: \(answer)")
            lines.append("")
        }
        lines.append("CITE RULE: when your reply uses a fact from a result above, cite it inline as [cite:<id>] (e.g. [cite:2]) right after the claim. Only use ids listed above — never invent one.")
        return lines.joined(separator: "\n")
    }
}
