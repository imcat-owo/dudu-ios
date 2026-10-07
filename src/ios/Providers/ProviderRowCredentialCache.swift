// Extracted from OpenMinis Views/Providers/ProviderInstancesView.swift (pure engine, no UI).
import Foundation

/// [T-ios-provider-row-keychain-in-body] Per-row credential display state, resolved
/// ONCE per (instance, authRevision) instead of on every SwiftUI body evaluation.
///
/// `isConfigured` and `credentialSummary` were each reading Keychain directly from
/// `body`. Every `SecItemCopyMatching` is a synchronous XPC round-trip to
/// `securityd`, so one body pass over N provider rows cost 2N blocking IPCs on the
/// MAIN THREAD — a real user log shows 110 `caller=isConfigured` +
/// 110 `caller=credentialSummary` reads in a single session (655 Keychain reads
/// overall). A crash report from that same session caught the main thread parked
/// inside `SecItemCopyMatching` under `InstanceRow.body`.
///
/// This is the same hazard `ProviderCredentialCache`
/// ([T-new-session-hang-credential-cache]) already exists for; the row simply
/// bypassed it. A separate cache is used rather than `hasAnyCredential` because
/// the row needs strictly more than a Bool — it renders the MASKED KEY, and its
/// OAuth notion of "authenticated" is per-provider-manager, not the router's
/// any-credential test. Reusing `hasAnyCredential` here would silently change
/// what the row displays.
///
/// Keying on `authRevision` (bumped by `notifyAuthChanged` on every credential
/// write/delete) makes invalidation exact: the UI still updates immediately after
/// the user adds or removes a key. The TTL is only a backstop for credential
/// changes that happen outside the app (Keychain iCloud sync).
final class ProviderRowCredentialCache: @unchecked Sendable {
    static let shared = ProviderRowCredentialCache()

    struct Display {
        let isConfigured: Bool
        let summary: String
    }

    /// Backstop only — `authRevision` is the primary invalidation signal.
    private static let ttl: TimeInterval = 15

    private let lock = NSLock()
    private var entries: [String: (value: Display, revision: UInt, at: Date)] = [:]

    private init() {}

    /// Drop everything. Called from the SAME places that clear
    /// `ProviderCredentialCache`, because those events (Keychain iCloud
    /// `view-change`, app foreground) change credentials WITHOUT bumping
    /// `authRevision` — so the revision key alone would not notice them.
    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func value(for instanceId: String, revision: UInt, probe: () -> Display) -> Display {
        let now = Date()
        lock.lock()
        if let e = entries[instanceId], e.revision == revision,
           now.timeIntervalSince(e.at) < Self.ttl {
            lock.unlock()
            return e.value
        }
        lock.unlock()

        // Probe runs OUTSIDE the lock — it does Keychain XPC and must not
        // serialize concurrent probes for different instances.
        let fresh = probe()

        lock.lock()
        entries[instanceId] = (fresh, revision, now)
        lock.unlock()
        return fresh
    }
}
