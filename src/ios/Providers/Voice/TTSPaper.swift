import Foundation

// MARK: - TTS 能力纸条（AI 说明书 · 纸条版）
//
// [tts-paper 2026-10-02] 醒醒：「模型根本不知道我有这个 TTS，他不会调用，也没说明书」。
//
// 纸条机制（按她定的口径）：用户话题跟语音/TTS 相关时，才把这张纸条塞进
// system prompt（注入点见 AIChatViewModel.runAgentLoop）；平时不占 prompt。
// 内容是活的——每次按 TTSServiceStore / TTSGroupStore 的当前配置现拼
//（有哪些分组/服务/音色），配置改了纸条自动跟着变，不用手动同步。
//
// 触发判定是宽松的语义匹配（不是死关键词）：只要用户这轮在聊"让 AI 开口说话"
// 这件事就给。假设记在这里：v1 用词表匹配；如果她嫌误触发/漏触发，再换更聪明
// 的判定。纸条只在配了 TTS 服务/分组时才出现——没配就不让模型知道，免得它
// 对着空气调工具（"空调"）。

enum TTSPaper {

    /// 拼出纸条正文。没配任何可用 TTS 服务/分组时返回 nil。
    static func paperText() -> String? {
        let groupStore = TTSGroupStore.shared
        let serviceStore = TTSServiceStore.shared
        let services = serviceStore.services.filter { $0.enabled }
        guard !services.isEmpty || !groupStore.groups.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("【纸条·TTS 语音】")
        lines.append("你有一个 send_voice 工具：把文字合成为语音消息发给主人（微信式语音气泡，点一下就能听，会自动播放）。主人说\"发条语音\"\"用语音说\"\"读出来\"\"念给我听\"这类话时，调这个工具——别自己去沙箱里跑命令合成音频。")
        lines.append("")

        // 当前配置（活的）：默认分组优先，其次单个服务。
        let defaultCandidates = groupStore.defaultGroupCandidates()
        if let defId = groupStore.defaultGroupId, let g = groupStore.group(id: defId) {
            if defaultCandidates.isEmpty {
                lines.append("默认 TTS 分组「\(g.name)」里没有可用的服务——先跟主人说 TTS 还没配好，让她去「设置 > Voice Services」里配。")
            } else {
                lines.append("默认 TTS 分组「\(g.name)」：")
                for (i, s) in defaultCandidates.enumerated() {
                    lines.append("  \(i + 1). \(s.name)（\(s.kind.displayName)·音色 \(s.voice)）")
                }
                lines.append("  合成时会按这个顺序自动 fallback：第一个挂了自动换下一个，你不用管。")
            }
        } else if let s = serviceStore.selectedService(), s.enabled {
            lines.append("当前 TTS 服务：\(s.name)（\(s.kind.displayName)·音色 \(s.voice)）。")
        } else if let s = services.first {
            lines.append("当前 TTS 服务：\(s.name)（\(s.kind.displayName)·音色 \(s.voice)）。")
        }

        // 没进默认分组的备选服务也列出来，让模型知道还有别的声音。
        let inDefault = Set(defaultCandidates.map { $0.id })
        let others = services.filter { !inDefault.contains($0.id) }
        if !others.isEmpty {
            lines.append("备选服务（不在默认分组里）：\(others.map { "\($0.name)（音色 \($0.voice)）" }.joined(separator: "、"))。")
        }
        lines.append("")
        lines.append("调用方法：send_voice(text=要说的话，tool_title=一句话摘要)。text 写口语化的中文，直接是主人会听到的话，别带 markdown 符号；别太长，太长分段调多次。")
        lines.append("换音色你换不了：音色/分组是主人在「设置 > Voice Services」里定的。主人让你换声音时，别自己编个音色名传进去——跟她说去设置里换默认分组/服务。")
        lines.append("失败时：工具会明确报错。如实告诉主人这条语音没发出去，不要谎称已发送；可以建议她检查 TTS 服务配置。")
        return lines.joined(separator: "\n")
    }

    /// 用户这轮消息跟语音/TTS 相关时返回纸条，否则返回 nil。
    /// 宽松匹配：覆盖"让 AI 开口说话"这件事的各种说法，不做死关键词锁定。
    static func paperIfRelevant(userMessage: String) -> String? {
        let t = userMessage.lowercased()
        let triggers = [
            "语音", "发语音", "声音", "朗读", "读出来", "念给我", "说给我听",
            "亲口", "tts", "voice", "speak", "播报", "有声", "哄睡",
        ]
        guard triggers.contains(where: { t.contains($0) }) else { return nil }
        return paperText()
    }
}
