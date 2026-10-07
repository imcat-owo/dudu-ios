import Foundation
import UserNotifications
import SwiftUI

// MARK: - [T-scheduled-prompt 09-13] W1: scheduled local notifications that
// wake the agent on tap.
//
// The workorder asked for exactly ONE thing with an honest boundary: a
// scheduled local notification whose TAP opens a session and auto-sends a
// preset prompt ("每天自醒一次：翻 daily、摸抽屉、留一条「今天我在」"). iOS
// gives no unattended background execution — notification-tap IS the physical
// ceiling, and this implementation stays inside it:
//
//   schedule: UNCalendarNotificationTrigger (system delivers while suspended)
//   tap:      ShortcutNotificationDelegate.didReceive → the scheduledPrompt
//             category routes here → opens session + auto-sends prompt
//   no promises beyond that: if the notification is never tapped, nothing
//   runs. The card body says so in plain language.
//
// Storage: UserDefaults (id-keyed JSON array). A prompt's session binding is
// optional — nil means "new session each fire" (the daily check-in use case).

enum ScheduledPromptRepeat: String, Codable, CaseIterable, Identifiable {
    case daily
    case weekly
    case once
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .daily: return AppLocalized("Every day")
        case .weekly: return AppLocalized("Every week")
        case .once: return AppLocalized("Once")
        }
    }
}

struct ScheduledPrompt: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var prompt: String
    var hour: Int
    var minute: Int
    var repeatRule: ScheduledPromptRepeat
    var enabled: Bool = true
    /// Weekday for .weekly (1=Sunday ... 7=Saturday, matching DateComponents).
    var weekday: Int = 1
    /// nil = open a NEW session each fire; non-nil = continue that session.
    var sessionId: String?
}

// MARK: - Notification category union registry
//
// `setNotificationCategories` REPLACES the whole registered set, so a
// site that registers only its own category silently unregisters every
// other feature's — most visibly the scheduled prompts' "Run now"
// action vanished after any shortcut run. Every registration must go
// through here, which keeps the union of all categories seen so far
// and always applies the full set.
enum NotificationCategoryRegistry {
    private static var categories: [String: UNNotificationCategory] = [:]
    private static let lock = NSLock()

    static func register(_ category: UNNotificationCategory) {
        lock.lock()
        categories[category.identifier] = category
        let all = Set(categories.values)
        lock.unlock()
        UNUserNotificationCenter.current().setNotificationCategories(all)
    }
}

@MainActor
final class ScheduledPromptStore: ObservableObject {
    static let shared = ScheduledPromptStore()
    private static let storageKey = "scheduled.prompts.v1"
    private static let category = "scheduledPrompt"

    @Published private(set) var prompts: [ScheduledPrompt] = []
    private let logger = AppLogger(category: "ScheduledPrompt")

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ScheduledPrompt].self, from: data) {
            prompts = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(prompts) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Register the tap-action category once. Safe to call repeatedly.
    func registerCategory() {
        let action = UNNotificationAction(
            identifier: "RUN_NOW",
            title: AppLocalized("Run now")
        )
        let category = UNNotificationCategory(
            identifier: Self.category,
            actions: [action],
            intentIdentifiers: []
        )
        NotificationCategoryRegistry.register(category)
    }

    /// Add or update one prompt and (re)schedule its notification.
    func upsert(_ prompt: ScheduledPrompt) async {
        if let i = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[i] = prompt
        } else {
            prompts.append(prompt)
        }
        persist()
        await reschedule(prompt)
    }

    func remove(id: String) async {
        prompts.removeAll { $0.id == id }
        persist()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notifId(id)])
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        guard var p = prompts.first(where: { $0.id == id }) else { return }
        p.enabled = enabled
        if let i = prompts.firstIndex(where: { $0.id == id }) {
            prompts[i] = p
        }
        persist()
        if enabled {
            await reschedule(p)
        } else {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [notifId(id)])
        }
    }

    private func notifId(_ promptId: String) -> String {
        "scheduled-prompt-\(promptId)"
    }

    /// (Re)schedule the UNCalendarNotificationTrigger for one prompt.
    private func reschedule(_ prompt: ScheduledPrompt) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notifId(prompt.id)])
        // A fresh schedule supersedes the previous generation entirely —
        // including its delivered copy. That copy shares this identifier,
        // and leaving it in Notification Center makes the next cold start's
        // rescheduleAll mistake it for "this generation already fired" and
        // retire a prompt the user just re-armed (e.g. a .once reminder
        // whose time they edited), even though it has not fired yet.
        center.removeDeliveredNotifications(withIdentifiers: [notifId(prompt.id)])
        guard prompt.enabled else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            logger.warning("notification auth not granted — scheduled prompt \(prompt.id.prefix(6)) will not fire")
            return
        }
        var comps = DateComponents()
        comps.hour = prompt.hour
        comps.minute = prompt.minute
        switch prompt.repeatRule {
        case .daily: comps.weekday = nil   // every day
        case .weekly: comps.weekday = prompt.weekday
        case .once:
            // One-shot: next occurrence of hour:minute (today or tomorrow).
            var cal = Calendar.current
            cal.timeZone = .current
            var fire = cal.date(bySettingHour: prompt.hour, minute: prompt.minute, second: 0, of: Date()) ?? Date()
            if fire <= Date() { fire = cal.date(byAdding: .day, value: 1, to: fire) ?? fire }
            let interval = fire.timeIntervalSinceNow
            if interval <= 0 { return }
            let content = buildContent(prompt)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let req = UNNotificationRequest(identifier: notifId(prompt.id), content: content, trigger: trigger)
            try? await center.add(req)
            logger.info("scheduled once-prompt \(prompt.id.prefix(6)) in \(Int(interval))s")
            return
        }
        let content = buildContent(prompt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let req = UNNotificationRequest(identifier: notifId(prompt.id), content: content, trigger: trigger)
        try? await center.add(req)
        logger.info("scheduled prompt \(prompt.id.prefix(6)) rule=\(prompt.repeatRule.rawValue) \(String(format: "%02d:%02d", prompt.hour, prompt.minute))")
    }

    private func buildContent(_ prompt: ScheduledPrompt) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = prompt.title.isEmpty ? AppLocalized("Scheduled prompt") : prompt.title
        content.body = prompt.prompt.isEmpty
            ? AppLocalized("Tap to wake the agent with this prompt.")
            : prompt.prompt
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = [
            "scheduledPrompt": true,
            "promptId": prompt.id,
            "prompt": prompt.prompt,
            "promptTitle": prompt.title,
            "sessionId": prompt.sessionId ?? "",
        ]
        return content
    }

    /// Re-arm everything on launch (system may have dropped pending requests
    /// across an app update; cheap idempotent call).
    func rescheduleAll() async {
        registerCategory()
        // A .once prompt whose notification already delivered has fired,
        // even if it was never tapped — retire it instead of re-arming it
        // for tomorrow on every cold start. (The tapped path also retires
        // in handleTap; a delivered notification the user swiped away
        // leaves no trace this API can see, so this covers what is
        // detectable.)
        let deliveredIds: Set<String> = await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                cont.resume(returning: Set(delivered.map { $0.request.identifier }))
            }
        }
        var retiredAny = false
        for i in prompts.indices
        where prompts[i].enabled && prompts[i].repeatRule == .once
            && deliveredIds.contains(notifId(prompts[i].id)) {
            prompts[i].enabled = false
            retiredAny = true
            // Retiring must actually disarm. The re-arm loop below skips
            // disabled prompts, so without this the pending request the
            // user scheduled survives — the switch reads off while the
            // notification still fires once at the new time.
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [notifId(prompts[i].id)])
        }
        if retiredAny { persist() }
        for p in prompts where p.enabled {
            await reschedule(p)
        }
    }

    // MARK: Tap handling

    /// Called from the notification delegate for the scheduledPrompt category.
    /// Opens the target session (existing or new draft) and auto-sends the
    /// preset prompt — the AskMinisIntent pipeline shape, minus Siri.
    static func handleTap(promptId: String, promptText: String, sessionId: String?) {
        Task { @MainActor in
            let vm: AIChatViewModel
            if let sid = sessionId, !sid.isEmpty {
                let (cached, _) = ViewModelCache.shared.getOrCreate(for: sid)
                vm = cached
                await vm.loadSession()
            } else {
                vm = ViewModelCache.shared.createDraft()
                vm.sessionSource = "scheduled"
                await vm.ensureSessionReturningId()
            }
            if vm.isProcessing {
                for await processing in vm.$isProcessing.values where !processing { break }
            }
            vm.inputText = promptText
            vm.send()
            if let sid = vm.sessionId, !sid.isEmpty {
                NotificationNavigationStore.shared.setPending(sid)
                NotificationCenter.default.post(
                    name: .openSessionFromIntent,
                    object: nil,
                    userInfo: ["sessionId": sid]
                )
            }
            // Update the binding if this was a new-session fire.
            // `if var` binds the Optional from first(where:) directly; the
            // old code nested a second `if var p = stored` on the ALREADY
            // unwrapped element — conditional binding on a non-Optional.
            if var p = shared.prompts.first(where: { $0.id == promptId }),
               p.sessionId == nil || p.sessionId?.isEmpty == true {
                p.sessionId = vm.sessionId
                await shared.upsert(p)
            }
            // A .once prompt has now fired: retire it. Without a stored
            // terminal state, the upsert above re-arms it for tomorrow and
            // the next cold start's rescheduleAll does the same — "once"
            // quietly became "daily". Disabling persists across both
            // paths: upsert's reschedule removes the pending request and
            // returns early, and rescheduleAll only arms enabled prompts.
            if var p = shared.prompts.first(where: { $0.id == promptId }),
               p.repeatRule == .once, p.enabled {
                p.enabled = false
                await shared.upsert(p)
            }
        }
    }
}
