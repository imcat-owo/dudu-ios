import Foundation
import Security

// MARK: - 联网搜索 key 的钥匙串存取（[s2-search]）
//
// 老规矩：key 只进钥匙串、不进 UserDefaults、不进日志、界面只显示
// 已填/未填。多把 key 拼成一个值存（换行分隔），读取时拆开。
// 写法沿用 BridgeRelayTokenStore 的仓内现成套路：不可同步（不走 iCloud）、
// AfterFirstUnlock 可读。

enum WebSearchKeys {
    static let service = "bridge.websearch"

    /// 读某服务商的全部 key（按存入顺序）。
    static func keys(for providerId: String) -> [String] {
        guard let data = keychainGet(account: providerId),
              let joined = String(data: data, encoding: .utf8) else { return [] }
        return joined
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func hasKeys(for providerId: String) -> Bool {
        !keys(for: providerId).isEmpty
    }

    static func keyCount(for providerId: String) -> Int {
        keys(for: providerId).count
    }

    /// 存某服务商的全部 key（空数组 = 清除，与仓内其他 secret 存储同口径）。
    static func save(keys: [String], for providerId: String) {
        let clean = keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if clean.isEmpty {
            delete(for: providerId)
            return
        }
        keychainSet(Data(clean.joined(separator: "\n").utf8), account: providerId)
    }

    static func delete(for providerId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain primitives（与 BridgeRelayTokenStore 同形）

    private static let log = AppLogger(category: "WebSearch")

    private static func keychainSet(_ data: Data, account: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add.merge(attrs) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // 只记状态码，绝不记 key 内容。
            log.error("[Keychain] websearch key save failed account=\(account) status=\(status)")
        }
    }

    private static func keychainGet(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
