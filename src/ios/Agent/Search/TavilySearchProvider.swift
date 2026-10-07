import Foundation

// MARK: - 联网搜索服务商：Tavily（[s2-search]）
//
// API 形态 2026-10-02 按公开文档核实：
//   POST https://api.tavily.com/search
//   Content-Type: application/json
//   Body {"api_key": "<key>", "query": "…", "search_depth": "basic",
//         "max_results": n, "include_answer": false}
//   返回 {"results": [{"title","url","content","score","published_date"}], "answer": …}
// 401/403 = key 无效（轮换器看到这个错换下一把）。
// 免费额度 1000 credits/月；basic 每次 1 credit。include_answer 不开——
// 那是 AI 总结，按条要额外 credit，结果片段已经够模型自己组织回答。

struct TavilySearchProvider: WebSearchProvider {
    let providerId = WebSearchProviderID.tavily
    let displayName = "Tavily"
    let keySignupURL = "https://tavily.com/"

    private static let endpoint = URL(string: "https://api.tavily.com/search")!
    private static let log = AppLogger(category: "WebSearch")

    func search(query: String, count: Int, apiKey: String) async throws -> WebSearchOutcome {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        // key 只进请求体，不进日志、不进报错。
        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "search_depth": "basic",
            "max_results": min(max(count, 1), 20),
            "include_answer": false,
            "include_raw_content": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let status: Int
        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            data = respData
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            // 取消必须原样透传：包成 network 会让调用方把它当成"搜索失败"。
            // URLSession 取消传出来的是 URLError(.cancelled)，不是 CancellationError，
            // 两种形态都要放行（仓内四个 LLM provider 的 mapError 同款口径）。
            if error is CancellationError || Self.isURLSessionCancelled(error) {
                throw error
            }
            throw WebSearchError.network("Tavily：\(error.localizedDescription)")
        }

        switch status {
        case 401, 403:
            // 只记状态码，不记 key。
            Self.log.error("[WebSearch] tavily invalid key, status=\(status)")
            throw WebSearchError.invalidKey(providerId: providerId)
        case 429:
            throw WebSearchError.rateLimited
        case 200..<300:
            break
        default:
            throw WebSearchError.badResponse("Tavily 返回 HTTP \(status)")
        }

        return try parse(data: data)
    }

    /// URLSession 任务被取消时抛的是 URLError(.cancelled)，不是 CancellationError。
    private static func isURLSessionCancelled(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    // MARK: - 解析

    private func parse(data: Data) throws -> WebSearchOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebSearchError.badResponse("Tavily 返回的不是 JSON")
        }
        let raw = json["results"] as? [[String: Any]] ?? []
        var results: [WebSearchResult] = []
        for (i, item) in raw.enumerated() {
            guard let title = item["title"] as? String, !title.isEmpty,
                  let url = item["url"] as? String, !url.isEmpty else { continue }
            let snippet = Self.trim((item["content"] as? String) ?? "")
            results.append(WebSearchResult(
                id: "\(i + 1)",
                title: title,
                url: url,
                snippet: snippet,
                publishedDate: item["published_date"] as? String
            ))
        }
        let answer = (json["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WebSearchOutcome(
            providerId: providerId,
            providerName: displayName,
            results: results,
            answer: answer
        )
    }

    private static func trim(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 800 { return String(t.prefix(800)) + "…" }
        return t
    }
}
