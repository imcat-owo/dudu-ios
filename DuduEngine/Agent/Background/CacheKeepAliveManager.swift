import Foundation
import os.log

private let logger = AppLogger(category: "CacheKeepAlive")

/// Sends lightweight warmup requests to keep Anthropic's prompt cache alive.
///
/// Anthropic's default cache TTL is 5 minutes. When the user pauses between
/// interactions, the cache expires and the next request re-processes the entire
/// context. This manager sends a `max_tokens:1` warmup request ~4 minutes after
/// the last API call to refresh the TTL. It fires at most 2 times per idle
/// period (total ~13 minutes of idle coverage). Skips when enhanced cache (1h
/// TTL) is enabled or the agent is currently processing. Failed warmups are
/// refunded and retried on the next cycle, but 3 consecutive failures suspend
/// the chain (with a notice to the user) until the next real request resets it.
@MainActor
final class CacheKeepAliveManager {
    static let shared = CacheKeepAliveManager()

    private struct SessionState {
        var lastRequestTime: Date
        var keepAliveCount: Int = 0
        var consecutiveFailures: Int = 0
        var suspended: Bool = false
        var timer: Timer?
        weak var vm: AIChatViewModel?
    }

    private var sessions: [String: SessionState] = [:]
    private let maxKeepAlives = 2
    private let maxConsecutiveFailures = 3
    private let keepAliveDelay: TimeInterval = 4 * 60  // 4 minutes

    private init() {}

    // MARK: - Public API

    /// Called after every Anthropic API call completes to (re)schedule the keep-alive timer.
    func recordRequest(sessionId: String, vm: AIChatViewModel) {
        let previousCount = sessions[sessionId]?.keepAliveCount ?? 0
        let hadTimer = sessions[sessionId]?.timer != nil
        sessions[sessionId]?.timer?.invalidate()

        // Fresh state: this also clears the consecutive-failure count and
        // any suspension, so a real request after the user fixes a bad key
        // resumes keep-alive automatically.
        var state = SessionState(lastRequestTime: Date(), vm: vm)
        state.timer = scheduleTimer(sessionId: sessionId)
        sessions[sessionId] = state

        let fireDate = Date().addingTimeInterval(keepAliveDelay)
        let fireDateStr = ISO8601DateFormatter().string(from: fireDate)
        logger.info("🔥 cache keep-alive: recordRequest session=\(sessionId.prefix(8)) previousKeepAlives=\(previousCount) hadTimer=\(hadTimer) historyCount=\(vm.keepAliveHistory.count) toolCount=\(vm.keepAliveTools.count) nextFire=\(fireDateStr)")
    }

    /// Cancel keep-alive for a session (on teardown / navigation away).
    func cancelKeepAlive(sessionId: String) {
        let hadState = sessions[sessionId] != nil
        let count = sessions[sessionId]?.keepAliveCount ?? 0
        sessions[sessionId]?.timer?.invalidate()
        sessions.removeValue(forKey: sessionId)
        logger.info("🔥 cache keep-alive: cancelled session=\(sessionId.prefix(8)) hadState=\(hadState) keepAlivesUsed=\(count)")
    }

    // MARK: - Timer

    private func scheduleTimer(sessionId: String) -> Timer {
        Timer.scheduledTimer(withTimeInterval: keepAliveDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireKeepAlive(sessionId: sessionId)
            }
        }
    }

    private func fireKeepAlive(sessionId: String) {
        guard var state = sessions[sessionId] else {
            logger.warning("🔥 cache keep-alive: timer fired but no session state for \(sessionId.prefix(8))")
            return
        }

        let elapsed = Date().timeIntervalSince(state.lastRequestTime)
        let elapsedStr = String(format: "%.1fs", elapsed)

        guard state.keepAliveCount < maxKeepAlives else {
            logger.info("🔥 cache keep-alive: max count reached (\(state.keepAliveCount)/\(self.maxKeepAlives)) session=\(sessionId.prefix(8)) elapsed=\(elapsedStr) — no more warmups")
            return
        }
        guard !state.suspended else {
            logger.info("🔥 cache keep-alive: suspended after repeated failures session=\(sessionId.prefix(8)) elapsed=\(elapsedStr) — waiting for next real request")
            return
        }
        guard let vm = state.vm else {
            logger.warning("🔥 cache keep-alive: vm deallocated session=\(sessionId.prefix(8)) elapsed=\(elapsedStr)")
            sessions.removeValue(forKey: sessionId)
            return
        }
        guard !vm.isProcessing else {
            logger.info("🔥 cache keep-alive: skipping (agent processing) session=\(sessionId.prefix(8)) elapsed=\(elapsedStr) — rescheduling")
            state.timer = scheduleTimer(sessionId: sessionId)
            sessions[sessionId] = state
            return
        }
        guard !vm.enhancedCacheEnabled else {
            logger.info("🔥 cache keep-alive: skipping (enhanced cache 1h TTL) session=\(sessionId.prefix(8)) elapsed=\(elapsedStr)")
            return
        }

        state.keepAliveCount += 1
        sessions[sessionId] = state

        logger.info("🔥 cache keep-alive: FIRING warmup #\(state.keepAliveCount)/\(self.maxKeepAlives) session=\(sessionId.prefix(8)) elapsed=\(elapsedStr) historyMsgs=\(vm.keepAliveHistory.count) tools=\(vm.keepAliveTools.count)")

        Task {
            await sendWarmup(sessionId: sessionId, vm: vm)
        }
    }

    // MARK: - Warmup Request

    private func sendWarmup(sessionId: String, vm: AIChatViewModel) async {
        // Identifies the chain this attempt belongs to. If a newer real
        // request replaces the session state mid-flight, this attempt's
        // failure must not count against (or suspend) the new chain —
        // handleFailure checks this.
        let chainLastRequestTime = sessions[sessionId]?.lastRequestTime

        guard let provider = vm.makeAnthropicProviderForWarmup() else {
            logger.warning("🔥 cache keep-alive: failed to create Anthropic provider session=\(sessionId.prefix(8))")
            // A single failed warmup must not end the chain (AE C-5):
            // the attempt is refunded and retried next cycle. Repeated
            // failures suspend the chain with a user-visible notice
            // instead — see handleFailure.
            handleFailure(sessionId: sessionId, vm: vm, chainLastRequestTime: chainLastRequestTime)
            return
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("🔥 cache keep-alive: sending warmup request session=\(sessionId.prefix(8)) model=\(provider.model.id) messages=\(vm.keepAliveHistory.count) tools=\(vm.keepAliveTools.count) systemPromptLen=\(vm.keepAliveSystemPrompt?.count ?? 0)")

        do {
            let usage = try await provider.sendWarmupRequest(
                messages: vm.keepAliveHistory,
                systemPrompt: vm.keepAliveSystemPrompt,
                tools: vm.keepAliveTools
            )

            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            let cacheRead = usage.cacheReadInputTokens ?? 0
            let cacheCreate = usage.cacheCreationInputTokens ?? 0
            let totalInput = usage.inputTokens + cacheRead + cacheCreate
            let cacheHitRate = totalInput > 0 ? Double(cacheRead) / Double(totalInput) * 100 : 0
            let cacheEffective = cacheRead > cacheCreate

            logger.info("🔥 cache keep-alive: warmup DONE session=\(sessionId.prefix(8)) duration=\(durationMs)ms input=\(usage.inputTokens) cache_read=\(cacheRead) cache_create=\(cacheCreate) output=\(usage.outputTokens) hit_rate=\(String(format: "%.1f", cacheHitRate))% effective=\(cacheEffective)")

            if !cacheEffective {
                logger.warning("🔥 cache keep-alive: LOW cache hit — cache_create(\(cacheCreate)) >= cache_read(\(cacheRead)). The prefix may have changed or cache already expired.")
            }

            // The success path needs the same chain check handleFailure
            // already does: while this warmup was in flight, a newer real
            // request may have replaced the session state (recordRequest
            // installs a fresh state with a new timer). A late success from
            // the OLD chain must not clear the new chain's failure count
            // nor invalidate/reschedule its timer — rescheduling from the
            // stale completion time can push the new chain's next warmup
            // past the cache TTL.
            guard sessions[sessionId]?.lastRequestTime == chainLastRequestTime else {
                logger.info("🔥 cache keep-alive: warmup succeeded for a superseded chain — leaving the current chain's state untouched session=\(sessionId.prefix(8))")
                return
            }

            // A successful warmup clears the consecutive-failure count.
            if var state = sessions[sessionId], state.consecutiveFailures != 0 {
                state.consecutiveFailures = 0
                sessions[sessionId] = state
            }

            // Reschedule if we haven't hit the max
            if var state = sessions[sessionId], state.keepAliveCount < maxKeepAlives {
                state.timer?.invalidate()
                let nextFireDate = Date().addingTimeInterval(keepAliveDelay)
                let nextFireStr = ISO8601DateFormatter().string(from: nextFireDate)
                state.timer = scheduleTimer(sessionId: sessionId)
                sessions[sessionId] = state
                logger.info("🔥 cache keep-alive: rescheduled warmup #\(state.keepAliveCount + 1)/\(self.maxKeepAlives) session=\(sessionId.prefix(8)) nextFire=\(nextFireStr)")
            } else {
                let count = sessions[sessionId]?.keepAliveCount ?? 0
                logger.info("🔥 cache keep-alive: NOT rescheduling session=\(sessionId.prefix(8)) keepAliveCount=\(count)/\(self.maxKeepAlives)")
            }
        } catch {
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            logger.error("🔥 cache keep-alive: warmup FAILED session=\(sessionId.prefix(8)) duration=\(durationMs)ms error=\(error.localizedDescription)")
            // Same failure path as the provider-failure branch above:
            // refund + retry next cycle, suspending with a notice after
            // repeated failures — see handleFailure.
            handleFailure(sessionId: sessionId, vm: vm, chainLastRequestTime: chainLastRequestTime)
        }
    }

    /// Central failure path for both warmup failure branches. The attempt
    /// is refunded (AE C-5) and the next cycle rescheduled — but only below
    /// the consecutive-failure cap: after `maxConsecutiveFailures` failures
    /// in a row the chain is suspended instead, so a persistent failure
    /// (e.g. an invalidated API key) cannot retry every 4 minutes for the
    /// rest of the idle period. A failure whose chain has already been
    /// replaced by a newer real request is ignored.
    private func handleFailure(sessionId: String, vm: AIChatViewModel, chainLastRequestTime: Date?) {
        guard var state = sessions[sessionId],
              state.lastRequestTime == chainLastRequestTime else { return }
        state.keepAliveCount = max(0, state.keepAliveCount - 1)
        state.consecutiveFailures += 1
        sessions[sessionId] = state

        if state.consecutiveFailures >= maxConsecutiveFailures {
            suspendAfterRepeatedFailures(sessionId: sessionId, vm: vm)
        } else {
            rescheduleAfterFailure(sessionId: sessionId)
        }
    }

    /// Stop the keep-alive chain until the next real request (recordRequest
    /// installs a fresh state, clearing the suspension) and surface why
    /// through the session's existing transient notice — never silently.
    private func suspendAfterRepeatedFailures(sessionId: String, vm: AIChatViewModel) {
        guard var state = sessions[sessionId], !state.suspended else { return }
        state.suspended = true
        state.timer?.invalidate()
        state.timer = nil
        sessions[sessionId] = state
        logger.warning("🔥 cache keep-alive: SUSPENDED after \(self.maxConsecutiveFailures) consecutive failures session=\(sessionId.prefix(8)) — resumes on next real request")
        vm.transientNotice = AppLocalized("Cache keep-alive paused: \(maxConsecutiveFailures) warmup requests failed in a row — your API key may be invalid. Fix the key and send any message to resume.")
    }

    /// Reschedule the next warmup after a failed attempt, mirroring the
    /// success branch's reschedule. The count was already refunded by the
    /// caller; the cap is re-checked here and again at fire time. Only
    /// called below the consecutive-failure cap — at the cap the caller
    /// suspends the chain instead (see handleFailure).
    private func rescheduleAfterFailure(sessionId: String) {
        guard var state = sessions[sessionId], state.keepAliveCount < maxKeepAlives else {
            let count = sessions[sessionId]?.keepAliveCount ?? 0
            logger.info("🔥 cache keep-alive: NOT rescheduling after failure session=\(sessionId.prefix(8)) keepAliveCount=\(count)/\(self.maxKeepAlives)")
            return
        }
        state.timer?.invalidate()
        let nextFireDate = Date().addingTimeInterval(keepAliveDelay)
        let nextFireStr = ISO8601DateFormatter().string(from: nextFireDate)
        state.timer = scheduleTimer(sessionId: sessionId)
        sessions[sessionId] = state
        logger.info("🔥 cache keep-alive: rescheduled after failure session=\(sessionId.prefix(8)) nextAttempt=\(state.keepAliveCount + 1)/\(self.maxKeepAlives) nextFire=\(nextFireStr)")
    }
}
