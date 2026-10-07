import Combine
import Foundation
import SwiftUI

// MARK: - Types

enum OffloadPermissionLevel: Int, CaseIterable {
    case bypass = 0
    case askOnce = 1
    case notAllowed = 2

    var displayName: String {
        switch self {
        case .bypass: return "Bypass"
        case .askOnce: return "Ask Once"
        case .notAllowed: return "Not Allowed"
        }
    }
}

enum PermissionResult {
    case allowed
    case denied(String)
}

struct PermissionRequest: Identifiable {
    /// 底座挂起 id（OffloadPermissionDialog 用它调 respond）。
    let id: String
    let commandName: String
    let displayLabel: String
    let description: String
    /// The full shell command string, e.g. "apple-healthkit query --type steps"
    let fullCommand: String

    /// Parse the command arguments into displayable key-value pairs.
    /// Handles patterns like: `command subcommand --key value --flag`.
    ///
    /// Only the FIRST shell command's tokens are surfaced — anything past a
    /// pipe / chain operator (`&&`, `||`, `;`, `|`) or a redirect (`>`,
    /// `>>`, `<`) belongs to a separate process or is plumbing the user
    /// shouldn't have to skim through to grant a permission. Without this
    /// gate the previous parser dumped the redirect target, the chained
    /// `python3 -c "..."` blob, and every word inside the quoted python
    /// snippet as `arg` rows, pushing the Allow / Deny buttons below the
    /// sheet's bottom edge.
    var parsedArguments: [(key: String, value: String)] {
        let parts = Self.firstCommandTokens(fullCommand)
        guard parts.count > 1 else { return [] }

        var result: [(key: String, value: String)] = []
        // First non-command token is the subcommand
        var idx = 1
        if idx < parts.count && !parts[idx].hasPrefix("-") {
            result.append((key: "Action", value: parts[idx]))
            idx += 1
        }
        while idx < parts.count {
            let token = parts[idx]
            if token.hasPrefix("--") || token.hasPrefix("-") {
                let key = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if idx + 1 < parts.count && !parts[idx + 1].hasPrefix("-") {
                    result.append((key: key, value: parts[idx + 1]))
                    idx += 2
                } else {
                    result.append((key: key, value: "true"))
                    idx += 1
                }
            } else {
                result.append((key: "arg", value: token))
                idx += 1
            }
        }
        return result
    }

    /// Whitespace-split the command but stop at the first shell separator so
    /// only the head command's tokens are returned. This is permissive about
    /// quoting (we don't try to honour `'...'` / `"..."` boundaries) — good
    /// enough for the permission-row preview where we just want to suppress
    /// the long tail past `&&`, redirects, etc. that confused users.
    private static let shellSeparators: Set<String> = [
        "&&", "||", ";", "|", ">", ">>", "<", "<<", "&",
    ]

    private static func firstCommandTokens(_ command: String) -> [String] {
        let raw = command.split(separator: " ").map(String.init)
        var head: [String] = []
        for token in raw {
            if shellSeparators.contains(token) { break }
            head.append(token)
        }
        return head
    }
}

// MARK: - Command Definitions

enum OffloadCommandCategory: String, CaseIterable {
    case privacy = "Privacy"
    case media = "Media"
    case system = "System"
}

struct OffloadCommandInfo {
    let name: String
    let displayLabel: String
    let description: String
    let category: OffloadCommandCategory
    /// Only privacy-sensitive commands appear in Settings
    let showInSettings: Bool
}

// MARK: - Manager

/// Fallback session id used when an offload permission check has no chat session
/// context (e.g. invocations outside the chat flow, or before a session id has
/// been assigned). Mirrors the Android constant `OFFLOAD_GLOBAL_SESSION_ID`
/// (commit 20d8e68) so per-session grants stay wire-compatible across platforms.
let OFFLOAD_GLOBAL_SESSION_ID = "offload-global"

@MainActor
final class OffloadPermissionManager: ObservableObject {
    static let shared = OffloadPermissionManager()

    static let allCommands: [OffloadCommandInfo] = [
        // Privacy — user-configurable
        .init(name: "apple-healthkit", displayLabel: "HealthKit", description: "Steps, heart rate, sleep, and other health records", category: .privacy, showInSettings: true),
        .init(name: "apple-calendar", displayLabel: "Calendar", description: "Events, schedules, and calendar details", category: .privacy, showInSettings: true),
        .init(name: "apple-reminders", displayLabel: "Reminders", description: "Tasks, due dates, and reminder lists", category: .privacy, showInSettings: true),
        .init(name: "apple-photos", displayLabel: "Photos", description: "Photos, videos, and album metadata", category: .privacy, showInSettings: true),
        .init(name: "apple-location", displayLabel: "Location", description: "Current GPS coordinates and location history", category: .privacy, showInSettings: true),
        .init(name: "apple-homekit", displayLabel: "HomeKit", description: "Smart home devices, rooms, and scenes", category: .privacy, showInSettings: true),
        .init(name: "apple-clipboard", displayLabel: "Clipboard", description: "Text and images copied to the clipboard", category: .privacy, showInSettings: true),
        // [batch7 用户-P2-1] 蓝牙 BLE：扫描附近设备、连接并读写特征——隐私敏感，
        // 登记进权限表后，聊天流与桥管线（OffloadToolRunner）都会走权限关卡。
        .init(name: "apple-bluetooth", displayLabel: "Bluetooth", description: "BLE 扫描、连接并读写附近蓝牙设备", category: .privacy, showInSettings: true),
        // Media — no personal data, always bypass
        .init(name: "apple-speak", displayLabel: "Speak", description: "", category: .media, showInSettings: false),
        .init(name: "apple-speech", displayLabel: "Speech", description: "", category: .media, showInSettings: false),
        .init(name: "apple-player", displayLabel: "Player", description: "", category: .media, showInSettings: false),
        .init(name: "apple-media", displayLabel: "Media", description: "", category: .media, showInSettings: false),
        // System — no personal data, always bypass
        .init(name: "apple-device", displayLabel: "Device", description: "", category: .system, showInSettings: false),
        .init(name: "apple-notification", displayLabel: "Notification", description: "", category: .system, showInSettings: false),
        .init(name: "apple-alarm", displayLabel: "Alarm", description: "", category: .system, showInSettings: false),
        .init(name: "apple-open", displayLabel: "Open URL", description: "", category: .system, showInSettings: false),
        .init(name: "apple-maps", displayLabel: "Maps", description: "", category: .system, showInSettings: false),
        .init(name: "apple-weather", displayLabel: "Weather", description: "", category: .system, showInSettings: false),
        .init(name: "apple-nlp", displayLabel: "NLP", description: "", category: .system, showInSettings: false),
        .init(name: "apple-vision", displayLabel: "Vision", description: "", category: .system, showInSettings: false),
    ]

    @Published var pendingRequest: PermissionRequest?

    /// Bumped on every permission-level write so settings rows (which read
    /// levels straight from UserDefaults via `permissionLevel(for:)`) can
    /// re-render. Levels themselves are not @Published, so without this a
    /// bulk change like `setAllBypass()` never reached the UI and rows kept
    /// showing the level seeded when the page was opened.
    @Published private(set) var levelsRevision = 0

    /// [s2-suspend-base] 挂起底座：排队、超时、会话放行都由它管，
    /// 本类只负责 offload 审批语义（权限等级 → 挂起/放行/拒绝）与弹窗映射。
    private let suspension = ToolSuspensionService.shared
    private var cancellables = Set<AnyCancellable>()

    private let defaults = UserDefaults.standard
    private let logger = AppLogger(category: "OffloadPermission")

    private init() {
        // 底座当前呈现的是 offload 审批 → 映射成 PermissionRequest 给弹窗；
        // 其他 tag（工具审批/问用户）各自由自己的弹窗消费，这里映射成 nil。
        suspension.$current
            .map { [weak self] req -> PermissionRequest? in
                guard let self, let req, req.tag == "offload",
                      case .approval(let payload) = req.kind
                else { return nil }
                let ctx = payload.context
                guard let commandName = ctx["commandName"] else { return nil }
                return PermissionRequest(
                    id: req.id,
                    commandName: commandName,
                    displayLabel: ctx["displayLabel"] ?? commandName,
                    description: ctx["description"] ?? "",
                    fullCommand: ctx["fullCommand"] ?? ""
                )
            }
            .assign(to: &$pendingRequest)
    }

    // MARK: - Storage

    private func defaultsKey(for command: String) -> String {
        "offloadPermission.\(command)"
    }

    func permissionLevel(for command: String) -> OffloadPermissionLevel {
        let raw = defaults.integer(forKey: defaultsKey(for: command))
        return OffloadPermissionLevel(rawValue: raw) ?? .bypass
    }

    func setPermissionLevel(_ level: OffloadPermissionLevel, for command: String) {
        defaults.set(level.rawValue, forKey: defaultsKey(for: command))
        levelsRevision += 1
    }

    func setAllBypass() {
        for cmd in Self.allCommands {
            setPermissionLevel(.bypass, for: cmd.name)
        }
        suspension.clearAllSessionGrants()
    }

    // MARK: - Command Extraction

    /// The offload command a shell invocation will actually run, or nil.
    ///
    /// [GH#242] Matched on the first token's BASENAME, because that is what the
    /// guest kernel dispatches on: `native_offload_lookup()` →
    /// `offload_find()` takes `strrchr(guest_path, '/')` and compares the
    /// trailing component against the registry
    /// (deps/ish/kernel/native_offload.c:186-196).
    ///
    /// This function used to compare the raw first token, so
    /// `/usr/local/bin/apple-healthkit` matched nothing and returned nil — and
    /// the caller reads nil as "not an offload command" and runs it unchecked
    /// (AIChatViewModel+ConcurrentTools.swift). The kernel then dispatched it
    /// anyway on basename, so an absolute path reached HealthKit / HomeKit /
    /// Photos / Location with no prompt, regardless of Bypass / Ask Once /
    /// Not Allowed. Verified on device: `/usr/local/bin/apple-clipboard` is a
    /// ZERO-byte placeholder yet returned real clipboard JSON, which is only
    /// possible via that native dispatch.
    ///
    /// Two matchers over one decision will drift again, so the rule here is
    /// deliberately the kernel's rule and nothing else. Registered names are
    /// bare (no slashes), so normalising the caller's side is sufficient.
    ///
    /// Scope: this closes path-based spellings (absolute, `./`, `../`, any
    /// prefix). It does NOT cover indirection where the first token is a
    /// different program — `sh -c '…'`, `env …`, a script, a subprocess — for
    /// which the name never appears as argv[0] here. Those need the check to
    /// move to the dispatch site itself; see the issue.
    static func extractOffloadCommand(from shellCommand: String) -> String? {
        let trimmed = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        let basename = (firstToken as NSString).lastPathComponent
        // Return the REGISTERED name, not the caller's spelling: every consumer
        // (permissionLevel, sessionGrants, the prompt's display label) keys off
        // the registry, and handing back "/usr/local/bin/apple-healthkit" would
        // look up nothing and silently degrade to the default level.
        if allCommands.contains(where: { $0.name == basename }) {
            return basename
        }
        return nil
    }

    // MARK: - Permission Check

    func checkPermission(for command: String, sessionId: String?, fullCommand: String = "") async -> PermissionResult {
        // Mirror Android: prefer the caller-supplied session id; fall back to the
        // global bucket when the chat hasn't bound a session yet (or when invoked
        // outside chat). This keeps `Ask Once` grants per-session when possible
        // while still working for non-chat callers.
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionId = trimmed.isEmpty ? OFFLOAD_GLOBAL_SESSION_ID : trimmed
        let level = permissionLevel(for: command)

        switch level {
        case .bypass:
            return .allowed

        case .notAllowed:
            logger.info("Permission denied (Not Allowed): \(command)")
            return .denied("Permission denied: the user has disabled '\(command)'. To enable it, go to Settings > Permissions or tap: [Open Permissions](minis-clone://settings/permissions)")

        case .askOnce:
            // 本次会话已放行（"Allow in Session" 点过）
            if suspension.hasSessionGrant("offload:\(command)", sessionId: sessionId) {
                return .allowed
            }

            let cmdInfo = Self.allCommands.first(where: { $0.name == command })
            // 挂起到底座：排队/30 秒超时/弹窗都由底座管。
            // "Allow in Session" 点了就记会话放行，所以 allowSessionGrant 不用
            // 再给开关——approve 固定带 grantSession: true（见 respond）。
            let decision = await suspension.suspendApproval(
                tag: "offload",
                title: cmdInfo?.displayLabel ?? command,
                description: cmdInfo?.description ?? "",
                grantKey: "offload:\(command)",
                allowSessionGrant: false,
                approveLabel: "Allow in Session",
                denyLabel: "Deny in Session",
                denyMessage: "",
                context: [
                    "commandName": command,
                    "displayLabel": cmdInfo?.displayLabel ?? command,
                    "description": cmdInfo?.description ?? "",
                    "fullCommand": fullCommand,
                ],
                sessionId: sessionId,
                timeoutSeconds: 30
            )

            switch decision {
            case .approved:
                logger.info("Permission granted (Ask Once): \(command)")
                return .allowed
            case .timedOut:
                logger.info("Permission timed out (Ask Once): \(command)")
                return .denied("Permission denied: authorization for '\(command)' timed out. To change permissions: [Open Permissions](minis-clone://settings/permissions)")
            case .denied:
                logger.info("Permission denied (Ask Once): \(command)")
                return .denied("Permission denied: the user declined '\(command)' for this session. To change permissions: [Open Permissions](minis-clone://settings/permissions)")
            default:
                // 问用户/跳过这类决策不会出现在审批挂起里，防御性地按拒绝处理。
                logger.info("Permission denied (Ask Once, unexpected decision): \(command)")
                return .denied("Permission denied: the user declined '\(command)' for this session. To change permissions: [Open Permissions](minis-clone://settings/permissions)")
            }
        }
    }

    // MARK: - UI Response

    func respond(to requestId: String, allowed: Bool) {
        guard pendingRequest?.id == requestId else { return }
        // "Allow in Session"：点了就放行本会话（grantSession: true），
        // 与旧逻辑"允许即记 sessionGrants"一致。
        suspension.respond(id: requestId, decision: allowed ? .approved(grantSession: true) : .denied)
    }

    // MARK: - Session Reset

    func resetSessionGrants(for sessionId: String) {
        suspension.clearSessionGrants(sessionId: sessionId)
    }
}
