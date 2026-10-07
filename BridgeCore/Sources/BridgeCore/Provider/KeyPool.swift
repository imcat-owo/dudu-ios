import Foundation

/// 密钥池：多把密钥轮流用（round-robin），失败累计到阈值就进冷却，
/// 冷却中的跳过；成功一次清零失败计数并解除冷却。
/// 时钟可注入，方便单测里拨时间验证冷却恢复。
public actor KeyPool {
    private var keys: [ProviderKey]
    private var cursor = 0
    private var failureCounts: [UUID: Int] = [:]
    private let failureThreshold: Int
    private let cooldownSeconds: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        keys: [ProviderKey],
        failureThreshold: Int = 1,
        cooldownSeconds: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keys = keys
        self.failureThreshold = max(failureThreshold, 1)
        self.cooldownSeconds = cooldownSeconds
        self.now = now
    }

    /// 取下一把可用密钥（启用中、未冷却），轮换游标随之推进。
    /// 全部不可用返回 nil，由调用方报「没有可用密钥」。
    public func nextKey() -> ProviderKey? {
        guard !keys.isEmpty else { return nil }
        for offset in 0..<keys.count {
            let index = (cursor + offset) % keys.count
            if isUsable(keys[index]) {
                cursor = (index + 1) % keys.count
                return keys[index]
            }
        }
        return nil
    }

    /// 记一次失败：达到阈值 → 进冷却、计数清零。
    public func markFailure(keyID: UUID) {
        failureCounts[keyID, default: 0] += 1
        guard failureCounts[keyID, default: 0] >= failureThreshold else { return }
        failureCounts[keyID] = 0
        if let index = keys.firstIndex(where: { $0.id == keyID }) {
            keys[index].cooldownUntil = now().addingTimeInterval(cooldownSeconds)
        }
    }

    /// 记一次成功：失败计数清零、解除冷却。
    public func markSuccess(keyID: UUID) {
        failureCounts[keyID] = 0
        if let index = keys.firstIndex(where: { $0.id == keyID }) {
            keys[index].cooldownUntil = nil
        }
    }

    /// 当前池内密钥快照（含冷却状态），供界面与测试查看。
    public func snapshot() -> [ProviderKey] {
        keys
    }

    private func isUsable(_ key: ProviderKey) -> Bool {
        guard key.isEnabled else { return false }
        if let until = key.cooldownUntil, until > now() { return false }
        return true
    }
}
