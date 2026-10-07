import Foundation

/// 小管家「干活」的判断上下文 —— 与聊天记忆物理隔离。
///
/// 她的决定（2026-10-02）：小管家做成可聊天的默认人设后，
/// 「聊天记忆 vs 干活判断」必须隔开 —— 聊天归聊天的人设记忆，
/// 干活判断另记一份，不混用。
///
/// 走查坐实的现状（本文件把"碰巧"钉死成约定）：
/// - 干活路径「搜 / 命令」→ BridgeMetaTools → Steward.execute：
///   全程无模型、无记忆，只走注册表关键词搜索 + 工具执行 + 结果清洗，
///   从不读聊天会话、从不读 memory/personas/steward/ 下的任何东西。
///   这条是结构性的：以后给干活加模型路由，只能从 work/ 取上下文，
///   不许碰聊天记忆。
/// - 聊天路径（AIChatViewModel，steward 人设）：
///   只读写 memory/personas/steward/ 下的 SOUL.md / GLOBAL.md / 日报
///   和人设会话；GLOBAL.md、日报按指定文件名读，memory_get 用非递归
///   枚举 —— work/ 子目录天然不会被聊天侧读到。
///
/// 约定（两边都遵守）：
/// 1. 干活要记判断（路由经验、工作笔记）→ 只许写 work/，不许进聊天记忆；
/// 2. 聊天侧（prompt 组装、记忆读写、会话历史）→ 不许读 work/；
/// 3. work/ 下的笔记进备份（BackupExporter / Importer 对 personas/ 是递归的）。
enum StewardWorkContext {

    /// 工作笔记子目录名：memory/personas/steward/work/
    static let dirName = "work"

    /// 小管家的工作笔记目录。nonisolated：干活路径（actor 上下文）也可调。
    nonisolated static func workDir() -> URL {
        PersonaStore.memoryDir(for: PersonaStore.stewardPersonaID)
            .appendingPathComponent(dirName, isDirectory: true)
    }

    /// 建目录（启动时 PersonaStore.ensureDirs() 会调；用前幂等可调）。
    nonisolated static func ensureWorkDir() {
        try? FileManager.default.createDirectory(
            at: workDir(), withIntermediateDirectories: true)
    }

    /// 记一条干活判断：追加进 work/notes.md，带时间戳。
    /// 注意：这是给"干活"记的，不是给聊天记的 —— 聊天记忆走日报 / GLOBAL.md。
    nonisolated static func appendWorkNote(_ note: String) {
        ensureWorkDir()
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry = "<!-- \(fmt.string(from: Date())) -->\n\(trimmed)\n\n"
        let url = workDir().appendingPathComponent("notes.md")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (entry + existing).data(using: .utf8)?
            .write(to: url, options: .atomic)
    }

    /// 读工作笔记（干活路径以后要取判断上下文时走这里，不走聊天记忆）。
    nonisolated static func readWorkNotes() -> String? {
        let url = workDir().appendingPathComponent("notes.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
