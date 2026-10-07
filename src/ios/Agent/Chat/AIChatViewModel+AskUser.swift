import Foundation

// MARK: - [s2-askuser] 问用户工具
//
// 对齐目标：AI 能中途停下来问她问题再继续——新工具 ask_user_input_v0，一次最多 4 道题、
// 单选/多选，界面自动带"其他（自填）/跳过"，答案 JSON 回 AI；App 被杀再打开，没答完的
// 问题能从存下的记录里捞回来接着答，答完投回原会话继续跑。
// 依据：Kelivo 的做法（补课笔记）。界面用 sheet 弹窗是我的推断，复用现有挂起弹窗风格。

extension AIChatViewModel {
    static let askUserToolName = "ask_user_input_v0"
    static let askUserMaxQuestions = 4

    /// 执行 ask_user_input_v0：解析 questions → 挂起等用户回答 → 返回 (输出, 成功, 块摘要)。
    /// deferredAssistantRaw：当轮 assistant 消息的落盘形态（loop 里已建好）。
    /// 挂起前先把它写进 DB——否则 App 在等待时被杀，DB 里就没有这条 tool_use，
    /// 重开后补的 tool_result 配不上对，调模型直接 400。写的是和正常批量提交同一行，
    /// 批量提交时凭 assistantMessagePersistedForSuspension 跳过，不会写两遍。
    func handleAskUser(toolArgs: [String: Any], toolId: String, deferredAssistantRaw: RawMessage?) async -> (output: String, success: Bool, summary: String) {
        // —— 解析 questions（JSON 字符串，仿 browser_use 的 cookies 写法）——
        guard let questionsJSON = toolArgs["questions"] as? String,
              let data = questionsJSON.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !raw.isEmpty
        else {
            let msg = "Error: 'questions' must be a non-empty JSON array like [{\"id\":\"q1\",\"question\":\"...\",\"type\":\"single\",\"options\":[\"A\",\"B\"]}]. Please call \(Self.askUserToolName) again with a valid 'questions' parameter."
            return (msg, false, msg)
        }
        var questions: [AskQuestion] = []
        for obj in raw.prefix(Self.askUserMaxQuestions) {
            guard let qid = (obj["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !qid.isEmpty,
                  let question = (obj["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty,
                  let options = obj["options"] as? [String], !options.isEmpty
            else { continue }
            let typeRaw = (obj["type"] as? String)?.lowercased()
            questions.append(AskQuestion(
                id: qid,
                question: question,
                type: typeRaw == "multi" ? "multi" : "single",
                options: options
            ))
        }
        guard !questions.isEmpty else {
            let msg = "Error: no valid question in 'questions' (each needs id, question, and a non-empty options array). Please call \(Self.askUserToolName) again."
            return (msg, false, msg)
        }
        // id 是 AI 生成的，可能重复；下游多处用 id 做字典 key（重复会 fatalError），
        // 这里去重（保留第一道），保证整条链路的 id 唯一。
        var seenIds = Set<String>()
        questions = questions.filter { seenIds.insert($0.id).inserted }
        let title = (toolArgs["tool_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = AskPayload(
            title: (title?.isEmpty == false) ? title! : "AI 想问你几个问题",
            questions: questions
        )

        // —— 挂起等用户点按（底座：先持久化再挂起，App 被杀可恢复；问用户不设超时）——
        // 先落当轮 assistant 消息（含 tool_use），见函数头注释。
        if let raw = deferredAssistantRaw, raw.id != assistantMessagePersistedForSuspension {
            await ChatStore.shared.appendMessage(raw)
            assistantMessagePersistedForSuspension = raw.id
            // 和 persistAgentMessage 一样 bump 基线，别让 iCloud 同步把自己写的当远端。
            lastKnownDbSortOrder += 1
            lastKnownDbCount += 1
        }
        let decision = await ToolSuspensionService.shared.suspendAsk(
            payload: payload,
            toolName: Self.askUserToolName,
            toolCallId: toolId,
            sessionId: sessionId
        )

        // —— 决策 → toolOutput ——
        switch decision {
        case .answered(let json):
            var output = json
            if raw.count > Self.askUserMaxQuestions {
                output += "\n<system-reminder>Only the first \(Self.askUserMaxQuestions) questions were asked; the rest were dropped. Do not re-ask the dropped questions in a follow-up \(Self.askUserToolName) call unless the user asks for more.</system-reminder>"
            }
            return (output, true, Self.summarizeAskAnswers(payload: payload, answerJSON: json))
        case .skipped:
            // 用户点了跳过：答案全 null，AI 按自己的判断继续。
            let nulls = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, NSNull()) })
            let json = (try? JSONSerialization.data(withJSONObject: nulls)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return (json, true, "用户跳过了这 \(questions.count) 道题，按你的判断继续。")
        case .timedOut:
            // 问用户不设超时，防御性分支。
            return ("{\"error\":\"question timed out without an answer\"}", false, "提问超时未回答。")
        case .approved, .denied:
            return ("{\"error\":\"question dismissed\"}", false, "提问被关闭。")
        }
    }

    /// 答案 JSON → 工具块里显示的一句话摘要。
    static func summarizeAskAnswers(payload: AskPayload, answerJSON: String) -> String {
        let answers = (try? JSONSerialization.jsonObject(with: Data(answerJSON.utf8)) as? [String: Any]) ?? [:]
        var lines = ["已回答（\(payload.questions.count) 道）："]
        for q in payload.questions {
            let text: String
            if let arr = answers[q.id] as? [String], !arr.isEmpty {
                text = arr.joined(separator: "、")
            } else if let s = answers[q.id] as? String, !s.isEmpty {
                text = s
            } else {
                text = "跳过"
            }
            lines.append("· \(q.question)：\(text)")
        }
        return lines.joined(separator: "\n")
    }
}
