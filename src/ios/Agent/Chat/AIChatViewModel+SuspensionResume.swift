import Foundation

/// [s2-suspend-base] 本文件自带 logger（主类里的 logger 是 private，扩展文件不可见，
/// 按 Agent/Chat 下其他扩展文件的惯例各自声明）。
private let logger = AppLogger(category: "AIChatVM")

// MARK: - [s2-suspend-base] 挂起恢复后继续跑
//
// App 被杀时正在等用户点按的挂起（如问用户），恢复后用户给出答案，
// 通过这里把答案作为 tool_result 投回 agentHistory，再走现有的 resume()
// 让 agent loop 从断点继续（history 尾是 tool_result 时 resume 不会再插
// "Continue" 提示，直接进下一轮模型请求）。

extension AIChatViewModel {
    /// 把一次恢复的挂起的答案投回原会话并继续跑。
    /// - Parameters:
    ///   - toolCallId: 原 tool_use 的 id（答案要配对的那个）。
    ///   - toolName: 工具名（如 "ask_user_input_v0"）。
    ///   - answerJSON: 答案 JSON，作为 tool_result 的内容。
    ///   - summary: 写进 UI 工具块的摘要。
    func continueAfterRestoredAsk(
        toolCallId: String,
        toolName: String,
        answerJSON: String,
        summary: String
    ) {
        guard !isProcessing else {
            logger.info("[SuspensionResume] session busy, skip restored-answer delivery tuId=\(toolCallId.prefix(12))")
            return
        }
        // 1. 答案作为 tool_result 追加进 agentHistory（user role，
        //    与正常工具结果同形，下一轮请求能直接配对上原来的 tool_use）。
        let resultMessage = AgentMessage(role: .user, parts: [
            .toolResult(id: toolCallId, name: toolName, content: answerJSON, isError: false),
        ])
        agentHistory.append(resultMessage)
        let resultIdx = agentHistory.count - 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let pid = await self.persistAgentMessage(resultMessage),
               resultIdx < self.agentHistory.count {
                self.agentHistory[resultIdx].dbMessageId = pid
            }
        }
        // 2. UI 上把原来的工具块标成已完成，写上摘要。
        for msg in messages where msg.role == .assistant {
            if let block = msg.blocks.first(where: { $0.toolUseId == toolCallId }) {
                block.content = summary
                block.toolStatus = .success
            }
        }
        // 3. 重进是 DB 里捞出来的内容，没有没提交的流式尾巴——
        //    把 committedBlockCount 对齐，避免 resume() 的 pre-trim 误伤。
        if let lastMsg = messages.last, lastMsg.role == .assistant {
            committedBlockCount = lastMsg.blocks.count
        }
        // 4. 走现有 resume() 从断点继续。
        canResume = true
        resume()
    }
}
