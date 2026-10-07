import Foundation

// MARK: - 联网搜索服务商：Brave Search（[s2-search]）
//
// API 形态 2026-10-02 按公开文档核实：
//   GET https://api.search.brave.com/res/v1/web/search?q=…&count=…
//   头 X-Subscription-Token: <key>
//   返回 {"web": {"results": [{"title","url","description","extra_snippets"}]}}
// 401/403 = key 无效（轮换器看到这个错换下一把）；免费额度 2000 次/月。

struct BraveSearchProvider: WebSearchProvider {
    let providerId = WebSearchProviderID.brave
    let displayName = "Brave Search"
    let keySignupURL = "https://brave.com/search/api/"

    private static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!
    private static let log = AppLogger(category: "WebSearch")

    func search(query: String, count: Int, apiKey: String) async throws -> WebSearchOutcome {
        var comps = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(max(count, 1), 20))),
            URLQueryItem(name: "extra_snippets", value: "true"),
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // key 只进请求头，不进日志、不进报错。
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 30

        let data: Data
        let status: Int
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            // 取消必须原样透传：包成 network 会让调用方把它当成"搜索失败"。
            // URLSession 取消传出来的是 URLError(.cancelled)，不是 CancellationError，
            // 两种形态都要放行（仓内四个 LLM provider 的 mapError 同款口径）。
            if error is CancellationError || Self.isURLSessionCancelled(error) {
                throw error
            }
            throw WebSearchError.network("Brave Search：\(error.localizedDescription)")
        }

        switch status {
        case 401, 403:
            // 只记状态码，不记 key。
            Self.log.error("[WebSearch] brave invalid key, status=\(status)")
            throw WebSearchError.invalidKey(providerId: providerId)
        case 429:
            throw WebSearchError.rateLimited
        case 200..<300:
            break
        default:
            throw WebSearchError.badResponse("Brave Search 返回 HTTP \(status)")
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
            throw WebSearchError.badResponse("Brave Search 返回的不是 JSON")
        }
        let web = json["web"] as? [String: Any]
        let raw = web?["results"] as? [[String: Any]] ?? []
        var results: [WebSearchResult] = []
        for (i, item) in raw.enumerated() {
            guard let title = item["title"] as? String, !title.isEmpty,
                  let url = item["url"] as? String, !url.isEmpty else { continue }
            var snippet = (item["description"] as? String) ?? ""
            if let extras = item["extra_snippets"] as? [String], !extras.isEmpty {
                snippet += "\n" + extras.prefix(2).joined(separator: "\n")
            }
            results.append(WebSearchResult(
                id: "\(i + 1)",
                title: title,
                url: url,
                snippet: Self.cleanSnippet(snippet),
                publishedDate: item["page_age"] as? String
            ))
        }
        return WebSearchOutcome(
            providerId: providerId,
            providerName: displayName,
            results: results,
            answer: nil
        )
    }

    /// Brave 的 description 偶尔带 HTML 转义/标签，清理成纯文本。
    private static func cleanSnippet(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#x27;", with: "'")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        // 摘要截断：太长只会吃 token。
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 600 {
            return String(trimmed.prefix(600)) + "…"
        }
        return trimmed
    }
}
