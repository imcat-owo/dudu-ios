import Foundation
import Security
import os.log

private let logger = AppLogger(category: "ProviderMigration")

/// Migrates existing provider configuration (AuthMode, API keys, OAuth state)
/// into the new ProviderInstance / ModelEntry / ModelGroup system.
@MainActor
enum ProviderMigration {

    private static let migrationKey = "com.openminis.clone.provider-migration-v1-done"
    private static let oauthMigrationKey = "com.openminis.clone.provider-migration-oauth-v2-done"

    /// Run migration if it hasn't been performed yet.
    static func migrateIfNeeded(store: ProviderConfigStore) {
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            logger.info("Starting provider migration from legacy config")
            migrate(store: store)
            UserDefaults.standard.set(true, forKey: migrationKey)
            logger.info("Provider migration complete")
        }

        if !UserDefaults.standard.bool(forKey: oauthMigrationKey) {
            // [R3-026] Only mark the OAuth migration done when every legacy
            // item was verifiably copied. Previously the flag was set
            // unconditionally while the copy helpers fail silently (Void,
            // log-only), so a failed Keychain write permanently lost the
            // login and was never retried.
            if migrateOAuthTokens(store: store) {
                UserDefaults.standard.set(true, forKey: oauthMigrationKey)
            } else {
                logger.error("OAuth token migration incomplete — legacy credentials kept, will retry on next launch")
            }
        }
    }

    // MARK: - V2: Migrate singleton OAuth tokens → per-instance storage

    /// Returns true when there is nothing left to migrate (every legacy
    /// token/string was copied AND read back from its new home). A legacy
    /// value is deleted only after its copy verifies; on any failure the
    /// legacy value is kept and false is returned so the caller leaves the
    /// done flag unset and the migration retries on a later launch.
    @discardableResult
    private static func migrateOAuthTokens(store: ProviderConfigStore) -> Bool {
        logger.info("Starting OAuth token migration to per-instance storage")
        var allCopied = true

        for instance in store.instances where instance.credentialType == .oauth {
            switch instance.providerType {
            case .anthropic:
                // Skip if per-instance token already exists
                if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: ClaudeTokenStorage.self) != nil {
                    continue
                }
                if let token = ClaudeOAuthManager.loadLegacyToken() {
                    ProviderKeychainHelper.saveOAuthToken(token, instanceId: instance.id)
                    // [R3-026] saveOAuthToken is Void and fails silently —
                    // delete the legacy token only if the copy reads back.
                    if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: ClaudeTokenStorage.self) != nil {
                        ClaudeOAuthManager.deleteLegacyToken()
                        logger.info("Migrated Claude OAuth token to instance \(instance.id)")
                    } else {
                        allCopied = false
                        logger.error("Claude OAuth token copy did not verify for instance \(instance.id) — keeping legacy token")
                    }
                }

            case .gemini:
                if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: GeminiTokenStorage.self) != nil {
                    continue
                }
                if let token = GeminiOAuthManager.loadLegacyToken() {
                    ProviderKeychainHelper.saveOAuthToken(token, instanceId: instance.id)
                    // [R3-026] Delete the legacy token only if the copy reads back.
                    if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: GeminiTokenStorage.self) != nil {
                        GeminiOAuthManager.deleteLegacyToken()
                        logger.info("Migrated Gemini OAuth token to instance \(instance.id)")
                    } else {
                        allCopied = false
                        logger.error("Gemini OAuth token copy did not verify for instance \(instance.id) — keeping legacy token")
                    }
                }
                // Migrate email and project ID from UserDefaults
                if let email = UserDefaults.standard.string(forKey: GeminiOAuthManager.legacyEmailKey) {
                    ProviderKeychainHelper.saveOAuthString(email, instanceId: instance.id, account: "oauth-email")
                    // [R3-026] Remove the legacy value only if the copy reads back.
                    if ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "oauth-email") == email {
                        UserDefaults.standard.removeObject(forKey: GeminiOAuthManager.legacyEmailKey)
                    } else {
                        allCopied = false
                        logger.error("Gemini OAuth email copy did not verify for instance \(instance.id) — keeping legacy value")
                    }
                }
                if let projectID = UserDefaults.standard.string(forKey: GeminiOAuthManager.legacyProjectIDKey) {
                    ProviderKeychainHelper.saveOAuthString(projectID, instanceId: instance.id, account: "oauth-gcp-project")
                    // [R3-026] Remove the legacy value only if the copy reads back.
                    if ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "oauth-gcp-project") == projectID {
                        UserDefaults.standard.removeObject(forKey: GeminiOAuthManager.legacyProjectIDKey)
                    } else {
                        allCopied = false
                        logger.error("Gemini GCP project ID copy did not verify for instance \(instance.id) — keeping legacy value")
                    }
                }

            case .openAI:
                if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: CodexTokenStorage.self) != nil {
                    continue
                }
                if let token = CodexOAuthManager.loadLegacyToken() {
                    ProviderKeychainHelper.saveOAuthToken(token, instanceId: instance.id)
                    // [R3-026] Delete the legacy token only if the copy reads back.
                    if ProviderKeychainHelper.loadOAuthToken(instanceId: instance.id, as: CodexTokenStorage.self) != nil {
                        CodexOAuthManager.deleteLegacyToken()
                        logger.info("Migrated Codex OAuth token to instance \(instance.id)")
                    } else {
                        allCopied = false
                        logger.error("Codex OAuth token copy did not verify for instance \(instance.id) — keeping legacy token")
                    }
                }

            case .antigravity:
                // No legacy tokens to migrate for Antigravity (new provider)
                break
            case .openRouter:
                // No legacy tokens to migrate for OpenRouter (new provider)
                break
            case .openAIResponses:
                break
            case .xAI:
                // xAI is a new provider; no legacy singleton tokens to migrate.
                break
            case .kimiCode:
                // Kimi is a new provider; no legacy singleton tokens to migrate.
                break
            case .unsupported:
                break
            }
        }

        logger.info("OAuth token migration complete")
        return allCopied
    }

    // MARK: - V1: Legacy migration

    private static func migrate(store: ProviderConfigStore) {
        var config = ProviderConfig.empty
        var firstGroupEntryIds: [String] = []

        // MARK: - Anthropic

        // API Key
        if let key = readLegacyKeychain(service: "com.openminis.clone.anthropic-api-key") {
            let instance = ProviderInstance(
                label: "Anthropic API Key",
                providerType: .anthropic,
                credentialType: .apiKey
            )
            config.instances.append(instance)
            let entries = LLMModel.allAnthropic.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)
            // Save key to new keychain location
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)

            if isLegacyActiveProvider("API Key") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // OAuth — check legacy singleton keychain directly
        if ClaudeOAuthManager.loadLegacyToken() != nil {
            let instance = ProviderInstance(
                label: "Claude OAuth",
                providerType: .anthropic,
                credentialType: .oauth
            )
            config.instances.append(instance)
            let entries = LLMModel.allAnthropic.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)

            if isLegacyActiveProvider("OAuth") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // MARK: - Gemini

        // API Key
        if let key = readLegacyKeychain(service: "com.openminis.clone.gemini-api-key") {
            let instance = ProviderInstance(
                label: "Gemini API Key",
                providerType: .gemini,
                credentialType: .apiKey
            )
            config.instances.append(instance)
            let entries = LLMModel.allGemini.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)

            if isLegacyActiveProvider("Gemini API Key") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // OAuth
        if GeminiOAuthManager.loadLegacyToken() != nil {
            let instance = ProviderInstance(
                label: "Gemini OAuth",
                providerType: .gemini,
                credentialType: .oauth
            )
            config.instances.append(instance)
            let entries = LLMModel.allGemini.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)

            if isLegacyActiveProvider("Gemini OAuth") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // MARK: - OpenAI

        // API Key
        if let key = readLegacyKeychain(service: "com.openminis.clone.openai-api-key") {
            let instance = ProviderInstance(
                label: "OpenAI API Key",
                providerType: .openAI,
                credentialType: .apiKey
            )
            config.instances.append(instance)
            let entries = LLMModel.allOpenAI.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)
            ProviderKeychainHelper.saveAPIKey(key, instanceId: instance.id)

            if isLegacyActiveProvider("OpenAI API Key") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // Codex OAuth
        if CodexOAuthManager.loadLegacyToken() != nil {
            let instance = ProviderInstance(
                label: "Codex OAuth",
                providerType: .openAI,
                credentialType: .oauth
            )
            config.instances.append(instance)
            // [R3-108] Codex OAuth must seed from the Codex-specific list:
            // allOpenAI contains models the Codex backend rejects with
            // HTTP 400 (gpt-5.2 / gpt-5). addInstance and the OAuth model
            // fetch both use allOpenAICodexOAuth — migration was the only
            // path still seeding the wrong list.
            let entries = LLMModel.allOpenAICodexOAuth.map {
                ModelEntry(providerInstanceId: instance.id, model: $0)
            }
            config.modelEntries.append(contentsOf: entries)

            if isLegacyActiveProvider("Codex OAuth") {
                firstGroupEntryIds = entries.map(\.id)
            }
        }

        // MARK: - Default Group

        // If we found an active provider, narrow the group to the last selected model if possible
        if !firstGroupEntryIds.isEmpty {
            // Try to match legacy AgentModelSettings primary model IDs
            let legacySettings = Self.loadLegacyAgentModelSettings()
            let primaryIds = legacySettings.primaryModelIds

            // Filter to just entries matching the legacy primary model IDs.
            // Entry ids are now "\(instanceId)/\(modelId)" ("/" separator);
            // the legacy ":" suffix could never match them.
            // Iterate the legacy ID list (the user's original order) rather
            // than the catalog-ordered entry list: group order decides the
            // fallback primary, so the user's first pick must stay first.
            let entriesInLegacyOrder: ([String]) -> [String] = { legacyIds in
                var seen = Set<String>()
                var ordered: [String] = []
                for legacyId in legacyIds {
                    for entryId in firstGroupEntryIds where entryId.hasSuffix("/\(legacyId)") {
                        if seen.insert(entryId).inserted {
                            ordered.append(entryId)
                        }
                    }
                }
                return ordered
            }
            let matchedEntries = entriesInLegacyOrder(primaryIds)

            let groupMembers = matchedEntries.isEmpty ? firstGroupEntryIds : matchedEntries

            let defaultGroup = ModelGroup(
                name: "Default",
                memberEntryIds: groupMembers,
                strategy: groupMembers.count > 1 ? .fallback : .fallback
            )
            config.modelGroups.append(defaultGroup)
            config.defaultPrimaryGroupId = defaultGroup.id

            // Sub-model group from legacy settings
            let subIds = legacySettings.subModelIds.isEmpty ? legacySettings.primaryModelIds : legacySettings.subModelIds
            if subIds != primaryIds {
                let subEntries = entriesInLegacyOrder(subIds)
                if !subEntries.isEmpty {
                    let subGroup = ModelGroup(
                        name: "Sub Tasks",
                        memberEntryIds: subEntries,
                        strategy: .fallback
                    )
                    config.modelGroups.append(subGroup)
                    config.defaultSubGroupId = subGroup.id
                }
            }
        }

        store.applyConfig(config)

        logger.info("Migration created \(config.instances.count) instances, \(config.modelEntries.count) entries, \(config.modelGroups.count) groups")
    }

    // MARK: - Legacy Helpers

    private static func readLegacyKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Legacy AgentModelSettings shape (for migration only).
    private struct LegacyAgentModelSettings: Codable {
        var primaryModelIds: [String]
        var subModelIds: [String]
    }

    private static func loadLegacyAgentModelSettings() -> LegacyAgentModelSettings {
        let key = "com.openminis.clone.agent-model-settings"
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(LegacyAgentModelSettings.self, from: data)
        else {
            return LegacyAgentModelSettings(primaryModelIds: [LLMModel.claudeSonnet46.id], subModelIds: [])
        }
        return settings
    }

    /// Check if a given raw auth mode string matches the legacy active provider keychain entry.
    private static func isLegacyActiveProvider(_ rawValue: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.openminis.clone.active-provider",
            kSecAttrAccount as String: "auth-mode",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let raw = String(data: data, encoding: .utf8) else { return false }
        return raw == rawValue
    }
}
