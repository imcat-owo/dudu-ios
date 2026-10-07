import Foundation
import Security

// MARK: - 中继口令的钥匙串存取（合并第 18(a) 条）
//
// 协议 v1 约定：kSecClassGenericPassword，service "bridge.relay"，
// account "token"。口令只存钥匙串、不进 UserDefaults、不进日志、
// 不进界面默认明文展示。
// 口令来源有两条：她在设置页粘贴填入，或点"生成强口令"由本机生成
// （generateStrongToken，32 随机字节 base64url 无 padding，与协议一致）。
// 写法沿用 MCPOAuthController 的仓内现成套路：不可同步（不走 iCloud）、
// AfterFirstUnlock 可读（后台重连时也能取到）。

enum BridgeRelayTokenStore {
    static let service = "bridge.relay"
    static let account = "token"

    private static let log = AppLogger(category: "BridgeRelay")

    /// 保存口令。空白视为清除（与仓内其他 secret 存储同口径）。
    static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete()
            return
        }
        keychainSet(Data(trimmed.utf8))
    }

    /// 读口令。取不到（没填 / 钥匙串异常）返回 nil；调用方据此提示
    /// 「口令错误 / 未配置」，不要拿空串去连——那只会白撞一次中继。
    /// 需要区分"没配"和"钥匙串暂不可读"时用 loadDetailed()。
    static func load() -> String? {
        if case .configured(let token) = loadDetailed() { return token }
        return nil
    }

    /// 口令读取的细分结果（用户-P2-6）：把"没配过"和"钥匙串暂不可读
    /// （冷启动、锁屏中等，可稍后重试）"区分开，调用方别把后者报成
    /// 红色"口令错误"吓她。
    enum TokenLoadResult {
        case configured(String)
        case notConfigured
        case readFailed
    }

    static func loadDetailed() -> TokenLoadResult {
        let (data, readFailed) = keychainGetDetailed()
        if let data, let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return .configured(token)
        }
        return readFailed ? .readFailed : .notConfigured
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 生成强口令：32 随机字节 base64url（无 padding，约 43 字符），与
    /// 协议 v1 的口令格式约定一致，够长够随机。随机源失败时回退两段
    /// UUID 拼接（仍具足够随机性），绝不返回空串。只返回口令本身，
    /// 不记日志——调用方负责落钥匙串。
    static func generateStrongToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            let b64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            if !b64.isEmpty { return b64 }
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: Keychain primitives（与 MCPOAuthController 同形）

    private static func keychainSet(_ data: Data) {
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
            // 只记状态码，绝不记口令内容。
            log.error("[Keychain] relay token save failed status=\(status)")
        }
    }

    /// 钥匙串读取（含状态区分）：errSecSuccess→值；errSecItemNotFound→没配过；
    /// 其他状态码→暂不可读（冷启动等），调用方可稍后重试。只记状态码，不记口令。
    private static func keychainGetDetailed() -> (data: Data?, readFailed: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return (result as? Data, false)
        }
        if status == errSecItemNotFound {
            return (nil, false)
        }
        log.error("[Keychain] relay token read failed status=\(status)")
        return (nil, true)
    }
}

// MARK: - 中继相关偏好（UserDefaults，非敏感部分）

/// 中继的非敏感配置：中继地址（host）与两个开关的期望状态。
/// 口令不在此列（只进钥匙串，见 BridgeRelayTokenStore）。
/// host 虽然不是秘密，但按协议约定同样不打进日志。
enum BridgeRelayPreferences {
    static let hostKey = "bridge.relay.host"
    static let relayEnabledKey = "bridge.relay.enabled"
    static let externalMCPEnabledKey = "bridge.externalMCP.enabled"

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    static var relayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: relayEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: relayEnabledKey) }
    }

    static var externalMCPEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: externalMCPEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: externalMCPEnabledKey) }
    }
}
