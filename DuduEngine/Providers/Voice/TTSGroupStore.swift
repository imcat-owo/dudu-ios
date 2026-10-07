import Foundation

// MARK: - TTS Group layer
//
// [tts-groups 2026-10-02] 醒醒：「目前只有 API 分组列表，没有 TTS 分组列表」。
// 对标 Providers/ModelGroup.swift：一个分组 = 有序的多个 TTS 服务，合成时按
// 顺序 fallback（第一个挂了自动换下一个）。和 ModelGroup 的区别：
//   - 只有 fallback 一种策略（轮询对语音没意义——同一个人设前后两句换音色会很怪）；
//   - 没有 iCloud 合并那套（v1 先不做）。
// 分组只存服务 id 引用；服务被删了在读取时懒过滤（candidates），不写回。

/// TTS 服务分组：有序成员，顺序 = fallback 顺序。
struct TTSGroup: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    /// 有序的 TTSServiceOptions.id。
    var memberServiceIds: [String]

    init(id: String = UUID().uuidString, name: String, memberServiceIds: [String] = []) {
        self.id = id
        self.name = name
        self.memberServiceIds = memberServiceIds
    }
}

/// TTS 分组存储：UserDefaults JSON，和 TTSServiceStore 同一套变更通知
///（.ttsServicesChanged），设置 UI 和合成链路都读这里。
final class TTSGroupStore: @unchecked Sendable {
    static let shared = TTSGroupStore()

    private static let groupsKey = "tts.groups.v1"
    private static let defaultKey = "tts.defaultGroupId.v1"

    private let lock = NSLock()
    private var _groups: [TTSGroup]
    private var _defaultGroupId: String?

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.groupsKey),
           let decoded = try? JSONDecoder().decode([TTSGroup].self, from: data) {
            _groups = decoded
        } else {
            _groups = []
        }
        let gid = d.string(forKey: Self.defaultKey)
        _defaultGroupId = (gid != nil && _groups.contains(where: { $0.id == gid })) ? gid : nil
    }

    // MARK: Reads

    var groups: [TTSGroup] {
        lock.lock(); defer { lock.unlock() }
        return _groups
    }

    var defaultGroupId: String? {
        lock.lock(); defer { lock.unlock() }
        return _defaultGroupId
    }

    func group(id: String) -> TTSGroup? {
        lock.lock(); defer { lock.unlock() }
        return _groups.first { $0.id == id }
    }

    func defaultGroup() -> TTSGroup? {
        lock.lock(); defer { lock.unlock() }
        guard let gid = _defaultGroupId else { return nil }
        return _groups.first { $0.id == gid }
    }

    /// 默认分组里「还存在、已启用」的成员服务（按分组顺序）。合成链路用这个。
    func defaultGroupCandidates() -> [TTSServiceOptions] {
        guard let g = defaultGroup() else { return [] }
        return candidates(for: g)
    }

    /// 某分组的可用成员（按顺序，已删/已停用的被过滤掉）。
    func candidates(for group: TTSGroup) -> [TTSServiceOptions] {
        let store = TTSServiceStore.shared
        return group.memberServiceIds.compactMap { store.service(id: $0) }.filter { $0.enabled }
    }

    // MARK: Writes

    @discardableResult
    func createGroup(name: String) -> TTSGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = TTSGroup(name: trimmed.isEmpty ? "未命名分组" : trimmed)
        lock.lock()
        _groups.append(g)
        // 第一个分组自动成为默认分组（和 model group 的默认组语义对齐）。
        if _groups.count == 1 { _defaultGroupId = g.id }
        let snapshot = _groups
        let def = _defaultGroupId
        lock.unlock()
        persist(snapshot, defaultGroupId: def)
        return g
    }

    func updateGroup(_ group: TTSGroup) {
        lock.lock()
        if let i = _groups.firstIndex(where: { $0.id == group.id }) { _groups[i] = group }
        let snapshot = _groups
        let def = _defaultGroupId
        lock.unlock()
        persist(snapshot, defaultGroupId: def)
    }

    func moveGroup(from source: IndexSet, to destination: Int) {
        lock.lock()
        var arr = _groups
        let items = source.sorted().map { arr[$0] }
        for idx in source.sorted(by: >) { arr.remove(at: idx) }
        let dest = destination - source.filter { $0 < destination }.count
        arr.insert(contentsOf: items, at: max(0, min(dest, arr.count)))
        _groups = arr
        let snapshot = _groups
        let def = _defaultGroupId
        lock.unlock()
        persist(snapshot, defaultGroupId: def)
    }

    func removeGroup(id: String) {
        lock.lock()
        _groups.removeAll { $0.id == id }
        if _defaultGroupId == id {
            _defaultGroupId = _groups.first?.id
        }
        let snapshot = _groups
        let def = _defaultGroupId
        lock.unlock()
        persist(snapshot, defaultGroupId: def)
    }

    func setDefaultGroupId(_ id: String?) {
        lock.lock()
        if let id, _groups.contains(where: { $0.id == id }) {
            _defaultGroupId = id
        } else if id == nil {
            _defaultGroupId = nil
        }
        let snapshot = _groups
        let def = _defaultGroupId
        lock.unlock()
        persist(snapshot, defaultGroupId: def)
    }

    // MARK: Persistence

    private func persist(_ list: [TTSGroup], defaultGroupId: String?) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(list) {
            d.set(data, forKey: Self.groupsKey)
        }
        if let defaultGroupId {
            d.set(defaultGroupId, forKey: Self.defaultKey)
        } else {
            d.removeObject(forKey: Self.defaultKey)
        }
        NotificationCenter.default.post(name: .ttsServicesChanged, object: nil)
    }
}
