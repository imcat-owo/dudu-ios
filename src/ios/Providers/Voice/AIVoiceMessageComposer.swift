import Foundation

// MARK: - AI voice-message composer
//
// [T-ai-voice-messages 09-12] 醒醒 2：「我想要里面的ai自己也能发语音，发出来就是
// 自动播放的。有气泡UI像wx那样会动的，有动态效果。」
//
// Flow (triggered from StreamEnd when per-session "AI Voice Replies" is ON):
//   1. Sanitize the assistant text (strip markdown, keep plain text).
//   2. Synthesize via the read-aloud candidate chain (service → group → System).
//   3. Write the WAV bytes to the session's attachments dir.
//   4. Return a minis-clone:// URL + duration for the caller to embed into a
//      markdown audio link. The link renders as a WX-style voice bubble via
//      AudioAttachment (detects `voice_bubble=1` query param).

@MainActor
enum AIVoiceMessageComposer {

    private static let logger = AppLogger(category: "AIVoiceComposer")

    /// Result: (minis-clone URL String, duration in seconds).
    struct Result {
        let url: String
        let duration: Double
        /// 实际合成出音频的服务名（默认链路兜底时为 nil）。
        /// [voice-bubble-tool 2026-10-02] send_voice 点名 voice/group 时回给模型，
        /// 让它知道到底是哪个声音发出去的。
        let serviceName: String?
    }

    /// [voice-bubble-tool 2026-10-02] send_voice 点名 voice/group 时的错误。
    /// description 直接是给模型的中文交代（含可用选项），调用方原样回即可。
    enum VoiceComposeError: LocalizedError {
        case emptyText
        case groupNotFound(name: String, available: [String])
        case groupEmpty(name: String)
        case voiceNotFound(name: String, available: [String])
        case serviceDisabled(name: String)
        case synthesisFailed(detail: String)

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "没有可说的话（文本为空）。"
            case .groupNotFound(let name, let available):
                let opts = available.isEmpty ? "（还没有建任何分组）" : "可用分组：" + available.joined(separator: "、")
                return "没有这个 TTS 分组「\(name)」。\(opts)不传 group 就用默认分组。"
            case .groupEmpty(let name):
                return "TTS 分组「\(name)」里没有可用的服务（成员都被删了或停用了）。换个分组，或不传 group 用默认的。"
            case .voiceNotFound(let name, let available):
                let opts = available.isEmpty ? "（还没有配任何 TTS 服务）" : "可用服务：" + available.joined(separator: "、")
                return "没有这个 TTS 服务「\(name)」。\(opts)不传 voice 就用默认分组。"
            case .serviceDisabled(let name):
                return "TTS 服务「\(name)」已停用。让主人去「设置 > Voice Services」里启用，或换个服务。"
            case .synthesisFailed(let detail):
                return "语音合成失败（\(detail)）。如实告诉主人这条语音没发出去，不要谎称已发送；可以建议她检查 TTS 服务配置。"
            }
        }
    }

    private static func prefKey(_ sid: String) -> String { "ai.voiceReplies.\(sid)" }

    static func voiceRepliesEnabled(sessionId: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefKey(sessionId))
    }

    static func setVoiceReplies(enabled: Bool, sessionId: String) {
        UserDefaults.standard.set(enabled, forKey: prefKey(sessionId))
    }

    /// [T-voice-bubble-context-clean 09-12] True when an assistant text part is
    /// ONLY a wx-style voice bubble this app composed. Such rows are DB/UI-only:
    /// loadSession keeps them OUT of agentHistory so the model never sees (and
    /// never imitates) its own bubble markdown. Shape-anchored, not
    /// substring-anchored: a normal reply that merely MENTIONS "voice_bubble=1"
    /// must never be stripped (unit-tested boundary: a 29-char reply mentioning
    /// the param stays; only an actual `![voice](…voice_bubble=1…)` link part
    /// goes).
    nonisolated static func isVoiceBubbleOnlyText(_ s: String) -> Bool {
        guard s.hasPrefix("![voice](") else { return false }
        guard s.contains("voice_bubble=1") else { return false }
        return s.count < 200
    }

    /// Synthesize the assistant reply text and persist the audio in the session's
    /// attachments dir. Returns a minis-clone:// URL ready for embedding into a
    /// `![voice](...)` markdown link. All errors (empty text, every candidate
    /// failed) are logged and return nil. [AI-P2-3] The caller owns the
    /// user-visible side of nil: it toasts the failure AND appends a
    /// <system-reminder> trace to the in-memory assistant message so the model
    /// knows no voice bubble went out — the nil itself stays silent here.
    ///
    /// [voice-bubble-tool 2026-10-02] 这是默认链路版（等价于 voice/group 都不传）。
    /// 要点名音色/分组的调用方请用下面的 throwing 重载，能拿到"为什么不行"的
    /// 具体原因（VoiceComposeError 的 description 直接是给模型的中文交代）。
    static func compose(for text: String, sessionId: String) async -> Result? {
        do {
            return try await compose(for: text, sessionId: sessionId, voice: nil, group: nil)
        } catch {
            logger.warning("voice message synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// [voice-bubble-tool 2026-10-02] send_voice 专用：voice/group 点名版。
    /// - voice: TTS 服务名（服务的 id 也行），用该服务的音色合成。
    /// - group: TTS 分组名（分组 id 也行），按分组成员顺序 fallback。
    /// 都不传 = 走默认链路（默认 TTS 分组 → 选中服务 → 模型分组）。
    /// 点名时是严格语义：只试点名的候选，死透了就抛错，不会悄悄用别的声音顶。
    static func compose(for text: String, sessionId: String, voice: String?, group: String?) async throws -> Result {
        let sanitized = VoiceTextSanitizer.sanitize(text, mode: .fullText)
        guard !sanitized.isEmpty else { throw VoiceComposeError.emptyText }

        let data: Data
        let dur: Double
        let usedService: String?
        do {
            (data, dur, usedService) = try await synthesizeFull(sanitized, voice: voice, group: group)
        } catch let e as VoiceComposeError {
            throw e
        } catch is CancellationError {
            // 取消必须透传，不能吞成"合成失败"（外层 dispatch 的取消分支负责收）。
            throw CancellationError()
        } catch {
            logger.warning("voice message synthesis failed: \(error.localizedDescription)")
            throw VoiceComposeError.synthesisFailed(detail: "TTS 服务不可用或未配置")
        }
        guard !data.isEmpty else { throw VoiceComposeError.synthesisFailed(detail: "合成返回空音频") }

        let ext = Self.isWAVData(data) ? "wav" : "mp3"
        let fname = "tts-\(UUID().uuidString.prefix(8)).\(ext)"
        let hostDir = AIChatViewModel.minisAttachmentsPersistentDir(for: sessionId)
        try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        let dest = hostDir.appendingPathComponent(fname)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            logger.warning("voice message write failed: \(error.localizedDescription)")
            throw VoiceComposeError.synthesisFailed(detail: "音频写盘失败")
        }
        let linuxPath = "/var/minis/attachments/\(fname)"
        let minisURL = "minis-clone://attachments/\(fname.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fname)"
        logger.info("voice message composed: \(linuxPath) dur=\(String(format: "%.1f", dur))s size=\(data.count) service=\(usedService ?? "default-chain")")
        return Result(url: minisURL, duration: dur, serviceName: usedService)
    }

    /// Walk the candidate chain exactly like read-aloud: selected service →
    /// model group. [T-system-voice-off 09-12] 醒醒 3: System voice is an
    /// EXPLICIT fallback, not a silent one — when nothing user-configured is
    /// usable we throw instead of falling to AVSpeechSynthesizer, so the turn
    /// reads as text-only and the log names the gap. The old always-System
    /// tail made every misconfigured session sound like the robotic system
    /// voice 醒醒 hates.
    private static func synthesizeFull(_ text: String, voice: String?, group: String?) async throws -> (Data, Double, String?) {
        // [voice-bubble-tool 2026-10-02] 点名了就走严格语义：只试点名的候选
        //（分组按成员顺序 fallback），死透了抛错，不悄悄用别的声音顶。
        if let explicit = try resolveExplicitServices(voice: voice, group: group) {
            for service in explicit {
                if let (data, _) = try await synthesizeWithService(service, text) {
                    return (data, VoiceOutputPlayer.wavDurationOf(data), service.name)
                }
            }
            throw VoiceComposeError.synthesisFailed(detail: "点名的 TTS 候选都失败了")
        }
        // 默认链路：和以前完全一致（默认 TTS 分组 → 选中服务 → 模型分组）。
        // 取消透传（不能 try? 吞掉），其他失败才落到下面的 synthesisFailed。
        do {
            let (data, _) = try await synthesizeWithServiceOrGroup(text)
            return (data, VoiceOutputPlayer.wavDurationOf(data), nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 普通失败：继续抛 synthesisFailed
        }
        throw VoiceComposeError.synthesisFailed(detail: "没有可用的 TTS 目标——先选个 TTS 服务或语音分组")
    }

    /// [voice-bubble-tool 2026-10-02] 把模型传的 voice/group 解析成候选服务列表。
    /// 都不传返回 nil（调用方走默认链路）。匹配顺序：id 精确 → 名字精确 →
    /// 名字忽略大小写。找不到/不可用就抛 VoiceComposeError（description 直接
    /// 是给模型的中文交代，含可用选项）。
    private static func resolveExplicitServices(voice: String?, group: String?) throws -> [TTSServiceOptions]? {
        if let g = group?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            let store = TTSGroupStore.shared
            let matched = store.group(id: g)
                ?? store.groups.first { $0.name == g }
                ?? store.groups.first { $0.name.lowercased() == g.lowercased() }
            guard let grp = matched else {
                throw VoiceComposeError.groupNotFound(name: g, available: store.groups.map { $0.name })
            }
            let cands = store.candidates(for: grp)
            guard !cands.isEmpty else {
                throw VoiceComposeError.groupEmpty(name: grp.name)
            }
            logger.info("[AIVoice] explicit group '\(grp.name)' → \(cands.count) candidate(s)")
            return cands
        }
        if let v = voice?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            let store = TTSServiceStore.shared
            let matched = store.service(id: v)
                ?? store.services.first { $0.name == v }
                ?? store.services.first { $0.name.lowercased() == v.lowercased() }
            guard let svc = matched else {
                throw VoiceComposeError.voiceNotFound(
                    name: v, available: store.services.filter { $0.enabled }.map { $0.name })
            }
            guard svc.enabled else {
                throw VoiceComposeError.serviceDisabled(name: svc.name)
            }
            logger.info("[AIVoice] explicit voice service '\(svc.name)'")
            return [svc]
        }
        return nil
    }

    /// linuxPathFor(url:) — turn the minis-clone URL back into the /var/minis
    /// path (used by the auto-play trigger's resolvePathForDirectRead).
    nonisolated static func linuxPathFor(url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host else { return "" }
        let sub = comps.percentEncodedPath.isEmpty ? "" : "/" + (comps.percentEncodedPath.dropFirst().removingPercentEncoding ?? String(comps.percentEncodedPath.dropFirst()))
        return "/var/minis/\(host)\(sub)"
    }

    /// [TTS-11] RIFF/WAVE magic check — the saved bubble's extension must
    /// describe the actual bytes (the old code guessed from whether a
    /// WAV duration could be read, which mislabels any vendor that
    /// returns WAV where MP3 was requested and vice versa).
    nonisolated static func isWAVData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.subdata(in: 0..<4) == Data("RIFF".utf8)
            && data.subdata(in: 8..<12) == Data("WAVE".utf8)
    }

    /// [TTS-11] Synthesize `text` through `synth`, splitting UP FRONT at
    /// `limit` characters on sentence boundaries when the text exceeds
    /// it, then joining the pieces into one blob with the read-aloud
    /// path's concat rules. A long reply used to go out as ONE request:
    /// past the vendor's per-request cap (Doubao 1024, OpenAI 4096, …)
    /// the whole bubble failed and the reply stayed text-only. Any
    /// chunk failing fails the whole bubble, same as before.
    /// [AI-P2-4] Each chunk now goes through `synthWithRetry` below —
    /// same-text retries with backoff, then split-smaller — mirroring
    /// read-aloud's `VoiceOutputPlayer.synthWithRetry` instead of the old
    /// single attempt per chunk (one network hiccup used to kill the
    /// whole long-reply bubble).
    private static func synthesizeChunked(
        _ text: String, limit: Int,
        _ synth: (String) async throws -> Data
    ) async throws -> Data {
        let chunks = VoiceOutputPlayer.splitText(text, maxChars: limit)
        guard chunks.count > 1 else { return try await synthWithRetry(text, synth) }
        var pieces: [Data] = []
        for chunk in chunks {
            let d = try await synthWithRetry(chunk, synth)
            guard !d.isEmpty else { throw VoiceProviderError.noAudioData }
            pieces.append(d)
        }
        logger.info("[AIVoice] long reply synthesized in \(chunks.count) chunks (limit \(limit))")
        return VoiceOutputPlayer.concatPieces(pieces)
    }

    /// [AI-P2-4] Two-phase resilience for one chunk, mirroring read-aloud's
    /// `VoiceOutputPlayer.synthWithRetry` (same retry counts/backoff/split
    /// size, shared constants): Phase 1 retries the SAME text with backoff;
    /// Phase 2 splits into smaller pieces and synthesizes those. Empty audio
    /// counts as a failed attempt. Throws only when both phases fail.
    private static func synthWithRetry(
        _ text: String,
        _ synth: (String) async throws -> Data
    ) async throws -> Data {
        let maxAttempts = VoiceOutputPlayer.synthRetriesSameText
        var lastError: Error?
        // Phase 1: retry the same text.
        for attempt in 0...maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            do {
                let d = try await synth(text)
                if !d.isEmpty { return d }
                lastError = VoiceProviderError.noAudioData
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            logger.warning("[AIVoice] chunk synth attempt \(attempt + 1)/\(maxAttempts + 1) failed: \(lastError?.localizedDescription ?? "?")")
            let backoff = VoiceOutputPlayer.synthRetryBackoff * Double(attempt + 1)
            // 不加 try?：backoff 睡眠期间被取消要直接抛出，不能吞掉继续重试。
            try await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
        }
        // Phase 2: split smaller and synthesize each piece.
        let small = VoiceOutputPlayer.splitText(text, maxChars: VoiceOutputPlayer.synthSplitChunkChars)
        guard small.count > 1 else { throw lastError ?? VoiceProviderError.parseError("chunk synth failed") }
        logger.info("[AIVoice] chunk still failing — retrying as \(small.count) smaller pieces")
        var pieces: [Data] = []
        for piece in small {
            if Task.isCancelled { throw CancellationError() }
            var ok = false
            for _ in 0...maxAttempts {
                do {
                    let d = try await synth(piece)
                    if !d.isEmpty { pieces.append(d); ok = true; break }
                    lastError = VoiceProviderError.noAudioData
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
                // 不加 try?：睡眠期间被取消要直接抛出，不能吞掉继续试下一个 piece。
                try await Task.sleep(nanoseconds: UInt64(VoiceOutputPlayer.synthRetryBackoff * 1e9))
            }
            guard ok else { throw lastError ?? VoiceProviderError.parseError("small-piece synth failed") }
        }
        return VoiceOutputPlayer.concatPieces(pieces)
    }

    /// [tts-groups 2026-10-02] 候选链：默认 TTS 分组成员（按分组顺序）→ 之前选中
    /// 的单个服务（兼容老配置）→ Voice Output 模型分组。没建分组时行为和以前
    /// 完全一致（选中服务 → 模型分组）。
    private static func synthesizeWithServiceOrGroup(_ text: String) async throws -> (Data, String?) {
        for service in ttsServiceCandidates() {
            if let result = try await synthesizeWithService(service, text) {
                return result
            }
        }
        for entry in VoiceProviderResolver.resolvedOutputCandidates() {
            guard let provider = VoiceProviderResolver.outputProvider(for: entry) else { continue }
            // [TTS-11] Group entries carry no vendor kind here — split at
            // the conservative shared limit (safe for every vendor).
            // 取消透传（不能 try? 吞掉），普通失败才 continue 试下一个。
            do {
                let data = try await synthesizeChunked(text, limit: 1000, { chunk in
                    try await provider.synthesize(VoiceOutputRequest(input: chunk, model: entry.model.id))
                })
                if !data.isEmpty {
                    logger.info("[AIVoice] synthesized via model-group entry \(entry.model.displayName)")
                    return (data, VoiceProviderResolver.isSystemEntry(entry.providerInstanceId) ? "wav" : "mp3")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw VoiceProviderError.parseError("all voice candidates failed")
    }

    /// 有序去重的 TTS 服务候选：默认分组成员优先，然后是选中的单个服务。
    private static func ttsServiceCandidates() -> [TTSServiceOptions] {
        var out: [TTSServiceOptions] = []
        var seen = Set<String>()
        for s in TTSGroupStore.shared.defaultGroupCandidates() where seen.insert(s.id).inserted {
            out.append(s)
        }
        let svcStore = TTSServiceStore.shared
        if let s = svcStore.selectedService(), s.enabled, seen.insert(s.id).inserted {
            out.append(s)
        }
        return out
    }

    /// 单个 TTS 服务合成一次。普通失败记 LOUD 日志并返回 nil（调用方继续下
    /// 一个候选）。[T-tts-key-status 09-13] 语义保留：选中的服务自己的失败必须
    /// 大声记原因（之前"有声但显示没 key"就是这里静默跳过导致的）。
    /// 取消是例外：CancellationError 直接抛出，不转 nil（否则调用方会继续试
    /// 下一个候选，最终报"合成失败"而非"已取消"，停止按钮形同虚设）。
    private static func synthesizeWithService(_ service: TTSServiceOptions, _ text: String) async throws -> (Data, String)? {
        let svcStore = TTSServiceStore.shared
        if !svcStore.hasAPIKey(for: service) {
            logger.warning("[AIVoice] TTS service '\(service.name)' has NO stored key — skipping (check the Keychain save in the service editor)")
            return nil
        }
        guard let provider = TTSProviderBridge.provider(for: service) else {
            logger.warning("[AIVoice] TTS service '\(service.name)' (\(service.kind.rawValue)) cannot synthesize — skipping")
            return nil
        }
        do {
            // [TTS-11] Split at THIS vendor's per-request limit before sending,
            // not after a failure.
            let data = try await synthesizeChunked(text, limit: service.kind.bubbleSynthesisCharLimit) { chunk in
                try await provider.synthesize(TTSProviderBridge.request(for: service, text: chunk))
            }
            if !data.isEmpty {
                logger.info("[AIVoice] synthesized via service '\(service.name)' (\(service.kind.rawValue))")
                return (data, service.kind == .azure ? "mp3" : "wav")
            }
            logger.warning("[AIVoice] service '\(service.name)' returned empty audio — trying next candidate")
        } catch is CancellationError {
            // 取消必须透传，不能吞成 nil（调用方靠 nil 决定"试下一个候选"，
            // 吞掉会导致"点了停止停不下来"，最后报"合成失败"而非"已取消"）。
            throw CancellationError()
        } catch {
            logger.warning("[AIVoice] service '\(service.name)' synth failed: \(error.localizedDescription) — trying next candidate")
        }
        return nil
    }
}
