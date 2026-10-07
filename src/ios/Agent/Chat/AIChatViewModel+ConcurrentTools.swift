//
//  AIChatViewModel+ConcurrentTools.swift
//  MinisApp
//
//  Concurrent tool execution: dispatches up to `maxConcurrentTools` tool
//  calls in parallel via TaskGroup, waits for all to complete, then
//  returns results ordered to match the original tool_use sequence
//  (Anthropic API requires tool_result order to mirror tool_use order
//  within the same user message).
//
//  Created for T-concurrent-tools 2026-05-25.
//

import Foundation
import UIKit

private let ctLogger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {

    /// Hard cap on simultaneous in-flight tool executions per agent turn.
    /// 10 is the requested ceiling; iSH itself can fan out further but
    /// concurrent shell forks on the emulator past this start to compete
    /// for emulator scheduling.
    static let maxConcurrentTools = 10

    /// Set-typed view of currently-running shell PIDs.
    ///
    /// Backed by the singular `runningCommandPid: Int32` slot on
    /// AIChatViewModel so `AIChatViewModel+ISHCommand`'s pidCallback
    /// (which assigns `runningCommandPid = pid`) keeps working
    /// unchanged. The stop button enumerates this Set to kill every
    /// in-flight shell across a concurrent batch. When per-task PID
    /// tracking lands this can be promoted to true Set storage with
    /// per-task insert/remove.
    ///
    /// [T-ios-concurrent-toolcall-dup-id]
    var runningCommandPids: Set<Int32> {
        get { runningCommandPid > 0 ? [runningCommandPid] : [] }
        set { runningCommandPid = newValue.first ?? 0 }
    }

    /// Tiny actor wrapping the per-turn image budget so concurrent tool
    /// tasks can race-free claim a slot for their image bytes.
    /// `reserveSlot()` returns true iff a slot was claimed; the caller
    /// then attaches `imageData` to its toolResult. False → caller must
    /// substitute a text placeholder.
    actor BatchImageBudget {
        private var remaining: Int
        private(set) var strippedCount: Int = 0

        init(initial: Int) { self.remaining = max(0, initial) }

        /// Claim one image slot. Returns true if granted.
        func reserveSlot() -> Bool {
            if remaining > 0 {
                remaining -= 1
                return true
            }
            strippedCount += 1
            return false
        }

        var strippedSoFar: Int { strippedCount }
    }

    /// Per-batch claim registry for shell file-change attribution.
    ///
    /// Shell tasks in one TaskGroup batch run truly concurrently — the
    /// coordinator forks an independent /bin/sh per call (see
    /// ISHExecutionCoordinator), so a sibling's writes land inside this
    /// task's [preSnapshot, postSnapshot] window and would otherwise be
    /// reported as this task's own products by every task whose window
    /// covers the write. Each shell task claims its changed paths here
    /// before reporting: the first task to claim a path keeps it, later
    /// siblings skip it, so a path is attributed (and registered in the
    /// fakefs metadata) exactly once per batch. [AE C-4]
    actor BatchFileClaimRegistry {
        private var claimedPaths: Set<String> = []

        /// Atomically claim the subset of `paths` no sibling in this
        /// batch has claimed yet. Returns the paths this caller owns.
        func claim(_ paths: [String]) -> [String] {
            let fresh = paths.filter { !claimedPaths.contains($0) }
            claimedPaths.formUnion(fresh)
            return fresh
        }
    }

    /// Outcome of executing a single tool call. Collected by each child
    /// task and merged in original index order by the outer dispatcher.
    struct ToolExecOutcome {
        let toolId: String
        let toolName: String
        let resultPart: AgentContentPart            // .toolResult(...)
        let snapshotEntry: (toolName: String, snapshot: ToolSnapshot)?
        let snapshotItem: ToolSnapshotItem?
        let cancelled: Bool
    }

    /// Execute a single tool use, returning a self-contained outcome.
    /// All mutations to `messages[msgIdx].blocks[blockIdx]` happen inside
    /// (the VM is @MainActor so this is safe even when invoked from
    /// concurrent child tasks). The outcome carries the toolResult part,
    /// snapshot, and cancellation flag so the dispatcher can collect them
    /// in original tool_use order after every child task completes.
    func executeSingleToolUse(
        tu: StreamResult.ToolEntry,
        msgIdx: Int,
        tools: [AgentToolDefinition],
        batchBudget: BatchImageBudget,
        batchFileClaims: BatchFileClaimRegistry,
        deferredAssistantRaw: RawMessage?
    ) async -> ToolExecOutcome {
        let blockIdx = tu.blockIdx

        // Graceful cancel pre-check: any task that begins after the user
        // tapped Stop short-circuits with a synthetic cancellation result
        // so history stays paired.
        if Task.isCancelled || self.userDidCancel {
            let cancelContent = "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>"
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].toolStatus = .cancelled
                messages[msgIdx].blocks[blockIdx].content = cancelContent
            }
            let cancelSnap = ToolSnapshot(type: .text, text: cancelContent, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: cancelSnap,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: cancelContent, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: cancelSnap),
                snapshotItem: item,
                cancelled: true
            )
        }

        var toolOutput: String = ""
        var toolSuccess: Bool = false
        var toolImageData: Data?
        var toolImageMimeType: String?
        var toolImageLinuxPath: String?
        var toolPageURL: String?
        var cancelledHere = false

        // Loop-detector pre-check: short-circuit when the model is stuck
        // in a runaway pattern (unknown tool spam, no-progress polling, etc).
        let loopPreCheck = toolLoopDetector.check(toolName: tu.name, params: tu.args)
        if loopPreCheck.level == .critical, let blockedMsg = loopPreCheck.message {
            toolOutput = blockedMsg
            toolSuccess = false
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = blockedMsg
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: "loop blocked")
            }
            toolLoopDetector.record(
                toolName: tu.name, params: tu.args,
                result: nil, errorMessage: blockedMsg, toolCallId: tu.id
            )
            let blockedSnap = ToolSnapshot(type: .text, text: blockedMsg, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: blockedSnap,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: blockedMsg, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: blockedSnap),
                snapshotItem: item,
                cancelled: false
            )
        }

        // JSON Repair (T-tool-json-repair b2c4f8a6).
        var toolArgs: [String: Any] = tu.args
        let needsRepair: Bool = {
            guard let toolDef = tools.first(where: { $0.name == tu.name }) else { return false }
            if tu.args.isEmpty && !toolDef.required.isEmpty { return true }
            for field in toolDef.required {
                guard let raw = tu.args[field] else { return true }
                if raw is NSNull { return true }
                if let s = raw as? String,
                   s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !(raw is String) && !(raw is [Any]) && !(raw is [String: Any]) { return true }
            }
            return false
        }()
        // [T-truncated-args-visibility #119] Tracks whether THIS call's
        // arguments arrived truncated and were glued shut by the repair pass.
        // Non-nil ⇒ the args are not what the model actually emitted.
        var truncationRepairTag: String? = nil
        if needsRepair {
            let rawJoined = tu.inputChunkRing.joined()
            let repairOutcome = Self.repairToolArgs(
                name: tu.name, args: tu.args, rawTail: rawJoined, tools: tools
            )
            if !repairOutcome.repairs.isEmpty {
                AppLogger(category: "ToolPreflight").warning(
                    "[ToolRepair] REPAIRED tool=\(tu.name) id=\(tu.id) strategies=[\(repairOutcome.repairs.joined(separator: ", "))] beforeKeys=[\(tu.args.keys.sorted().joined(separator: ","))] afterKeys=[\(repairOutcome.args.keys.sorted().joined(separator: ","))] rawJoined=<<<\(rawJoined.prefix(500))>>>"
                )
                toolArgs = repairOutcome.args
                // Only the truncation strategy means "the value itself was cut
                // short". Type-coercion and fuzzy-name repairs fix the SHAPE of
                // a fully-received argument and are not a data-loss signal.
                truncationRepairTag = repairOutcome.repairs.first { $0.hasPrefix("truncation+") }
            }
        }

        // [T-truncated-args-visibility #119] Refuse to execute a WRITE whose
        // argument stream was truncated.
        //
        // The repair pass closes an unterminated JSON string by appending `"}`,
        // which for file_write is indistinguishable from the model having ended
        // `content` right there: the JSON parses, every required field is
        // present, preflight passes, and a HALF file lands on disk while both
        // the UI and the model's tool result report plain success. The user
        // finds a truncated file later; the model, seeing "success", keeps
        // building on it.
        //
        // For writes a partial artifact is strictly worse than none — it is
        // silent corruption of the user's data, and unlike a blocked call it
        // cannot be recovered by simply retrying. Read-only and shell tools
        // keep the existing repair-and-run behaviour: there the repaired call
        // is at worst a wasted round-trip, and refusing them would regress
        // recoveries that work today.
        if let tag = truncationRepairTag,
           tu.name == "file_write" || tu.name == "file_edit" {
            let path = (toolArgs["path"] as? String) ?? (toolArgs["file_path"] as? String) ?? ""
            AppLogger(category: "ToolPreflight").warning(
                "[ToolRepair] REFUSED truncated write tool=\(tu.name) id=\(tu.id) strategy=\(tag) path=\(path)"
            )
            let uiMessage = AppLocalized("Blocked: arguments were truncated in transit")
            let modelMessage = """
            Error: This call was NOT executed. Its argument stream was truncated in transit \
            (repair strategy: \(tag)), so the `content` your client sent was cut short and would \
            have written an incomplete file\(path.isEmpty ? "" : " to \(path)"). Nothing was \
            written to disk — the target file is unchanged.

            The most likely cause is the response hitting its output-token limit mid-argument. \
            Re-issue this write in smaller pieces: write the first part, then append the rest \
            with follow-up calls, rather than repeating the same oversized call.
            """
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = uiMessage
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: uiMessage)
            }
            toolLoopDetector.record(
                toolName: tu.name, params: tu.args,
                result: nil, errorMessage: modelMessage, toolCallId: tu.id
            )
            let refusedSnap = ToolSnapshot(type: .text, text: modelMessage, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: refusedSnap,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: modelMessage, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: refusedSnap),
                snapshotItem: item,
                cancelled: false
            )
        }

        // Preflight: reject empty / missing-required-field tool calls.
        if let preflightError = Self.preflightValidateToolCall(name: tu.name, args: toolArgs, tools: tools) {
            let chunkRing = tu.inputChunkRing
            AppLogger(category: "ToolPreflight").warning(
                "[ToolPreflight] BLOCKED tool=\(tu.name) id=\(tu.id) reason=\"\(preflightError)\" argsKeys=[\(tu.args.keys.sorted().joined(separator: ","))] chunkCount=\(chunkRing.count) lastChunk=<<<\(chunkRing.last?.prefix(500) ?? "")>>>"
            )
            let uiMessage = AppLocalized("Blocked invalid tool call")
            let modelMessage = "Error: Tool call rejected before execution. \(preflightError) The arguments your client sent were empty or missing required fields — re-issue the call with all required parameters filled in. Do not retry with the same empty arguments."
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = uiMessage
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: uiMessage)
            }
            toolLoopDetector.record(
                toolName: tu.name, params: tu.args,
                result: nil, errorMessage: modelMessage, toolCallId: tu.id
            )
            let blockedSnap = ToolSnapshot(type: .text, text: modelMessage, mediaRef: nil, duration: nil)
            let item = ToolSnapshotItem(
                id: tu.id, toolName: tu.name, snapshot: blockedSnap,
                mediaResolver: await ChatStore.shared.mediaFileURLResolver()
            )
            return ToolExecOutcome(
                toolId: tu.id, toolName: tu.name,
                resultPart: .toolResult(id: tu.id, name: tu.name, content: modelMessage, isError: true),
                snapshotEntry: (toolName: tu.name, snapshot: blockedSnap),
                snapshotItem: item,
                cancelled: false
            )
        }

        let argsJson: String = {
            if let data = try? JSONSerialization.data(withJSONObject: toolArgs),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{}"
        }()

        do {
        switch tu.name {
        case "shell_execute":
            let (command, timeout, delay) = parseToolInput(from: argsJson)

            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ctLogger.warning("[ToolArgsProbe] shell_execute called with empty command — argsJson=<<<\(argsJson)>>>")
                toolOutput = "Error: Missing required 'command' parameter. Please call shell_execute again with a non-empty `command` field."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }

            // [s2-approve] 高风险工具审批关卡：MCP 逐工具审批 / 日历提醒写动作强制审批 /
            // 工作区命令总开关。被拦下则直接回 AI，不执行。
            let gateOutcome = await ToolApprovalGate.checkShellCommand(command, sessionId: self.sessionId)
            if case .blocked(let gateMessage) = gateOutcome {
                ctLogger.info("[ToolApproval] BLOCKED shell command")
                toolOutput = gateMessage
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = gateMessage
                }
                break
            }

            // Offload permission check.
            ctLogger.info("[OffloadPerm] shell command: \(command)")
            if let offloadCmd = OffloadPermissionManager.extractOffloadCommand(from: command) {
                // [s2-approve] 日历/提醒的写动作已由上面的强制审批问过，
                // 这里跳过，避免同一个动作弹两次窗。
                let writeAlreadyAsked = (offloadCmd == "apple-calendar" || offloadCmd == "apple-reminders")
                    && ToolApprovalGate.writeSubcommand(command: offloadCmd, fullCommand: command).isWrite
                if !writeAlreadyAsked {
                    ctLogger.info("[OffloadPerm] matched offload: \(offloadCmd), level: \(OffloadPermissionManager.shared.permissionLevel(for: offloadCmd).rawValue)")
                    let permResult = await OffloadPermissionManager.shared.checkPermission(
                        for: offloadCmd, sessionId: self.sessionId, fullCommand: command
                    )
                    if case .denied(let msg) = permResult {
                        ctLogger.info("[OffloadPerm] DENIED: \(offloadCmd)")
                        toolOutput = msg
                        toolSuccess = false
                        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                            messages[msgIdx].blocks[blockIdx].content = msg
                        }
                        break
                    }
                    ctLogger.info("[OffloadPerm] ALLOWED: \(offloadCmd)")
                }
            } else {
                ctLogger.info("[OffloadPerm] no offload match for first token")
            }

            // Delay execution.
            if delay > 0 {
                toolDelayWaitCount += 1
                defer { toolDelayWaitCount -= 1 }
                // [T-delay-stop-latency] The stop button during the countdown
                // sets `commandCancelledByUser` (stopCurrentCommand guards on
                // `toolDelayWaitActive`), but the old loop only re-checked that
                // flag once per whole second and then slept a FULL second — a
                // tap landing just after a check waited up to ~1s before the
                // next check, which read as "stop does nothing" during the
                // delay phase (the user report). Poll on a short tick instead so
                // both the button flag AND Task cancellation are honored within
                // ~100ms, while the visible countdown still refreshes once per
                // whole second.
                let totalSeconds = Int(delay)
                let tickNanos: UInt64 = 100_000_000 // 100ms
                let ticksPerSecond = 10
                var lastShownRemaining = -1
                for tick in 0..<(totalSeconds * ticksPerSecond) {
                    if commandCancelledByUser || Task.isCancelled {
                        throw CancellationError()
                    }
                    let remaining = totalSeconds - (tick / ticksPerSecond)
                    if remaining != lastShownRemaining,
                       msgIdx < self.messages.count, blockIdx < self.messages[msgIdx].blocks.count {
                        lastShownRemaining = remaining
                        let mm = remaining / 60
                        let ss = remaining % 60
                        let countdown = mm > 0 ? String(format: "%d:%02d", mm, ss) : "\(ss)s"
                        self.messages[msgIdx].blocks[blockIdx].content = "⏳ Waiting \(countdown) before executing..."
                        self.scrollToBottomSignal.send()
                    }
                    try await Task.sleep(nanoseconds: tickNanos)
                }
                // Final cancellation check after the last tick so a tap in the
                // final 100ms window still aborts before we launch the process.
                if commandCancelledByUser || Task.isCancelled {
                    throw CancellationError()
                }
            }

            let preSnapshot = snapshotMinisFiles()
            let result: CommandResult
            do {
                var lineBuffer: [String] = []
                var lastFlush = Date.distantPast
                let kMaxStreamingDisplayChars = 30_000
                let flushLines: () -> Void = { [weak self] in
                    guard let self, !lineBuffer.isEmpty else { return }
                    let joined = lineBuffer.joined(separator: "\n")
                    lineBuffer.removeAll()
                    lastFlush = Date()
                    if msgIdx < self.messages.count && blockIdx < self.messages[msgIdx].blocks.count {
                        let current = self.messages[msgIdx].blocks[blockIdx].content
                        var newContent: String
                        if current.hasSuffix("Executing...") {
                            newContent = joined
                        } else {
                            newContent = current + "\n" + joined
                        }
                        if newContent.count > kMaxStreamingDisplayChars {
                            newContent = "…[output truncated]…\n" + String(newContent.suffix(kMaxStreamingDisplayChars))
                        }
                        self.messages[msgIdx].blocks[blockIdx].content = newContent
                        self.scrollToBottomSignal.send()
                    }
                }
                // [T-tool-exec-breadcrumb] Durable, written BEFORE the command
                // launches. `[ToolLifecycle] COMPLETED` only lands after a tool
                // returns, so a process killed mid-execution (watchdog SIGKILL,
                // Jetsam, SIGABRT) left no record of what was running. This line
                // is on disk (O_SYNC) before executeCommand is entered, so the
                // last breadcrumb after a kill names the command that was live.
                // Command is truncated — enough to identify it, not enough to
                // bloat the file with a large heredoc.
                #if DEBUG
                CrashReporter.writeToolBreadcrumb(
                    "[ToolExec] STARTING shell_execute id=\(tu.id.prefix(20)) sid=\(sessionId?.prefix(8) ?? "nil") timeout=\(timeout)s command=\"\(command.prefix(500))\""
                )
                #endif
                result = try await executeCommand(command, timeout: timeout) { [weak self] line in
                    guard let self else { return }
                    let (cleanedLine, capturedURLs) = MinisURLMarker.extract(from: line)
                    if !capturedURLs.isEmpty {
                        Task { @MainActor in
                            for raw in capturedURLs {
                                if let u = URL(string: raw),
                                   MinisOpenURLBroker.isSupportedScheme(u.scheme) {
                                    MinisOpenURLBroker.shared.offer(u)
                                }
                            }
                        }
                    }
                    if cleanedLine.isEmpty && !line.isEmpty { return }
                    lineBuffer.append(cleanedLine)
                    if Date().timeIntervalSince(lastFlush) >= 0.2 {
                        flushLines()
                    }
                }
                flushLines()
            } catch {
                result = CommandResult(output: "Error: \(error.localizedDescription)", exitCode: -1)
            }
            // [T-tool-exec-breadcrumb] Pair for the STARTING line above. The
            // existing `[ToolLifecycle] COMPLETED` covers every tool, but it
            // travels the droppable NSLog pipe; this one shares the STARTING
            // line's durable file so a STARTING with no matching FINISHED is
            // unambiguous evidence that the process died inside this command.
            #if DEBUG
            CrashReporter.writeToolBreadcrumb(
                "[ToolExec] FINISHED shell_execute id=\(tu.id.prefix(20)) exit=\(result.exitCode)"
            )
            #endif
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                let existingContent = messages[msgIdx].blocks[blockIdx].content
                let hasStreamedContent = !existingContent.isEmpty
                    && !existingContent.hasSuffix("Executing...")
                if !hasStreamedContent {
                    let (cleaned, capturedURLs) = MinisURLMarker.extract(from: result.output)
                    for raw in capturedURLs {
                        if let u = URL(string: raw),
                           MinisOpenURLBroker.isSupportedScheme(u.scheme) {
                            MinisOpenURLBroker.shared.offer(u)
                        }
                    }
                    let resultTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !resultTrimmed.isEmpty {
                        messages[msgIdx].blocks[blockIdx].content = resultTrimmed
                    }
                }
            }
            if commandCancelledByUser {
                // NOTE: don't reset commandCancelledByUser here under
                // concurrent execution — sibling shell tasks still need
                // the signal to abort their own delay loops. The outer
                // dispatcher resets it once per batch.
                toolOutput = "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>\n" + result.output
                cancelledHere = true
            } else {
                toolOutput = result.output
            }
            toolSuccess = result.exitCode == 0

            // Scan for new/modified files under /var/minis/
            let postSnapshot = snapshotMinisFiles()
            // [AE C-4] Sibling shell tasks in this batch execute truly
            // concurrently (one forked /bin/sh each), so their writes
            // land inside this task's [pre, post] snapshot window. Claim
            // the changed paths against the per-batch registry first:
            // each path is reported — and registered in the fakefs
            // metadata — by exactly one task in the batch.
            let newOrModified = await batchFileClaims.claim(
                postSnapshot.filter { key, date in
                    preSnapshot[key] == nil || preSnapshot[key]! < date
                }.map { $0.key }
            )
            if !newOrModified.isEmpty {
                for path in newOrModified {
                    var isDir: ObjCBool = false
                    if let hostURL = resolveHostPath(path) {
                        FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir)
                    }
                    ensureParentDirsInMetaDB(for: path)
                    ensureFakefsMetadata(for: path, isDirectory: isDir.boolValue)
                }
                toolOutput += "\n\n[minis] New/modified files:"
                for path in newOrModified.sorted() {
                    if let url = linuxPathToMinisURL(path) {
                        toolOutput += "\n  \(url)"
                    }
                }
            }

            let (redactedOut, redactHits) = EnvVarRedactor.redactIfEnabled(toolOutput)
            if redactHits > 0 {
                ctLogger.info("[EnvVarRedact] shell_execute: masked \(redactHits) env-var value(s) in tool result")
            }
            toolOutput = redactedOut

        case "file_read":
            let fileResult: FileToolResult
            do {
                fileResult = try await executeFileRead(from: argsJson)
            } catch {
                fileResult = FileToolResult(output: "Error: \(error.localizedDescription)", success: false)
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = fileResult.output
            }
            toolOutput = fileResult.output
            toolSuccess = fileResult.success
            if fileResult.success,
               let data = argsJson.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let readPath = dict["path"] as? String,
               let skillId = SkillStore.shared.skillIdFromPath(readPath) {
                await MainActor.run { SkillStore.shared.recordSkillUse(skillId) }
            }

        case "file_write":
            let fileResult: FileToolResult
            do {
                fileResult = try await executeFileWrite(from: argsJson)
            } catch {
                fileResult = FileToolResult(output: "Error: \(error.localizedDescription)", success: false)
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = fileResult.output
            }
            toolOutput = fileResult.output
            toolSuccess = fileResult.success
            if fileResult.success,
               let data = argsJson.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let writtenPath = dict["path"] as? String,
               writtenPath.contains("/skills/") && writtenPath.hasSuffix("SKILL.md") {
                await MainActor.run { SkillStore.shared.reload() }
            }

        case "file_edit":
            let fileResult: FileToolResult
            do {
                fileResult = try await executeFileEdit(from: argsJson)
            } catch {
                fileResult = FileToolResult(output: "Error: \(error.localizedDescription)", success: false)
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = fileResult.output
            }
            toolOutput = fileResult.output
            toolSuccess = fileResult.success
            if fileResult.success,
               let data = argsJson.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let editedPath = dict["path"] as? String,
               editedPath.contains("/skills/") && editedPath.hasSuffix("SKILL.md") {
                await MainActor.run { SkillStore.shared.reload() }
            }

        case "browser_use":
            var browserResult: BrowserActionResult
            if let input = BrowserActionInput.parse(from: argsJson) {
                do {
                    browserResult = try await browserTabPool.execute(action: input)
                } catch {
                    browserResult = .error(error.localizedDescription)
                }
            } else {
                browserResult = .error("Invalid browser_use input. Required: 'action' parameter.")
            }

            if browserTakeoverActive {
                if let freshResult = await waitForMidActionTakeover() {
                    let originalText = browserResult.text
                    let takeoverNote = "\n[Browser takeover] User manually operated the browser. Screenshot updated."
                    browserResult = BrowserActionResult(
                        text: originalText + takeoverNote,
                        success: browserResult.success,
                        base64Image: freshResult.base64Image,
                        imageFilePath: freshResult.imageFilePath,
                        pageURL: freshResult.pageURL ?? browserResult.pageURL
                    )
                }
            }
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = browserResult.text
                messages[msgIdx].blocks[blockIdx].imageFilePath = browserResult.imageFilePath
                if let pageURL = browserResult.pageURL {
                    messages[msgIdx].blocks[blockIdx].browserURL = pageURL
                }
            }
            toolOutput = browserResult.text
            toolSuccess = browserResult.success
            toolPageURL = browserResult.pageURL
            // [AI-P2-9] The toolResult pageURL field is dropped by the vendor
            // wire conversions (tool_result has no URL slot on the wire), so
            // surface it in the result text — one place covering all vendors.
            // Skipped when a 来源 line is already present (e.g. getText
            // renders its own above). Appended at the end so browser_use's
            // prefix+suffix truncation keeps it.
            if let pageURL = browserResult.pageURL, !pageURL.isEmpty,
               !toolOutput.contains("来源：") {
                toolOutput += "\n来源：\(pageURL)"
            }
            if let b64 = browserResult.base64Image, let data = Data(base64Encoded: b64) {
                // [IMG-10] Same gate as read_image, soft oversize policy:
                // screenshots are app-produced, so an over-ceiling capture
                // converges through the gate's re-encode instead of being
                // refused; only an undecodable payload loses its image,
                // with the reason noted in the tool text. (The old code
                // force-labelled the raw bytes image/jpeg whenever its own
                // resize failed.)
                switch ImagePayloadPrep.gatedToolImage(data, oversize: .downscaleOversize) {
                case .success(let gated):
                    toolImageData = gated.data
                    toolImageMimeType = gated.mimeType
                case .failure(let rejection):
                    toolImageData = nil
                    toolImageMimeType = nil
                    toolOutput += "\n[Screenshot was captured but could not be attached: \(rejection.reason).]"
                }

                let timestamp = Int(Date().timeIntervalSince1970)
                let screenshotFilename = "screenshot_\(timestamp).jpg"
                let sid = sessionId ?? "unknown"
                let persistDir = Self.minisBrowserPersistentDir(for: sid)
                let fm = FileManager.default
                try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)
                let persistPath = persistDir.appendingPathComponent(screenshotFilename)
                try? data.write(to: persistPath)

                let linuxPath = "\(Self.minisBrowserLinuxDir)/\(screenshotFilename)"
                toolImageLinuxPath = linuxPath

                if let minisURL = linuxPathToMinisURL(linuxPath) {
                    toolOutput += "\nminis_url: \(minisURL)"
                }
            }

            if let fetchData = browserResult.fetchedFileData,
               let fetchName = browserResult.fetchedFileName {
                let sid = sessionId ?? "unknown"
                let persistDir = Self.minisBrowserPersistentDir(for: sid)
                try? FileManager.default.createDirectory(at: persistDir, withIntermediateDirectories: true)
                let persistPath = persistDir.appendingPathComponent(fetchName)
                try? fetchData.write(to: persistPath)

                let linuxPath = "\(Self.minisBrowserLinuxDir)/\(fetchName)"
                if let minisURL = linuxPathToMinisURL(linuxPath) {
                    toolOutput += "\nminis_url: \(minisURL)"
                }
            }

            // [T-browser-download-ux] Surface native WKDownload activity in the
            // tool result so the agent KNOWS a page interaction triggered a
            // download and doesn't re-download the same file via shell
            // curl/wget. WebKit's decideDestination callback can land a beat
            // after the action resolves (navigation-turned-download resumes
            // the continuation first), so if a download is in flight but not
            // yet registered, wait briefly for the filename to be known.
            if let sid = sessionId {
                var downloadReport = BrowserDownloadCenter.shared.agentReport(for: sid)
                if downloadReport == nil,
                   browserTabPool.activeManager?.hasInflightDownloads == true {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    downloadReport = BrowserDownloadCenter.shared.agentReport(for: sid)
                        ?? "[browser_downloads] This action triggered a native browser file "
                         + "download that is still starting (filename not yet resolved). It will "
                         + "be saved into /var/minis/workspace/ — do NOT re-download it with "
                         + "curl/wget; check the workspace or the next browser_use result instead."
                }
                if let downloadReport {
                    toolOutput += "\n\n" + downloadReport
                }
            }

        case "read_image":
            let pathArg = toolArgs["path"] as? String ?? ""
            let resolvedURL = await resolveMinisPath(pathArg)
            ctLogger.info("[read_image] pathArg=\(pathArg) resolvedURL=\(resolvedURL?.path ?? "nil") exists=\(resolvedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
            // [IMG-10] One read, one shared gate (the browser-screenshot
            // path uses the same one): format sniffed from magic bytes and
            // checked against the whitelist, 20 MB / 40 MP ceilings checked
            // from the header BEFORE any decode, EXIF orientation baked in,
            // unified context caps. A refusal names the specific reason —
            // the old code lumped unsupported formats, oversize files and
            // truncated data into one "could not read" and probed the file
            // with two extra full reads just for logging.
            var gateRejection: ImagePayloadPrep.ToolImageRejection?
            var gatedImage: ImagePayloadPrep.GatedToolImage?
            var sourceData: Data?
            if let fileURL = resolvedURL, let fileData = try? Data(contentsOf: fileURL) {
                sourceData = fileData
                switch ImagePayloadPrep.gatedToolImage(fileData) {
                case .success(let gated): gatedImage = gated
                case .failure(let rejection): gateRejection = rejection
                }
            }

            if let fileURL = resolvedURL, let fileData = sourceData, let gated = gatedImage {
                let originalSize = fileData.count
                let originalW = Int(gated.pixelSize.width)
                let originalH = Int(gated.pixelSize.height)
                let inferenceData = gated.data
                let outSize = ImagePayloadPrep.pixelSize(gated.data)
                let resizedW = outSize.map { Int($0.width) } ?? originalW
                let resizedH = outSize.map { Int($0.height) } ?? originalH

                if pathArg.hasPrefix("/var/minis/") {
                    toolImageLinuxPath = pathArg
                } else if pathArg.hasPrefix("minis-clone://") {
                    let tail = String(pathArg.dropFirst("minis-clone://".count))
                    if !tail.isEmpty {
                        toolImageLinuxPath = "/var/minis/\(tail)"
                    }
                }

                var meta = "Image loaded successfully."
                meta += "\nPath: \(pathArg)"
                meta += "\nOriginal: \(originalW)x\(originalH), \(formatBytes(originalSize))"
                if resizedW != originalW || resizedH != originalH {
                    meta += "\nResized for analysis: \(resizedW)x\(resizedH)"
                }
                if gated.sourceFormat != gated.mimeType {
                    meta += "\nConverted from \(gated.sourceFormat) to \(gated.mimeType) for analysis."
                }
                if ImagePayloadPrep.frameCount(fileData) > 1 {
                    meta += "\nAnimated image: first frame used for analysis."
                }
                meta += "\nMIME: \(gated.mimeType)"

                // [T-ios-vision-group #182] Two ways to answer this call.
                //
                // Native-vision models keep the original behaviour exactly:
                // attach the pixels and let the model look at them.
                //
                // A model WITHOUT native vision only reaches this line because a
                // Vision Group is configured (that's the tool-exposure gate), so
                // hand the bytes to that group and return its DESCRIPTION as
                // text. Crucially we then leave `toolImageData` nil: attaching
                // pixels a text-only model can't decode is what the providers
                // silently drop today, and on the OpenAI Chat Completions path
                // they'd be dropped without even a placeholder.
                // [T-ios-vision-group-t264 #182] Optional caller-supplied question
                // about the image. Only load-bearing on the vision-group branch —
                // there it steers the describing model, which is the host model's
                // only way to follow up on a detail it cannot look at itself.
                let visionPrompt = (toolArgs["prompt"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // [T-ios-vision-branch-mismatch #182] MUST be the same source the
                // registration used — see `activeModelHasNativeVision`. Reading
                // `selectedModel` here (while the request is built from
                // resolveCurrentEntry) is what made a text-only model fall into
                // the native pixel branch and get metadata instead of a
                // description.
                let nativeVision = self.activeModelHasNativeVision
                if nativeVision {
                    toolImageData = inferenceData
                    toolImageMimeType = gated.mimeType
                    // Native models see the pixels, so the prompt isn't needed to
                    // direct anything — but echo it so the transcript shows what
                    // the model was looking for. Image data is untouched.
                    if let p = visionPrompt, !p.isEmpty {
                        toolOutput = meta + "\nRequested focus: \(p)"
                    } else {
                        toolOutput = meta
                    }
                    toolSuccess = true
                } else {
                    do {
                        // [T-ios-vision-group-attribution #182] Name the model
                        // that is currently reading, live. Previously the card
                        // just said "Reading image <path>…" for however many
                        // seconds the call took, so the user could not tell
                        // which member of the group was working — nor see a
                        // fallback happen. `onAttempt` fires before each
                        // candidate, so a switch is visible as it occurs.
                        let groupLabel = VisionGroupResolver.groupName()
                        let pathForUI = pathArg
                        // [s2-ocr] OCR ladder (IMG-9): image-hash cache →
                        // free on-device OCR → Vision Group describe. Only the
                        // last tier spends model quota; repeat reads of the
                        // same image cost nothing. See ImageOCRTier.
                        let tierOutcome = try await ImageOCRTier.textForImage(
                            originalData: fileData,
                            preparedData: inferenceData,
                            mimeType: gated.mimeType,
                            customPrompt: visionPrompt,
                            seed: abs(tu.id.hashValue),
                            onAttempt: { [weak self] attempt in
                                guard let self,
                                      msgIdx < self.messages.count,
                                      blockIdx < self.messages[msgIdx].blocks.count else { return }
                                let via = groupLabel.map { " (\($0))" } ?? ""
                                let retry = attempt.index > 1
                                    ? " — attempt \(attempt.index)/\(attempt.total)" : ""
                                self.messages[msgIdx].blocks[blockIdx].content =
                                    "Reading image \(pathForUI) via \(attempt.modelName)\(via)\(retry)…"
                            }
                        )
                        toolOutput = meta + "\n\n" + tierOutcome.framedText
                        toolSuccess = true
                        let viaName = tierOutcome.modelName.map { " via \($0)" } ?? ""
                        ctLogger.info("[read_image] ocr-tier source=\(tierOutcome.source.rawValue)\(viaName) cached=\(tierOutcome.fromCache)")
                    } catch {
                        // Deliberately a SUCCESSFUL result carrying failure text:
                        // an errored tool result tends to make models retry in a
                        // loop, whereas this lets the model tell the user plainly.
                        let reason = (error as? VisionGroupResolver.VisionError)?.errorDescription
                            ?? error.localizedDescription
                        toolOutput = meta + "\n\n" + VisionGroupResolver.failureText(reason)
                        toolSuccess = true
                        ctLogger.error("[read_image] vision-group describe FAILED: \(reason)")
                    }
                }

                // The on-screen tool block shows the image itself in BOTH
                // branches — the user can always see what was read, regardless
                // of what the model received.
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].imageFilePath = fileURL.path
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
            } else if let gateRejection {
                ctLogger.error("[read_image] GATE-REFUSED pathArg=\(pathArg) reason=\(gateRejection.reason)")
                toolOutput = "Error: Could not read image at '\(pathArg)': \(gateRejection.reason)."
                toolSuccess = false
            } else {
                ctLogger.error("[read_image] FAILED pathArg=\(pathArg) resolvedURL=\(resolvedURL?.path ?? "nil")")
                toolOutput = "Error: Could not read image at '\(pathArg)'. Verify the path exists and is a valid image file."
                toolSuccess = false
            }

        case "memory_write":
            let memResult = executeMemoryWrite(from: argsJson)
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = memResult.output
            }
            toolOutput = memResult.output
            toolSuccess = memResult.success

        case "memory_get":
            let memResult = executeMemoryGet(from: argsJson)
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = memResult.output
            }
            toolOutput = memResult.output
            toolSuccess = memResult.success

        case "ask_user_input_v0":
            let askResult = await handleAskUser(toolArgs: toolArgs, toolId: tu.id, deferredAssistantRaw: deferredAssistantRaw)
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = askResult.summary
            }
            toolOutput = askResult.output
            toolSuccess = askResult.success

        case "web_search":
            // [s2-search] 第 18 条联网搜索：查资料。query 为空直接拦；
            // key 没配好时工具根本不会注册到模型面前，这里是双保险。
            let searchQuery = (toolArgs["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if searchQuery.isEmpty {
                toolOutput = "Error: Missing required 'query' parameter. Please call web_search again with a non-empty `query`."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }
            let searchCount: Int = {
                if let n = toolArgs["count"] as? Int { return n }
                if let s = toolArgs["count"] as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
                return 8
            }()
            do {
                let outcome = try await WebSearchService.search(
                    query: searchQuery, count: min(max(searchCount, 1), 20))
                let formatted = WebSearchService.formatForModel(outcome, query: searchQuery)
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = formatted
                }
                toolOutput = formatted
                toolSuccess = true
            } catch let searchErr as WebSearchError {
                // userMessage 里不带 key 明文（见 WebSearchError）。
                toolOutput = "Error: \(searchErr.userMessage)"
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
            } catch let cancel as CancellationError {
                // 取消必须透传出去，不能吞成"搜索失败"（外层 do/catch 负责收）。
                throw cancel
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                // URLSession 取消传出来的是 URLError(.cancelled) 不是 CancellationError，
                // 转一下让外层取消分支能收（不转会掉进下面的兜底变成"搜索失败"）。
                throw CancellationError()
            } catch {
                toolOutput = "Error: 搜索失败：\(error.localizedDescription)"
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
            }

        case "send_voice":
            // [voice-bubble-tool 2026-10-02] AI 主动发语音的正规链路：复用朗读同款 TTS
            // 链路合成，气泡以 inline part 落进当前回复（UI block 立刻可见；DB 行在
            // 本轮 batch 落盘后补气泡 part，见 runAgentLoop 的 pendingVoiceBubbles
            // flush——agentHistory 永远不带气泡 part，沿用 context-clean 单一口径）。
            // 合成走 AIVoiceMessageComposer.compose（service → group 候选链），
            // 与"AI Voice Replies"自动气泡同一条路。
            let speakText = (toolArgs["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if speakText.isEmpty {
                toolOutput = "Error: Missing required 'text' parameter. Please call send_voice again with the words to speak in `text`."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }
            guard let sid = sessionId else {
                toolOutput = "Error: no active session — cannot send voice."
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
                break
            }
            // [voice-bubble-tool 2026-10-02] voice/group 点名（TTS 施工员转交）：
            // 空字符串当没传；点名走严格语义（找不到/都挂了就报错，不悄悄换声音）。
            let voiceParam: String? = {
                let v = (toolArgs["voice"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }()
            let groupParam: String? = {
                let g = (toolArgs["group"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return g.isEmpty ? nil : g
            }()
            do {
                let voice = try await AIVoiceMessageComposer.compose(
                    for: speakText, sessionId: sid, voice: voiceParam, group: groupParam)
                let durParam = voice.duration > 0 ? Int(voice.duration.rounded()) : 0
                let link = "![voice](\(voice.url)?voice_bubble=1&dur=\(durParam)&auto_play=true)"
                // ① UI：气泡 block 直接进当前回复（用户立刻看见）。
                if msgIdx < messages.count {
                    messages[msgIdx].blocks.append(AssistantBlock(kind: .text, content: link))
                }
                // ② DB：deferred raw 建于工具执行前，这里只记账，落盘时统一补 part。
                pendingVoiceBubbles.append(link)
                voiceBubbleSentThisTurn = true
                // ③ 自动播放（与 StreamEnd 自动气泡一致；录音中不抢麦）。
                if !VoiceModePreference.shared.isCapturing {
                    if let fileURL = await resolvePathForDirectRead(
                        AIVoiceMessageComposer.linuxPathFor(url: voice.url)) {
                        GlobalAudioPlayer.shared.play(url: fileURL)
                    }
                }
                let via = voice.serviceName.map { "（\($0)合成）" } ?? ""
                ctLogger.info("[VoiceBubbleTool] sent voice bubble dur=\(durParam)s service=\(voice.serviceName ?? "default-chain")")
                let summary = "语音消息已发出（约\(durParam)秒\(via)），以语音气泡呈现并自动播放。"
                toolOutput = summary
                toolSuccess = true
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = summary
                }
            } catch is CancellationError {
                // [p1fix 2026-10-02] 取消信号必须透传——外层的 `catch is CancellationError`
                // 负责收尾（用户点停止）。无差别 catch 会把它变成普通工具结果，
                // 导致"点了停止停不下来"。
                throw CancellationError()
            } catch {
                // VoiceComposeError 的 description 直接是给模型的中文交代（含可用选项）；
                // 其他错误兜底，不让模型对着空气猜。
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                toolOutput = "Error: \(msg)"
                toolSuccess = false
                if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                    messages[msgIdx].blocks[blockIdx].content = toolOutput
                }
            }

        case "add_mcp", "list_mcp", "remove_mcp", "toggle_mcp":
            // [mcp-agg] MCP 聚合点管理工具（小管家专用）：定义与实现在 MCPManagementTools。
            let (mcpText, mcpOK) = await MCPManagementTools.handleDialogCall(name: tu.name, args: toolArgs)
            toolOutput = mcpText
            toolSuccess = mcpOK
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = toolOutput
            }

        default:
            toolOutput = "Error: Unknown tool '\(tu.name)'"
            toolSuccess = false
        }
        } catch is CancellationError {
            let cancelContent = "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>"
            let existing = (msgIdx < messages.count && blockIdx < messages[msgIdx].blocks.count)
                ? messages[msgIdx].blocks[blockIdx].content : ""
            toolOutput = existing.isEmpty ? cancelContent : existing + "\n" + cancelContent
            toolSuccess = false
            cancelledHere = true
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].toolStatus = .cancelled
            }
        } catch {
            ctLogger.error("Tool execution threw non-cancellation error: \(error)")
            toolOutput = "Error: \(error.localizedDescription)"
            toolSuccess = false
        }

        // Tail cancel-detection: if Task got cancelled mid-execution.
        if !cancelledHere && Task.isCancelled && self.userDidCancel {
            cancelledHere = true
            toolOutput += "\n<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>"
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].content = toolOutput
                messages[msgIdx].blocks[blockIdx].toolStatus = .cancelled
            }
        }

        let toolDuration: TimeInterval? = {
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count,
               let start = messages[msgIdx].blocks[blockIdx].toolStartTime {
                return Date().timeIntervalSince(start)
            }
            return nil
        }()

        // Create snapshot from tool output.
        let snapshot: ToolSnapshot
        switch tu.name {
        case "browser_use":
            if let imagePath = (msgIdx < messages.count && blockIdx < messages[msgIdx].blocks.count)
                ? messages[msgIdx].blocks[blockIdx].imageFilePath : nil,
               let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
               let sid = sessionId {
                let ref = await ChatStore.shared.saveMedia(
                    data: imageData, mimeType: "image/jpeg", sessionId: sid,
                    originalFileName: "browser_snapshot.jpg", subdir: "browser",
                    linuxPath: toolImageLinuxPath
                )
                snapshot = ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: toolDuration)
            } else {
                let lines = toolOutput.components(separatedBy: "\n")
                let lastLines = lines.suffix(20).joined(separator: "\n")
                snapshot = ToolSnapshot(type: .text, text: lastLines, mediaRef: nil, duration: toolDuration)
            }
        case "read_image":
            if let imagePath = (msgIdx < messages.count && blockIdx < messages[msgIdx].blocks.count)
                ? messages[msgIdx].blocks[blockIdx].imageFilePath : nil,
               let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
               let sid = sessionId {
                let fileURL = URL(fileURLWithPath: imagePath)
                let mime = Self.detectImageMime(imageData)
                let ref = await ChatStore.shared.saveMedia(
                    data: imageData, mimeType: mime, sessionId: sid,
                    originalFileName: fileURL.lastPathComponent, subdir: "images",
                    linuxPath: toolImageLinuxPath
                )
                snapshot = ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: toolDuration)
            } else {
                snapshot = ToolSnapshot(type: .text, text: toolOutput, mediaRef: nil, duration: toolDuration)
            }
        case "file_write", "file_edit":
            if let path = toolArgs["path"] as? String,
               let hostURL = await resolvePathForDirectRead(path),
               let fileContent = try? String(contentsOf: hostURL, encoding: .utf8) {
                let lines = fileContent.components(separatedBy: "\n")
                let preview = lines.prefix(200).joined(separator: "\n")
                snapshot = ToolSnapshot(type: .text, text: preview, mediaRef: nil, duration: toolDuration)
            } else {
                snapshot = ToolSnapshot(type: .text, text: toolOutput, mediaRef: nil, duration: toolDuration)
            }
        default:
            snapshot = ToolSnapshot(type: .text, text: toolOutput, mediaRef: nil, duration: toolDuration)
        }

        let snapshotResolver = await ChatStore.shared.mediaFileURLResolver()
        let snapshotItem = ToolSnapshotItem(
            id: tu.id, toolName: tu.name, snapshot: snapshot, mediaResolver: snapshotResolver
        )

        // Update tool block status and store execution duration.
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            let blk = messages[msgIdx].blocks[blockIdx]
            blk.toolDuration = toolDuration
            if cancelledHere {
                blk.toolStatus = .cancelled
            } else if toolSuccess, truncationRepairTag != nil {
                // [T-truncated-args-visibility #119] A repaired call must not
                // render as a clean success — that is exactly the silence the
                // user reported. Surface it with the same weight the blocked
                // path already gets, so "arguments were altered" is visible in
                // the transcript rather than buried in a log line.
                blk.toolStatus = .failed(
                    message: AppLocalized("Arguments truncated in transit — result may be incomplete")
                )
            } else {
                blk.toolStatus = toolSuccess
                    ? .success
                    : .failed(message: toolOutput.components(separatedBy: "\n").first ?? "Failed")
            }
            ctLogger.info("[ToolLifecycle] COMPLETED toolId=\(tu.id.prefix(20)) tool=\(tu.name) sid=\(sessionId?.prefix(8) ?? "nil") appState=\(UIApplication.shared.applicationState == .active ? "fg" : "bg") suspended=\(streamingUIUpdatesSuspended) isProcessing=\(isProcessing) success=\(toolSuccess) duration=\(String(format: "%.1f", toolDuration ?? 0))s")
            scrollToBottomSignal.send()
        }

        // [T-shared-event-log] Cross-session trace when a heavy tool finishes,
        // so other sessions can see it in /var/minis/shared/events.jsonl.
        // The output excerpt goes through SharedEventLog.redact().
        let toolDur = toolDuration ?? 0
        // 轻量工具平时不记，但失败了要记——跨会话排障时"谁挂了"
        // 比"谁跑得久"更重要（AI-P2-13）。
        if !toolSuccess
            || SharedEventLog.heavyToolNames.contains(tu.name)
            || toolDur >= SharedEventLog.heavyDurationThreshold {
            let outcome = cancelledHere ? "cancelled" : (toolSuccess ? "ok" : "failed")
            let firstLine = toolOutput.components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            SharedEventLog.shared.emit(
                event: "tool.finished",
                summary: "\(tu.name) \(outcome) \(String(format: "%.1f", toolDur))s: \(String(firstLine.prefix(160)))",
                sessionId: sessionId
            )
        }

        // Compose finalOutput with truncation/offload.
        let maxToolResultLength = Self.kMaxToolResultChars
        var finalOutput: String
        if toolOutput.isEmpty {
            finalOutput = "(no output)"
        } else if toolOutput.count > maxToolResultLength {
            let offloadResult = offloadToolOutput(toolOutput, toolName: tu.name, toolId: tu.id)
            let offloadMinisURL = linuxPathToMinisURL(offloadResult.linuxPath)
            let truncatedBody: String
            if tu.name == "shell_execute" || tu.name == "browser_use" {
                let halfLen = maxToolResultLength / 2
                truncatedBody = String(toolOutput.prefix(halfLen))
                    + "\n\n...\n\n"
                    + String(toolOutput.suffix(halfLen))
            } else {
                truncatedBody = String(toolOutput.prefix(maxToolResultLength))
            }
            finalOutput = truncatedBody
                + "\n\n[OUTPUT TRUNCATED] Full output (\(toolOutput.count) chars) saved to: \(offloadResult.linuxPath)"
                + (offloadMinisURL.map { "\nminis_url: \($0)" } ?? "")
                + "\nUse file_read tool to read the complete output."
        } else {
            finalOutput = toolOutput
        }

        // Image budget: reserve a slot atomically via the actor. If
        // declined, swap image bytes for a text placeholder.
        if let imgData = toolImageData {
            let granted = await batchBudget.reserveSlot()
            if !granted {
                let placeholder = Self.imagePlaceholderText(data: imgData, originalPath: toolArgs["path"] as? String, snapshotPath: nil)
                if finalOutput.isEmpty || !toolSuccess {
                    finalOutput = placeholder
                } else {
                    finalOutput += "\n\n" + placeholder
                }
                toolImageData = nil
                toolImageMimeType = nil
                ctLogger.info("🖼️ Tool image budget exhausted, stripped image from \(tu.name) id:\(tu.id.prefix(8))")
            }
        }

        // Loop-detector post-record.
        let postCheck = toolLoopDetector.record(
            toolName: tu.name, params: toolArgs,
            result: toolSuccess ? finalOutput : nil,
            errorMessage: toolSuccess ? nil : finalOutput,
            toolCallId: tu.id
        )
        if postCheck.level == .warning, let warningMsg = postCheck.message {
            if finalOutput.isEmpty {
                finalOutput = warningMsg
            } else {
                finalOutput += "\n\n" + warningMsg
            }
        }

        // [T-truncated-args-visibility #119] Tell the MODEL when the call it
        // just got a success for was built from truncated arguments.
        //
        // Writes never reach here (refused above), so this covers the tools we
        // still run repaired — shell_execute, browser_use, file_read, … There
        // the repaired call may well have done the right thing, but the model
        // has no way to know its own arguments were altered, and silently
        // assuming they were intact is how a half-truth propagates downstream.
        // Stating it lets the model verify rather than guess.
        if let tag = truncationRepairTag {
            finalOutput += "\n\n<system-reminder>The argument stream for this call was truncated in "
                + "transit and auto-closed by the client (repair strategy: \(tag)) before execution. "
                + "The arguments actually used may be incomplete — verify the result and re-issue "
                + "the call with complete arguments if anything is missing.</system-reminder>"
        }

        let resultPart = AgentContentPart.toolResult(
            id: tu.id, name: tu.name, content: finalOutput, isError: !toolSuccess,
            imageData: toolImageData, imageMimeType: toolImageMimeType,
            pageURL: toolPageURL, imageLinuxPath: toolImageLinuxPath
        )

        #if DEBUG
        let head = String(finalOutput.prefix(200))
        let tail = finalOutput.count > 400 ? "...\(String(finalOutput.suffix(200)))" : ""
        ctLogger.debug("🔧 Tool result [\(tu.name)] id:\(tu.id.prefix(8)) success:\(toolSuccess) len:\(finalOutput.count) head=\"\(head)\" \(tail)")
        #endif

        return ToolExecOutcome(
            toolId: tu.id, toolName: tu.name,
            resultPart: resultPart,
            snapshotEntry: (toolName: tu.name, snapshot: snapshot),
            snapshotItem: snapshotItem,
            cancelled: cancelledHere
        )
    }
}
