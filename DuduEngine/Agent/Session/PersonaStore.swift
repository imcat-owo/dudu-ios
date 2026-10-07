import Foundation
import SwiftUI

// MARK: - Persona (独立人设)
//
// Kelivo 整套借鉴：每人设独立的人设文件（systemPrompt）+ 独立记忆 +
// 独立聊天记录；工具层（iSH/浏览器/MCP/环境变量/现有工具）全局共用，
// 人设只存"用哪些"（skillIds / mcpServerIds / localToolIds 白名单，
// null = 全部可用）。
//
// 人设文件（systemPrompt / style / name）落在
//   memory/personas/<id>/SOUL.md
// 用现有的 SoulMDParser 读写；本 struct 只存注册表级的元数据，
// 存在 MinisConfig/personas.json（整表 JSON，对标 Kelivo 的
// SharedPreferences 整表做法，按我们的数据层改写成文件）。

struct Persona: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var avatar: String?          // dataURI，nil = 默认图标
    var modelId: String?         // nil = 用全局默认模型
    var skillIds: [String]?      // nil = 全部可用
    var mcpServerIds: [String]?  // nil = 全部可用
    var localToolIds: [String]?  // nil = 全部可用（v1 仅存储，执行层过滤后续再接）
    var sortOrder: Int
    var isBuiltIn: Bool          // 内置（小管家）不可删除
}

// MARK: - PersonaStore

/// 人设注册表 + 当前人设。UI 层走 @MainActor 的 shared；
/// prompt 组装等非隔离调用方走下面的 nonisolated static 助手。
@MainActor
final class PersonaStore: ObservableObject {

    static let shared = PersonaStore()

    /// 默认人设（她现在用的那个，迁移后落在这里）。固定 id，保证
    /// 老会话（persona_id 为空）永远有归属。
    static let defaultPersonaID = "default"
    /// 内置小管家"MCP小助手"。固定 id，不可删除。
    static let stewardPersonaID = "steward"

    private static let currentIDKey = "persona.current.id"
    private static let fileName = "personas.json"

    @Published private(set) var personas: [Persona] = []

    @Published var currentPersonaID: String = PersonaStore.readCurrentID() {
        didSet {
            UserDefaults.standard.set(currentPersonaID, forKey: Self.currentIDKey)
            NotificationCenter.default.post(name: .personaDidChange, object: nil)
        }
    }

    var current: Persona {
        personas.first { $0.id == currentPersonaID }
            ?? personas.first { $0.id == Self.defaultPersonaID }
            ?? personas.first
            ?? Persona(id: Self.defaultPersonaID, name: "我的小家", avatar: nil,
                       modelId: nil, skillIds: nil, mcpServerIds: nil,
                       localToolIds: nil, sortOrder: 0, isBuiltIn: false)
    }

    // MARK: - nonisolated 静态助手（prompt 组装 / 工具过滤用）

    /// 当前人设 id。读 UserDefaults，不碰 @MainActor 状态。
    nonisolated static func currentID() -> String {
        readCurrentID()
    }

    private nonisolated static func readCurrentID() -> String {
        (UserDefaults.standard.string(forKey: currentIDKey))?.isEmpty == false
            ? UserDefaults.standard.string(forKey: currentIDKey)!
            : defaultPersonaID
    }

    /// 某人设的记忆目录：memory/personas/<id>/（SOUL.md / GLOBAL.md / 日志都在里面）。
    nonisolated static func memoryDir(for personaID: String) -> URL {
        AIChatViewModel.minisMemoryPersistentDir
            .appendingPathComponent("personas/\(personaID)", isDirectory: true)
    }

    /// 当前人设的工具白名单快照（skill / mcp）。nil = 全部可用。
    /// 直接读 personas.json，不经过 @MainActor，prompt 组装线程可调。
    nonisolated static func whitelistSnapshot() -> (skillIds: [String]?, mcpServerIds: [String]?) {
        whitelist(for: currentID())
    }

    /// 某人设的工具白名单快照。nil = 全部可用。
    nonisolated static func whitelist(for personaID: String) -> (skillIds: [String]?, mcpServerIds: [String]?) {
        let url = AIChatViewModel.minisConfigRoot.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Persona].self, from: data) else {
            return (nil, nil)
        }
        guard let p = list.first(where: { $0.id == personaID }) else { return (nil, nil) }
        return (p.skillIds, p.mcpServerIds)
    }

    // MARK: - 初始化 / 迁移

    private init() {
        // 真正的加载在 ensureDefaults() 里（启动时 MinisApp 按顺序调）。
    }

    /// 启动时调用一次：建表（首启迁移）+ 加载。必须在
    /// SoulStore.ensureExists() 之前调，因为迁移会搬走 memory/SOUL.md。
    func ensureDefaults() {
        let fm = FileManager.default
        let jsonURL = AIChatViewModel.minisConfigRoot
            .appendingPathComponent(Self.fileName)

        if fm.fileExists(atPath: jsonURL.path) {
            load()
            ensureDirs()
            // 小管家 SOUL.md 兜底：万一丢了（删文件等），重写一份。
            let stewardSoulURL = Self.memoryDir(for: Self.stewardPersonaID)
                .appendingPathComponent("SOUL.md")
            if !fm.fileExists(atPath: stewardSoulURL.path) {
                try? Self.stewardSoulContent.data(using: .utf8)?
                    .write(to: stewardSoulURL, options: .atomic)
            }
            return
        }

        // —— 首启：从现有全局 SOUL.md 迁移 ——
        let memDir = AIChatViewModel.minisMemoryPersistentDir
        let defaultDir = Self.memoryDir(for: Self.defaultPersonaID)
        try? fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.memoryDir(for: Self.stewardPersonaID),
                                withIntermediateDirectories: true)

        // 读老 SOUL.md（直接读老路径，不走 persona-aware 的 SoulStore）。
        let oldSoulURL = memDir.appendingPathComponent("SOUL.md")
        var soulName = "我的小家"
        if let data = try? Data(contentsOf: oldSoulURL),
           let text = String(data: data, encoding: .utf8) {
            let parsed = SoulMDParser.parse(text)
            let n = parsed.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { soulName = n }
            // 搬文件：SOUL.md / GLOBAL.md / YYYY-MM-DD.md → default 人设目录
            let newSoulURL = defaultDir.appendingPathComponent("SOUL.md")
            try? fm.moveItem(at: oldSoulURL, to: newSoulURL)
        }
        // GLOBAL.md
        let oldGlobal = memDir.appendingPathComponent("GLOBAL.md")
        if fm.fileExists(atPath: oldGlobal.path) {
            try? fm.moveItem(at: oldGlobal,
                             to: defaultDir.appendingPathComponent("GLOBAL.md"))
        }
        // 每日日志 YYYY-MM-DD.md
        if let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]) {
            for f in files where isDailyLogName(f.lastPathComponent) {
                try? fm.moveItem(at: f,
                                 to: defaultDir.appendingPathComponent(f.lastPathComponent))
            }
        }

        // 写小管家的 SOUL.md（写死的 MCP 管家规则）。
        let stewardSoulURL = Self.memoryDir(for: Self.stewardPersonaID)
            .appendingPathComponent("SOUL.md")
        if !fm.fileExists(atPath: stewardSoulURL.path) {
            try? Self.stewardSoulContent.data(using: .utf8)?
                .write(to: stewardSoulURL, options: .atomic)
        }

        let list = [
            Persona(id: Self.defaultPersonaID, name: soulName, avatar: nil,
                    modelId: nil, skillIds: nil, mcpServerIds: nil,
                    localToolIds: nil, sortOrder: 0, isBuiltIn: false),
            Persona(id: Self.stewardPersonaID, name: "MCP小助手", avatar: nil,
                    modelId: nil,
                    skillIds: [],          // 专用：默认只开 MCP 相关 skill，后续加
                    mcpServerIds: nil,
                    localToolIds: nil, sortOrder: 1, isBuiltIn: true),
        ]
        save(list)
        self.personas = list.sorted { $0.sortOrder < $1.sortOrder }
        if UserDefaults.standard.string(forKey: Self.currentIDKey) == nil {
            currentPersonaID = Self.defaultPersonaID
        }
        NotificationCenter.default.post(name: .personaDidChange, object: nil)
    }

    private func isDailyLogName(_ name: String) -> Bool {
        guard name.hasSuffix(".md"), name.count == 13 else { return false }
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return true
    }

    /// 保证每人设的记忆目录都存在（注册表有但目录丢了时补）。
    private func ensureDirs() {
        let fm = FileManager.default
        for p in personas {
            try? fm.createDirectory(at: Self.memoryDir(for: p.id),
                                    withIntermediateDirectories: true)
        }
        // [steward-sep] 小管家的工作笔记目录：干活判断的家，与聊天记忆物理隔离。
        // 聊天侧（GLOBAL.md / 日报 / memory_get 非递归枚举）读不到 work/ 子目录。
        StewardWorkContext.ensureWorkDir()
    }

    // MARK: - 读写

    private func jsonURL() -> URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent(Self.fileName)
    }

    private func load() {
        let url = jsonURL()
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Persona].self, from: data),
              !list.isEmpty else {
            // 注册表坏了：重建默认（不丢记忆文件，只重建注册表）。
            personas = [
                Persona(id: Self.defaultPersonaID, name: "我的小家", avatar: nil,
                        modelId: nil, skillIds: nil, mcpServerIds: nil,
                        localToolIds: nil, sortOrder: 0, isBuiltIn: false),
                Persona(id: Self.stewardPersonaID, name: "MCP小助手", avatar: nil,
                        modelId: nil, skillIds: [], mcpServerIds: nil,
                        localToolIds: nil, sortOrder: 1, isBuiltIn: true),
            ]
            save(personas)
            return
        }
        personas = list.sorted { $0.sortOrder < $1.sortOrder }
        // 当前 id 指向的人设没了 → 回落到 default
        if !personas.contains(where: { $0.id == currentPersonaID }) {
            currentPersonaID = Self.defaultPersonaID
        }
    }

    private func save(_ list: [Persona]) {
        let url = jsonURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 备份恢复/回滚后重载注册表（BackupImporter 调）：读盘 + 补目录。
    /// load() 里已有"当前 id 指向的人设没了 → 回落 default"的保护。
    func reloadFromDisk() {
        load()
        ensureDirs()
    }

    private func persist() {
        save(personas)
    }

    // MARK: - 管理（照搬 Kelivo AssistantProvider 逻辑）

    /// 新建人设：空 SOUL.md + 空记忆目录。
    @discardableResult
    func addPersona(name: String) -> Persona {
        let p = Persona(id: UUID().uuidString,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "新人设" : name.trimmingCharacters(in: .whitespacesAndNewlines),
                        avatar: nil, modelId: nil, skillIds: nil, mcpServerIds: nil,
                        localToolIds: nil,
                        sortOrder: (personas.map(\.sortOrder).max() ?? 0) + 1,
                        isBuiltIn: false)
        try? FileManager.default.createDirectory(at: Self.memoryDir(for: p.id),
                                                withIntermediateDirectories: true)
        personas.append(p)
        persist()
        return p
    }

    /// 复制人设：连记忆目录一起复制一份新的（对标 Kelivo duplicate 连头像文件都复制）。
    func duplicatePersona(_ id: String) -> Persona? {
        guard let src = personas.first(where: { $0.id == id }) else { return nil }
        var copy = src
        copy.id = UUID().uuidString
        copy.name = src.name + " 副本"
        copy.isBuiltIn = false
        copy.sortOrder = (personas.map(\.sortOrder).max() ?? 0) + 1
        let fm = FileManager.default
        let srcDir = Self.memoryDir(for: src.id)
        let dstDir = Self.memoryDir(for: copy.id)
        if fm.fileExists(atPath: srcDir.path) {
            try? fm.copyItem(at: srcDir, to: dstDir)
        } else {
            try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        }
        personas.append(copy)
        persist()
        return copy
    }

    /// 删除人设：不许删最后一个，不许删内置；级联删它的会话（Task 跑后台，避免卡 UI）。
    func deletePersona(_ id: String) {
        guard let idx = personas.firstIndex(where: { $0.id == id }) else { return }
        guard !personas[idx].isBuiltIn else { return }
        // P2-1：default 人设是迁移锚点（老会话 persona_id 为空时的归属），
        // 删了它等于把"家"拆了——标成不可删。
        guard id != Self.defaultPersonaID else { return }
        guard personas.count > 1 else { return }
        let removed = personas.remove(at: idx)
        persist()
        try? FileManager.default.removeItem(at: Self.memoryDir(for: removed.id))
        if currentPersonaID == id {
            currentPersonaID = Self.defaultPersonaID
        }
        Task.detached {
            await ChatStore.shared.deleteSessions(forPersonaId: id)
        }
        NotificationCenter.default.post(name: .personaDidChange, object: nil)
    }

    /// 重命名（同步写回该人设 SOUL.md 的 frontmatter，保持一处真相）。
    func renamePersona(_ id: String, to name: String) {
        guard let idx = personas.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        personas[idx].name = trimmed
        persist()
        // 同步 SOUL.md frontmatter 的 name 字段
        let url = Self.memoryDir(for: id).appendingPathComponent("SOUL.md")
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            var file = SoulMDParser.parse(text)
            file.metadata.name = trimmed
            try? SoulMDParser.serialize(file).data(using: .utf8)?
                .write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: .personaDidChange, object: nil)
    }

    /// 排序（拖拽）。
    func movePersona(from source: IndexSet, to destination: Int) {
        personas.move(fromOffsets: source, toOffset: destination)
        for (i, _) in personas.enumerated() { personas[i].sortOrder = i }
        persist()
    }

    /// 切换当前人设。
    func setCurrent(_ id: String) {
        guard personas.contains(where: { $0.id == id }), id != currentPersonaID else { return }
        currentPersonaID = id
        SoulStore.refreshCache()
    }

    /// 更新某人设的白名单 / 模型绑定。
    func updatePersona(_ persona: Persona) {
        guard let idx = personas.firstIndex(where: { $0.id == persona.id }) else { return }
        // 内置人设的 isBuiltIn 不许经这里翻掉
        var p = persona
        p.isBuiltIn = personas[idx].isBuiltIn
        personas[idx] = p
        persist()
    }

    // MARK: - 小管家 SOUL.md 初值（写死的 MCP 管家规则）

    /// 脑子里只有 MCP 相关的东西。身份边界写死：非 MCP 的事直接说办不了，不编。
    static let stewardSoulContent: String = {
        let body = """
            你是"MCP小助手"，桥内置的 MCP 管家。你只管 MCP 相关的事。

            身份边界（写死）：
            - 你的世界里只有 MCP：找 MCP 工具、调 MCP 工具、接新的 MCP 进来、管 MCP 的开关。
            - 非 MCP 的问题（闲聊、写代码、查资料、画图……）直接说"我只管 MCP 相关的事，这个办不了"，不编、不绕。

            找工具（搜）：
            - 先看有哪些 MCP server（`minis-mcp-cli`），再按关键词找工具。
            - 给调用方只回：名字 + 一句话简介 + 参数简述。不贴全文。

            调工具（命令）：
            - 像收到用户消息一样直接执行，不废话、不解释、不铺垫。
            - 能做就做：有结果回结果，报错原样回，不吞错、不编成功。

            接新的 MCP（脏活归你）：
            - 她发你一个链接/配置，你先谈鉴权：要 key 就问她要，key 只进钥匙串，绝不写进聊天记录和配置文件明文。
            - 连上后拉工具清单，把清单念给她听：有哪些工具、干什么的。
            - 她点确认才落盘接入。她没点头之前，一个字都不写。

            结果清洗：
            - 回结果前先洗干净：去 ANSI 转义、折叠重复进度行、JSON 精简、留头留尾。只回高密度的。

            敏感动作：
            - 删数据、对外发送、发 Issue 这类，先问她。她超时没确认或不在手机旁，默认拒绝。
            """
        return SoulMDParser.serialize(SoulFile(
            metadata: SoulMetadata(name: "MCP小助手", emoji: "",
                                   style: "简洁、直接，不废话", lang: "zh", icon: ""),
            body: body))
    }()
}

// MARK: - 通知

extension Notification.Name {
    /// 当前人设切换 / 人设增删改后发出。UI 刷新人设相关显示。
    static let personaDidChange = Notification.Name("MinisPersonaDidChange")
}
