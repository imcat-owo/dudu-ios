import AppIntents
import Foundation

/// Retries (re-runs) from a specific user message in a session.
/// At runtime, shows a picker of user messages from the selected session,
/// then deletes all messages after the chosen one and re-runs the agent.
@available(iOS 17.0, *)
struct RetryRunIntent: AppIntent {
    static var title: LocalizedStringResource = "Retry Run"
    static var description = IntentDescription("Re-runs the AI agent from a specific user message in a session. Presents a list of user messages to choose from, then retries from that point.")
    static var openAppWhenRun = false

    @Parameter(title: "Session")
    var session: SessionEntity

    @Parameter(title: "Message")
    var message: UserMessageEntity?

    @Parameter(title: "Attachments", description: "Images, videos, or files to replace existing attachments. Accepts output from previous Shortcuts actions. If empty, keeps original attachments.",
               supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"],
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]?

    @Parameter(title: "Wait for Result", description: "When enabled, waits for the AI to finish and returns the full response for use in subsequent actions.", default: false)
    var waitForResult: Bool

    @Parameter(title: "Send Notifications", description: "When enabled, posts a system notification when the task starts and again when it finishes. Turn this off for automations that run silently. The app's global task-notification setting still applies.", default: true)
    var sendCompletionNotification: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SendPromptResult> & ProvidesDialog {
        BackgroundKeepAliveManager.shared.setup()

        // [T-shortcuts-eager-keepalive] Arm keep-alive BEFORE any await so
        // iOS doesn't suspend the AppIntent-woken process before the normal
        // setActive path (buried behind vm.send() → currentTask → await
        // ensureSession()) has a chance to fire. No-op unless the user has
        // enhancedBackgroundEffective on.
        let eagerResult = BackgroundKeepAliveManager.shared.armEagerlyForShortcut(
            sessionId: session.id, caller: "RetryRunIntent")
        // [T-shortcuts-diag-and-pending] Snapshot state and mark pending; the
        // completion path clears it.
        ShortcutRunTracker.logPerformEntry(
            intent: "RetryRunIntent",
            sessionId: session.id,
            eagerKeepAliveArmed: eagerResult.armed,
            eagerKeepAliveSkippedReason: eagerResult.skipReason
        )
        let pendingId = ShortcutRunTracker.markPending(
            intent: "RetryRunIntent",
            sessionId: session.id,
            eagerKeepAliveArmed: eagerResult.armed,
            eagerKeepAliveSkippedReason: eagerResult.skipReason
        )
        // Every exit from here must resolve the pending record and the
        // eager activity entry. The paths below that complete (or hand the
        // pending record to the async completion Task) do their own
        // cleanup and set pendingHandedOff; any OTHER exit — above all the
        // user cancelling the message picker, whose requestDisambiguation
        // throws — falls to this defer. Without it, a cancelled retry left
        // the pending record for the next launch to report as "Automation
        // may not have completed", plus a phantom running entry in the
        // activity tracker for the rest of the process's life.
        var pendingHandedOff = false
        defer {
            if !pendingHandedOff {
                ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "throwOrCancel.cleanup")
                if eagerResult.armed {
                    SessionActivityTracker.shared.setInactive(session.id,
                        source: "RetryRunIntent.eager.throwCleanup")
                }
            }
        }

        let (vm, isNew) = ViewModelCache.shared.getOrCreate(for: session.id)
        // [T-shortcut-duplicate-completion-notification] See SendPromptIntent.
        // Note this deliberately does NOT set `sessionSource = "shortcut"`: this
        // session may have been created by hand in the app, and that tag also
        // drives near-capacity auto-compaction.
        vm.suppressGeneralCompletionNotification = true
        if isNew {
            await vm.loadSession()
        }

        // Wait if session is currently processing
        if vm.isProcessing {
            for await processing in vm.$isProcessing.values {
                if !processing { break }
            }
        }

        // Find user messages
        let userMessages = vm.messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else {
            // [T-shortcuts-diag-and-pending] Early-return before any agent
            // work — clear the pending marker so the next foreground scan
            // doesn't flag this as orphaned.
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "earlyReturn.noUserMessages")
            pendingHandedOff = true
            // [T-ios-session-status-mismatch] The eager setActive above added
            // this session id to the tracker before we knew we'd bail. The VM
            // sink pairs setActive/setInactive on $isProcessing transitions,
            // but we're returning without ever flipping isProcessing → the
            // sink never fires setInactive and the tracker leaks a phantom
            // "running" session (home spinner stuck, chat.session.status
            // false-positive). Drop it here.
            if eagerResult.armed {
                SessionActivityTracker.shared.setInactive(session.id,
                    source: "RetryRunIntent.eager.earlyReturnNoUserMessages")
            }
            return .result(
                value: SendPromptResult(sessionId: session.id, modelName: "N/A", status: "Error", isNewSession: false),
                dialog: IntentDialog(stringLiteral: AppLocalized("No user messages found in this session."))
            )
        }

        // Build entity list from this session's user messages
        let sessionTitle = session.displayName
        let entities = userMessages.enumerated().map { idx, msg -> UserMessageEntity in
            let text = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = text.isEmpty ? "(attachment)" : String(text.prefix(80))
            return UserMessageEntity(
                id: "\(session.id):\(idx)",
                sessionId: session.id,
                preview: preview,
                index: idx + 1,
                sessionTitle: sessionTitle
            )
        }

        // Resolve which message to retry from
        let chosenEntity: UserMessageEntity
        if let provided = message {
            chosenEntity = provided
        } else if entities.count == 1 {
            chosenEntity = entities[0]
        } else {
            // Runtime disambiguation — shows the correct session's messages
            chosenEntity = try await $message.requestDisambiguation(
                among: entities,
                dialog: IntentDialog("Which message do you want to retry from?")
            )
        }

        // [R3-035] Validate the chosen entity against THIS session before
        // trusting its positional index. A saved shortcut holds the entity
        // independently of the Session parameter — the user can pick a
        // message, then change the session (or messages get deleted and
        // indices shift). retryFromMessage deletes everything after the
        // chosen message, so applying a foreign/stale index here silently
        // truncated the current session at the wrong point; the old
        // out-of-range path even fell back to the LAST message instead of
        // complaining. Entities from the disambiguation above are built
        // from this session, so they pass by construction.
        guard chosenEntity.sessionId == session.id,
              chosenEntity.index >= 1, chosenEntity.index <= userMessages.count else {
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "earlyReturn.messageSessionMismatch")
            pendingHandedOff = true
            if eagerResult.armed {
                SessionActivityTracker.shared.setInactive(session.id,
                    source: "RetryRunIntent.eager.messageSessionMismatch")
            }
            return .result(
                value: SendPromptResult(sessionId: session.id, modelName: "N/A", status: "Error", isNewSession: false),
                dialog: IntentDialog(stringLiteral: AppLocalized("The selected message doesn't belong to this session."))
            )
        }

        // Map entity index back to ChatMessage
        let targetMessage = userMessages[chosenEntity.index - 1]

        let promptPreview = String(targetMessage.content.prefix(50))

        // Convert intent files to InputAttachments for replacement (if provided)
        var replacementAttachments: [InputAttachment]? = nil
        if let intentFiles = files, !intentFiles.isEmpty {
            // Stage files via the VM's cache, then detach them for retryFromMessage
            let countBefore = vm.attachments.count
            for file in intentFiles {
                let name = SendPromptIntent.resolvedFileName(for: file)
                vm.addDataAttachment(data: file.data, fileName: name)
            }
            replacementAttachments = Array(vm.attachments.dropFirst(countBefore))
            vm.attachments.removeSubrange(countBefore...)
        }

        // Retry from that message (replacement attachments override the original ones)
        vm.retryFromMessage(targetMessage.id, replacementAttachments: replacementAttachments)

        let sid = vm.sessionId ?? session.id

        // Resolve model name
        var modelName = vm.selectedModel.displayName
        let store = ProviderConfigStore.shared
        if let binding = store.binding(for: sid) {
            switch binding.primarySource {
            case .group(_, let resolvedEntryId):
                if let entry = store.entry(for: resolvedEntryId) {
                    modelName = entry.model.displayName
                }
            case .directEntry(let modelEntryId, _):
                if let entry = store.entry(for: modelEntryId) {
                    modelName = entry.model.displayName
                }
            }
        }

        // Notification: retry started. See the note in SendPromptIntent.
        if sendCompletionNotification {
            ShortcutNotification.post(
                id: "shortcut-retry-\(sid)",
                title: AppLocalized("我的小家: Retrying"),
                body: "\(modelName): \(promptPreview)\(targetMessage.content.count > 50 ? "…" : "")",
                sessionId: sid
            )
        }

        if waitForResult {
            for await processing in vm.$isProcessing.values {
                if !processing { break }
            }

            // [T-shortcuts-diag-and-pending] Loop finished.
            ShortcutRunTracker.markCompleted(recordId: pendingId, reason: "waitForResult.done")
            pendingHandedOff = true

            let responseText = SendPromptIntent.extractResponseText(from: vm)

            // Per-run opt-out. ANDs with the app-wide toggle, which
            // ShortcutNotification.post checks internally — do not duplicate it here.
            if sendCompletionNotification {
                ShortcutNotification.post(
                    id: "shortcut-retry-done-\(sid)",
                    title: AppLocalized("我的小家: Retry Done"),
                    body: "\(modelName): \(String(responseText.prefix(200)))",
                    sessionId: sid
                )
            }

            let result = SendPromptResult(
                sessionId: sid,
                modelName: modelName,
                status: "Completed",
                isNewSession: false,
                prompt: targetMessage.content,
                responseText: responseText
            )
            return .result(value: result, dialog: "\(responseText.prefix(500))")
        }

        // Async mode
        let capturedModelName = modelName
        let capturedSid = sid
        let capturedPendingId = pendingId
        let capturedSendCompletionNotification = sendCompletionNotification
        Task { @MainActor in
            for await processing in vm.$isProcessing.values {
                if !processing { break }
            }

            // [T-shortcuts-diag-and-pending] Loop finished.
            ShortcutRunTracker.markCompleted(recordId: capturedPendingId, reason: "async.done")

            let summary = String(SendPromptIntent.extractResponseText(from: vm).prefix(200))

            if capturedSendCompletionNotification {
                ShortcutNotification.post(
                    id: "shortcut-retry-done-\(capturedSid)",
                    title: AppLocalized("我的小家: Retry Done"),
                    body: "\(capturedModelName): \(summary)",
                    sessionId: capturedSid
                )
            }
        }
        // The pending record now belongs to the Task above.
        pendingHandedOff = true

        let result = SendPromptResult(
            sessionId: sid,
            modelName: modelName,
            status: "Retrying",
            isNewSession: false,
            prompt: targetMessage.content
        )

        // Build the elided preview BEFORE interpolating so the localization key
        // has exactly one placeholder. Inlining the ternary would bake a second
        // one into the key and make it fragile to translate.
        let elidedPreview = promptPreview + (targetMessage.content.count > 50 ? "…" : "")
        return .result(value: result, dialog: IntentDialog(stringLiteral: AppLocalized("Retrying from message: \(elidedPreview)")))
    }

    static var parameterSummary: some ParameterSummary {
        // The summary had no trailing closure, so it declared no "Show More"
        // section and NEITHER `waitForResult` nor `sendCompletionNotification`
        // was reachable on the action card. Both are optional refinements, so
        // they belong there rather than on the Summary line.
        Summary("Retry \(\.$session) from \(\.$message)") {
            \.$files
            \.$waitForResult
            \.$sendCompletionNotification
        }
    }
}
