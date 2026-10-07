import Foundation
import AVFoundation
import CryptoKit

// MARK: - Voice-output preference (persisted)

enum VoiceOutputPreferences {
    private static let key = "voice.output.readRepliesAloud"
    private static let speedKey = "voice.output.speedMultiplier"

    /// Whether agent replies should be read aloud via TTS.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The speed steps the floating speaker button cycles through.
    static let speedSteps: [Float] = [1.0, 1.25, 1.5, 2.0]

    /// Playback speed multiplier for read-replies TTS (applies to subsequently
    /// generated/queued utterances). Persisted so it survives across replies.
    static var speedMultiplier: Float {
        get {
            let v = UserDefaults.standard.object(forKey: speedKey) as? Float ?? 1.0
            return speedSteps.contains(v) ? v : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: speedKey) }
    }

    /// [T-kelivo-tts 09-10] Read-aloud text selection mode (kelivo-style):
    /// fullText = everything; quotedOnly = just quoted spans;
    /// withoutParentheses = drop (asides). Persisted.
    private static let selectionKey = "voice.output.selectionMode"
    static var selectionMode: VoiceTextSanitizer.SelectionMode {
        get { VoiceTextSanitizer.SelectionMode(rawValue: UserDefaults.standard.string(forKey: selectionKey) ?? "") ?? .fullText }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectionKey) }
    }

    private static let mutedKey = "voice.output.muted"

    /// [T-tts-services 09-11] kelivo-style "cache audio for replay": keep the
    /// files a network service synthesized so replaying the same unit doesn't
    /// re-hit the vendor. Persisted; default on (audio is small and private).
    private static let cacheKey = "voice.output.cacheNetworkAudio"
    static var cacheNetworkAudio: Bool {
        get {
            if UserDefaults.standard.object(forKey: cacheKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: cacheKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: cacheKey) }
    }

    // [T-tts-first-use-nudge 09-13] N2: one-time guidance card on the FIRST
    // read-aloud enable. Users who never opened Settings → Voice hear the
    // robotic system voice and never learn the service layer exists. The
    // card fires once per install (skipped entirely when a TTS service is
    // already configured — they don't need it).
    private static let firstUseNudgeKey = "voice.output.firstUseNudgeShown"
    /// True when the nudge has NOT been shown yet AND no service is configured.
    static var shouldShowFirstUseNudge: Bool {
        guard !UserDefaults.standard.bool(forKey: firstUseNudgeKey) else { return false }
        return TTSServiceStore.shared.services.isEmpty
    }
    /// Mark the nudge as shown (call whether the card was tapped or dismissed).
    static func markFirstUseNudgeShown() {
        UserDefaults.standard.set(true, forKey: firstUseNudgeKey)
    }

    /// Whether read-replies is temporarily muted (persisted so it survives restart).
    static var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }

    /// [T-capsule-visibility 09-12] 醒醒 1：「语音悬浮胶囊，自己会消失，要么…
    /// 或者其他功能都放到'•••'里。」Master visibility switch for the floating
    /// speech capsule, surfaced in the chat "•••" menu. When OFF the capsule never
    /// renders (even mid-playback — pause/stop stay available from the message
    /// action bar); read-aloud audio itself keeps working. Persisted.
    private static let capsuleVisibleKey = "voice.output.capsuleVisible"
    static var capsuleVisible: Bool {
        get {
            // Default ON: existing users see no change.
            if UserDefaults.standard.object(forKey: capsuleVisibleKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: capsuleVisibleKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: capsuleVisibleKey) }
    }

    /// [T-system-voice-off 09-12] 醒醒 3：「把里面的系统语音全变成可关闭选项，
    /// 不然ai老用那个系统语音，很难听，改成我自定义的语音分组我这边自己配置的。」
    /// When OFF (the default), the read-aloud chain refuses the built-in
    /// System AVSpeechSynthesizer voice: only the user's TTS service / voice
    /// group speaks, and nothing speaks when they're unusable. Set ON only by
    /// someone who explicitly wants the robot voice back.
    private static let systemVoiceAllowedKey = "voice.output.systemVoiceAllowed"
    static var systemVoiceAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: systemVoiceAllowedKey) }
        set { UserDefaults.standard.set(newValue, forKey: systemVoiceAllowedKey) }
    }

    private static let offXKey = "voiceCapsule.anchorOffset.dx"
    private static let offYKey = "voiceCapsule.anchorOffset.dy"

    /// Last dragged offset of the floating capsule RELATIVE to its default
    /// bottom-trailing resting corner. Window-size independent: the capsule
    /// keeps its distance from the anchor corner across rotation / iPad Stage
    /// Manager window resizes. (The previous scheme persisted an ABSOLUTE
    /// window-coordinate center, which landed mid-content once the window
    /// shrank.) nil = never dragged → default resting corner.
    static var capsuleAnchorOffset: CGSize? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: offXKey) != nil, d.object(forKey: offYKey) != nil else { return nil }
            return CGSize(width: d.double(forKey: offXKey), height: d.double(forKey: offYKey))
        }
        set {
            let d = UserDefaults.standard
            if let o = newValue {
                d.set(Double(o.width), forKey: offXKey)
                d.set(Double(o.height), forKey: offYKey)
            } else {
                d.removeObject(forKey: offXKey)
                d.removeObject(forKey: offYKey)
            }
        }
    }
}

// MARK: - VoiceOutputPlayer
//
// Ordered, streaming TTS queue for reading replies aloud with a CONFIGURED cloud
// voice model (Groq/MiniMax/Doubao/…). Text units (sentences / titles / tool
// announcements) are enqueued in order; audio is generated ahead of time
// (pipelined, up to `maxPrefetch` concurrent synthesize requests) but PLAYED
// strictly in enqueue order, so playback stays gapless and correctly sequenced.
//
// The offline System provider is NOT handled here — the AIChatViewModel keeps its
// existing AVSpeechSynthesizer path for System (it already carries voice/rate/
// pitch/volume + background keep-alive). This player is the cloud-model path.

@MainActor
final class VoiceOutputPlayer: NSObject, ObservableObject {

    static let shared = VoiceOutputPlayer()

    @Published private(set) var isPlaying = false
    /// [T-kelivo-tts 09-10] Playback progress of the CURRENT unit (0...1) for
    /// the floating control's scrubber, plus the wall-clock times behind it.
    @Published private(set) var playbackProgress: Double = 0
    @Published private(set) var playbackPosition: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    /// True while a cloud TTS network synthesis is in flight with nothing yet
    /// playing — drives the "…" loading animation on the speaker control so the
    /// user knows audio is being generated (not stuck).
    @Published private(set) var isSynthesizing = false
    /// Display name of the model that LAST successfully synthesized — set when a
    /// fail-over picks a different group member, so the speech control's capsule
    /// can show the model that's actually producing audio. nil = use the resolved
    /// default label.
    @Published private(set) var activeModelLabel: String?
    /// Bumped each time a unit fully fails (all candidates exhausted) — the speech
    /// control observes it to flash the speaker icon red for a few seconds.
    @Published private(set) var synthFailureTick = 0

    /// One ordered fail-over candidate.
    struct Candidate {
        let key: String          // ModelEntry.id / service id (stable identity for stickiness)
        let label: String
        let provider: any VoiceOutputCapable
        /// [T-tts-services 09-11] Builds the synthesis request for a text unit.
        /// The legacy Model-Group path emits a bare `VoiceOutputRequest(input:
        /// model:)`; the TTS service path folds in the vendor's voice id and
        /// tuning knobs. Keeping this per-candidate means the two layers never
        /// have to agree on a shared parameter shape.
        let makeRequest: (String) -> VoiceOutputRequest
    }
    /// STICKY cursor: the ModelEntry.id we're currently synthesizing with. Persists
    /// across units (and the whole reply) until that model fails, then advances.
    private var stickyCandidateKey: String?

    /// Recompute `isSynthesizing`: a unit is generating (task running, no audio
    /// yet) AND nothing is currently playing (so it reads as "loading", not as a
    /// background prefetch behind active playback).
    private func refreshSynthesizingState() {
        let generating = queue.contains { $0.task != nil && $0.audio == nil && !$0.failed }
        let next = generating && player == nil
        if next != isSynthesizing { isSynthesizing = next }
    }

    private let logger = AppLogger(category: "VoiceOutput")
    private var player: AVAudioPlayer?

    /// One queued unit: its order index, source text, and (once generated) audio.
    /// `ownerSessionId` records which chat session (or manual read-aloud source)
    /// enqueued it, so `stopSession` can clear ONE session's units without
    /// touching other concurrent sessions' queued speech.
    private final class Unit {
        let seq: Int
        let text: String
        let ownerSessionId: String
        var audio: Data?          // nil until synthesize completes
        var failed = false        // synthesize errored → skip on playback
        var task: Task<Void, Never>?
        init(seq: Int, text: String, ownerSessionId: String) {
            self.seq = seq; self.text = text; self.ownerSessionId = ownerSessionId
        }
    }

    private var queue: [Unit] = []      // pending + generating, in order
    private var nextSeq = 0
    private var playingSeq = -1         // seq currently playing (-1 = idle)
    /// Owner session of the unit currently playing (nil = idle).
    private var playingSessionId: String?
    /// The unit currently playing. pumpPlayback REMOVES it from `queue` when
    /// playback starts, so without this reference its text is unrecoverable —
    /// stopAll(collectRemainder:) used to search `queue` by playingSeq and
    /// always miss, silently dropping the playing sentence on a voice switch.
    private var playingUnit: Unit?

    /// [TTS-10] Read hooks for the Now Playing extension in
    /// VoiceNowPlaying.swift. `player` / `playingUnit` stay private to this
    /// file (and `Unit` is a private nested type), so the cross-file
    /// extension reads playback state through these instead of touching
    /// the private storage directly.
    var nowPlayingHasLivePlayer: Bool { player != nil }
    var nowPlayingUnitText: String? { playingUnit?.text }

    /// Owner id used by non-session read-aloud entry points (long-press menu,
    /// markdown preview) — never collides with a real session id.
    static let manualOwnerId = "__manual__"

    // MARK: - Dynamic TTS window measurement
    // Exponentially-smoothed estimates from completed synth+play cycles, used to
    // recommend how many characters the next batch should accumulate so audio
    // never under-runs (next batch's audio ≥ time to synthesize it) but batches
    // aren't so large they risk a synth timeout.
    /// Seconds of AUDIO produced per source character (e.g. ~0.18 s/char for CJK).
    private var secPerChar: Double = 0.18
    /// Seconds of SYNTHESIS time per source character (network + model).
    private var synthSecPerChar: Double = 0.05
    /// Fixed synthesis latency per request (s) — connection + model warmup.
    private var synthLatency: Double = 0.6
    /// Safety factor (<1) applied to the computed minimum so accumulation stays
    /// slightly ahead of consumption instead of exactly matching it.
    private static let windowSafety: Double = 0.8
    /// Hard ceiling on a single batch's character count (avoid synth timeouts).
    static let maxBatchChars = 220
    /// Floor so we never recommend a uselessly tiny batch.
    static let minBatchChars = 8
    /// Retry the SAME text this many times before falling back to splitting it.
    static let synthRetriesSameText = 2
    /// Backoff between retries (seconds), grows per attempt.
    static let synthRetryBackoff = 0.4
    /// Sub-chunk size when a too-long / rejected batch is split for a final retry.
    static let synthSplitChunkChars = 60
    /// Max concurrent synthesize requests running ahead of playback.
    private static let maxPrefetch = 2

    // MARK: - Dynamic window

    /// Update the smoothed per-char audio / synth estimates from one cycle.
    private func recordSynthMetrics(chars: Int, synthTime: Double, wav: Data) {
        guard chars > 0 else { return }
        let audioDur = Self.wavDuration(wav)
        guard audioDur > 0.05, synthTime > 0.01 else { return }
        let a = 0.3   // smoothing
        secPerChar      += (audioDur / Double(chars)  - secPerChar)      * a
        synthSecPerChar += (synthTime / Double(chars) - synthSecPerChar) * a
        // Latency ≈ synthTime minus the per-char portion (floored at 0).
        let perCharPart = synthSecPerChar * Double(chars)
        synthLatency    += (max(0, synthTime - perCharPart) - synthLatency) * a
    }

    /// How many seconds of generated-but-not-yet-played audio are buffered now
    /// (the front unit's remaining time + all ready units behind it).
    private var bufferedAudioSeconds: Double {
        var total = 0.0
        if let p = player { total += max(0, p.duration - p.currentTime) }
        for u in queue where u.audio != nil && !u.failed {
            total += Self.wavDuration(u.audio!)
        }
        return total
    }

    /// Recommended minimum characters for the NEXT batch so audio doesn't
    /// under-run. Base requirement (no buffer): enough chars that the batch's
    /// audio duration covers the time to synthesize it —
    ///   N·secPerChar ≥ synthLatency + N·synthSecPerChar
    ///   ⇒ N ≥ synthLatency / (secPerChar − synthSecPerChar)
    /// Then ×0.8 (don't over-accumulate). When there's ALREADY buffered audio
    /// (mid/late reply), we can afford to wait for a LONGER, more coherent batch —
    /// grow the minimum proportionally to the buffer, capped at maxBatchChars.
    var recommendedMinChars: Int {
        let denom = max(0.02, secPerChar - synthSecPerChar)
        let base = (synthLatency / denom) * Self.windowSafety
        // Buffer headroom in seconds → extra chars we can wait to coalesce.
        let headroomChars = (bufferedAudioSeconds / max(0.01, secPerChar)) * Self.windowSafety
        let n = Int((base + headroomChars).rounded())
        return max(Self.minBatchChars, min(Self.maxBatchChars, n))
    }

    /// Whether the queue currently has any audio playing/ready (used by the caller
    /// to apply the "speak the first batch ASAP" rule when idle).
    var hasPendingAudio: Bool {
        player != nil || queue.contains { $0.audio != nil && !$0.failed }
    }

    private static func wavDuration(_ wav: Data) -> Double {
        // [T-tts-vendor-fix 09-13] Sniff a real RIFF/WAVE header before reading
        // the header fields — mp3/ogg payloads put frame data where the WAV
        // byteRate sits (offset 28), so the old blind read produced garbage
        // durations that poisoned the smoothed secPerChar window (audit #7).
        guard wav.count > 44 else { return 0 }
        // RIFF magic at 0, WAVE magic at 8 — Data has no starts(with:at:),
        // so compare the WAVE tag bytes directly.
        guard wav.starts(with: Array("RIFF".utf8)),
              [UInt8](wav.dropFirst(8).prefix(4)) == Array("WAVE".utf8)
        else { return 0 }
        let byteRate = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
        let rate = UInt32(littleEndian: byteRate)
        guard rate > 0 else { return 0 }
        return Double(wav.count - 44) / Double(rate)
    }

    /// [T-ai-voice-messages 09-12] Public facade over `wavDuration` for the
    /// voice-message composer (duration label + bubble metadata). Returns 0
    /// for non-WAV bytes (mp3) — callers treat 0 as "unknown, resolve lazily".
    static func wavDurationOf(_ wav: Data) -> Double {
        wavDuration(wav)
    }

    // MARK: - Public API

    /// Enqueue a text unit to be read aloud via the configured cloud TTS model.
    /// No-op when read-aloud is off or the text is blank. Order is preserved.
    /// `sessionId` tags the unit's owner so `stopSession` can clear one
    /// session's speech without touching concurrent sessions'.
    func enqueue(_ text: String, sessionId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceOutputPreferences.isEnabled, !trimmed.isEmpty else { return }

        let unit = Unit(seq: nextSeq, text: trimmed, ownerSessionId: sessionId); nextSeq += 1
        queue.append(unit)
        VoiceLog.log(String(format: "TTS enqueue #%d owner=%@ chars=%d queue=%d buffered=%.2fs est[sec/ch=%.3f synth/ch=%.3f lat=%.2f minChars=%d] \"%@\"",
            unit.seq, String(sessionId.prefix(8)), trimmed.count, queue.count, bufferedAudioSeconds,
            secPerChar, synthSecPerChar, synthLatency, recommendedMinChars,
            String(trimmed.prefix(30))))
        pumpPrefetch()
        pumpPlayback()
    }

    /// Sanitize, split into speech-sized segments using the streaming segmenter,
    /// and enqueue each segment. Used by long-press "Read Aloud" / markdown
    /// preview / "Read Selected" — same splitting as live streaming TTS.
    /// Non-session callers pass `VoiceOutputPlayer.manualOwnerId`.
    func enqueueSegmented(_ rawText: String, sessionId: String) {
        let sanitized = VoiceTextSanitizer.sanitize(rawText, mode: VoiceOutputPreferences.selectionMode)
        guard !sanitized.isEmpty else { return }
        let segments = AIChatViewModel.splitIntoSpeechSegments(sanitized)
        for s in segments { enqueue(s, sessionId: sessionId) }
    }

    /// Stop everything: cancel in-flight synth, clear the queue, stop playback.
    ///
    /// [T-tts-services 09-11] `restart` support: when a voice change arrives
    /// mid-read, the caller can ask for the not-yet-played remainder back so it
    /// can re-enqueue it through the NEW voice (kelivo restarts playback; letting
    /// the old audio finish would read the old voice for several more seconds
    /// and defeat the point of switching).
    @discardableResult
    func stopAll(collectRemainder: Bool = false) -> (text: String, sessionId: String)? {
        var remainder: (String, String)?
        if collectRemainder {
            // The currently-playing unit (partially heard) + every queued unit
            // that never played, in order. The partially-heard unit is included
            // WHOLE — restarting mid-sentence would splice two voices at an
            // arbitrary point, which sounds worse than re-hearing a few words.
            // Units that already synthesized but haven't played yet are ALSO
            // included: their audio was made with the OLD voice, so replaying it
            // would violate the switch.
            var texts: [String] = []
            var owner: String?
            if let playing = playingUnit {
                texts.append(playing.text)
                owner = playing.ownerSessionId
            }
            for u in queue where u.seq != playingSeq && !u.failed {
                texts.append(u.text)
                owner = owner ?? u.ownerSessionId
            }
            let joined = texts.joined(separator: "\n")
            if !joined.isEmpty {
                remainder = (joined, owner ?? VoiceOutputPlayer.manualOwnerId)
            }
        }
        for u in queue { u.task?.cancel() }
        queue.removeAll()
        player?.stop()
        player = nil
        stopProgressTick(reset: true)
        playingSeq = -1
        playingSessionId = nil
        playingUnit = nil
        isPlaying = false
        isPaused = false
        isSynthesizing = false
        releaseSessionIfSafe()
        VoiceNowPlaying.shared.refresh()
        return remainder
    }

    /// Clear ONE session's queued/synthesizing units. If the currently-playing
    /// unit belongs to that session, stop it and continue with the next unit
    /// from other sessions. Units owned by other sessions are untouched — this
    /// is what lets multiple concurrent chats share the queue without a new
    /// reply in one chat wiping another chat's pending speech.
    func stopSession(_ sessionId: String) {
        let owned = queue.filter { $0.ownerSessionId == sessionId }
        guard !owned.isEmpty || playingSessionId == sessionId else { return }
        for u in owned { u.task?.cancel() }
        queue.removeAll { $0.ownerSessionId == sessionId }
        VoiceLog.log("TTS stopSession owner=\(String(sessionId.prefix(8))) cleared=\(owned.count) remaining=\(queue.count) playingWasOurs=\(playingSessionId == sessionId)")
        if playingSessionId == sessionId {
            player?.stop()
            player = nil
            playingSeq = -1
            playingSessionId = nil
            playingUnit = nil
            isPaused = false
            pumpPlayback()   // continue with other sessions' queued content
        }
        refreshSynthesizingState()
        if queue.isEmpty && player == nil {
            isPlaying = false
            releaseSessionIfSafe()
        }
    }

    /// Clear the sticky fail-over cursor + active-model label. Call when the user
    /// MANUALLY changes the voice output selection so the capsule reflects the new
    /// choice instead of a stale failed-over model.
    func resetActiveModel() {
        stickyCandidateKey = nil
        activeModelLabel = nil
    }

    @Published private(set) var isPaused = false

    /// Apply a new playback rate to the CURRENTLY-playing cloud audio immediately
    /// (real-time speed change). New units pick it up from VoiceOutputPreferences.
    func setRate(_ rate: Float) {
        player?.enableRate = true
        player?.rate = rate
    }

    /// Pause the currently-playing cloud audio (queue keeps filling in background).
    /// Sets `isPaused` even when there's no live `player` yet — an external
    /// recording can silence/stop our AVAudioPlayer BEFORE the pause signal
    /// arrives, and we still need `isPaused` latched so `pumpPlayback` won't
    /// start the next queued unit under the recorder, and so `resume()` knows to
    /// pick the queue back up. Playback stays gated on `!isPaused` in
    /// `pumpPlayback`.
    func pause() {
        if let p = player, p.isPlaying { p.pause() }
        isPaused = true
        stopProgressTick(reset: false)
        VoiceNowPlaying.shared.refresh()
    }

    /// Resume paused cloud audio. Resumes the live player if one is paused, and
    /// ALWAYS kicks the pump so a queue that drained its player while paused
    /// (external recording stopped our AVAudioPlayer) starts its next unit.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let p = player {
            p.play()
            startProgressTick()
        } else { pumpPlayback() }
        VoiceNowPlaying.shared.refresh()
    }

    /// The cloud TTS queue has drained — end the reply-TTS intent. The coordinator
    /// then re-applies the next-highest intent's profile (e.g. capture, keep-alive)
    /// or deactivates the session. No need to guard on capture here: the coordinator
    /// won't deactivate a session a higher-priority intent still owns.
    private func releaseSessionIfSafe() {
        AudioSessionCoordinator.shared.end(.replyTTS)
    }

    // MARK: - Pipeline

    /// Start synthesize for the earliest not-yet-generated units, up to maxPrefetch.
    private func pumpPrefetch() {
        let inFlight = queue.filter { $0.task != nil && $0.audio == nil && !$0.failed }.count
        var slots = Self.maxPrefetch - inFlight
        guard slots > 0 else { return }

        // [T-tts-services 09-11] Independent TTS service layer takes precedence
        // when the user has one selected. This is the kelivo-style path: the
        // service carries its own vendor/baseURL/key/model/voice + tuning knobs,
        // so it is a complete synthesis target on its own — no Model Group
        // needed. Falls through to the legacy group candidates when no service
        // is selected, or when the selected one can't build a provider (missing
        // credential, vendor without TTS), so an existing setup never breaks.
        var candidates: [Candidate] = Self.resolvedServiceCandidates()

        if candidates.isEmpty {
            candidates = VoiceProviderResolver.resolvedOutputCandidates().compactMap { entry -> Candidate? in
                guard let p = VoiceProviderResolver.outputProvider(for: entry) else { return nil }
                return Candidate(key: entry.id,
                                 label: entry.model.displayName,
                                 provider: p,
                                 makeRequest: { VoiceOutputRequest(input: $0, model: entry.model.id) })
            }
        }
        guard !candidates.isEmpty else {
            // [T-system-voice-off 09-12] Zero usable targets: with the System
            // voice switch OFF (default) there is NOTHING to synthesize with —
            // drain the queue silently and log the gap once per window so the
            // failure is diagnosable from the device log. (With the switch ON,
            // a zero-candidate group is a misconfiguration; same drain — the
            // alternative is retry-looping units forever.)
            VoiceLog.log("TTS pumpPrefetch: no usable candidates — draining \(queue.count) unit(s)")
            for i in queue.indices {
                queue[i].failed = true
                queue[i].task = nil
            }
            synthFailureTick &+= 1
            pumpPlayback()   // skip-and-drain so isPlaying/UI settle promptly
            refreshSynthesizingState()
            // [T-system-voice-off 09-12] Tell the reading VM to settle its
            // isReadingAloud state — nothing will ever play, so the capsule
            // must not hang on "reading" (修复审查问题4).
            NotificationCenter.default.post(name: .ttsQueueDrainedSilently, object: nil)
            return
        }
        // STICKY fail-over (mirrors the agent loop): once we've moved to a model,
        // keep using it for subsequent units — only advance when IT fails. We
        // realize this by moving the currently-active candidate to the FRONT, so
        // synthWithFailover tries it first and only walks forward on its failure.
        if let active = stickyCandidateKey,
           let i = candidates.firstIndex(where: { $0.key == active }), i > 0 {
            let c = candidates.remove(at: i)
            candidates.insert(c, at: 0)
        }
        // Drop a stale active label if the active model is no longer a candidate.
        if let active = stickyCandidateKey, !candidates.contains(where: { $0.key == active }) {
            stickyCandidateKey = nil
            activeModelLabel = nil
        }

        for unit in queue where unit.task == nil && unit.audio == nil && !unit.failed {
            guard slots > 0 else { break }
            slots -= 1
            let charCount = unit.text.count
            let seq = unit.seq
            unit.task = Task { [weak self] in
                guard let self else { return }
                let t0 = DispatchTime.now()
                do {
                    // [T-tts-vendor-fix 09-13] Cache hit path (kelivo's
                    // cacheNetworkAudioForReplay): when caching is ON and this
                    // exact text was already synthesized by this exact
                    // candidate, reuse the bytes — replay costs nothing.
                    var data: Data?
                    var used: Candidate?
                    if let cached = self.cachedAudio(for: unit.text, candidates: candidates) {
                        data = cached.data
                        used = cached.candidate
                        VoiceLog.log("TTS cache hit #\(seq)")
                    }
                    if data == nil {
                        // Synthesize at 1× always; speed is applied at PLAYBACK via
                        // AVAudioPlayer.rate. Fails over across group models: each model
                        // gets same-text retries + a split fallback before the next.
                        let (d, u) = try await Self.synthWithFailover(
                            text: unit.text, candidates: candidates, seq: seq)
                        data = d; used = u
                        self.storeCachedAudio(text: unit.text, candidate: u, audio: d)
                    }
                    guard let audio = data, let chosen = used else { return }
                    if Task.isCancelled { return }
                    let synthTime = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
                    await MainActor.run {
                        unit.audio = audio
                        // Stick to the model that just worked; surface it on the capsule.
                        if self.stickyCandidateKey != chosen.key {
                            self.stickyCandidateKey = chosen.key
                            self.activeModelLabel = chosen.label
                            VoiceLog.log("TTS active model → \(chosen.label)")
                        }
                        self.recordSynthMetrics(chars: charCount, synthTime: synthTime, wav: audio)
                        VoiceLog.log("TTS synth done #\(seq): \(audio.count) bytes in \(String(format: "%.2f", synthTime))s")
                        self.pumpPlayback()
                        self.pumpPrefetch()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        // All retries + split fallback exhausted — give up on THIS
                        // unit (mark failed so playback skips it and continues with
                        // the next), and tell the user some content can't be read.
                        unit.failed = true
                        self.synthFailureTick &+= 1   // flash the control red
                        self.logger.error("TTS synth failed #\(seq): \(error.localizedDescription)")
                        VoiceLog.log("TTS synth FAILED #\(seq) after all retries + split: \(error.localizedDescription)")
                        DuduToast.show(AppLocalized("Voice synthesis failed — some content may not be read aloud."),
                                        systemImage: "exclamationmark.triangle.fill")
                        self.pumpPlayback()
                        self.pumpPrefetch()
                    }
                }
            }
        }
        refreshSynthesizingState()
    }

    // MARK: - Synthesis cache (kelivo cacheNetworkAudioForReplay)
    //
    // [T-tts-vendor-fix 09-13] In-memory LRU keyed by (candidate key, text).
    // Replaying the same reply (or re-reading the same sentence) skips the
    // vendor call entirely. Cleared when the switch turns OFF. Bounded so a
    // long reading session can't grow it without limit.
    //
    // [TTS-7] Two levels now: the memory LRU in front of TTSDiskCache, so
    // replays survive relaunch. Both levels share ONE key — a SHA-256
    // fingerprint over candidate + model + voice + speed + format +
    // tuning extras + text, built from the candidate's actual request.
    // (The old key used `text.hashValue`, which is randomized per launch
    // and ignores tuning: change the speed and the stale audio still hit.)

    private static let synthCacheLimit = 64
    private var synthCache: [String: (data: Data, candidateKey: String)] = [:]
    private var synthCacheOrder: [String] = []

    private func cacheKey(text: String, candidate: Candidate) -> String {
        let req = candidate.makeRequest(text)
        var parts: [String] = [
            candidate.key,
            req.model ?? "",
            req.voice ?? "",
            req.speed.map { String(format: "%.3f", Double($0)) } ?? "",
            req.responseFormat.rawValue,
        ]
        for k in req.extras.keys.sorted() { parts.append("\(k)=\(req.extras[k] ?? "")") }
        parts.append(text)
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Find cached audio for this text among the given candidates (sticky
    /// candidate first — it's been moved to the front by the caller).
    /// Memory first, then disk (a disk hit refills the memory level).
    private func cachedAudio(for text: String, candidates: [Candidate]) -> (data: Data, candidate: Candidate)? {
        guard VoiceOutputPreferences.cacheNetworkAudio else { return nil }
        for c in candidates {
            let k = cacheKey(text: text, candidate: c)
            if let hit = synthCache[k] {
                return (hit.data, c)
            }
            if let disk = TTSDiskCache.load(key: k) {
                synthCache[k] = (disk, c.key)
                synthCacheOrder.append(k)
                return (disk, c)
            }
        }
        return nil
    }

    private func storeCachedAudio(text: String, candidate: Candidate, audio: Data) {
        guard VoiceOutputPreferences.cacheNetworkAudio, !audio.isEmpty else { return }
        let k = cacheKey(text: text, candidate: candidate)
        if synthCache[k] != nil {
            if let i = synthCacheOrder.firstIndex(of: k) { synthCacheOrder.remove(at: i) }
        }
        synthCache[k] = (audio, candidate.key)
        synthCacheOrder.append(k)
        while synthCacheOrder.count > Self.synthCacheLimit {
            let oldest = synthCacheOrder.removeFirst()
            synthCache.removeValue(forKey: oldest)
        }
        TTSDiskCache.store(key: k, data: audio)
    }

    // MARK: - Synthesis with retry / split fallback

    /// [T-tts-services 09-11] Candidate from the independent TTS service layer.
    /// Services are explicit choices, not an invisible cross-vendor fallback:
    /// if none is selected and usable, the normal Model-Group/System path below
    /// remains authoritative.
    /// A service layer has explicit selection semantics: only the selected,
    /// enabled, credentialed service may replace the Model Group/System route.
    /// Enabled services are *saved options*, not invisible fail-over targets —
    /// otherwise an old half-configured entry can steal every System utterance
    /// and turn a tap into a silent network failure.
    @MainActor
    private static func resolvedServiceCandidates() -> [Candidate] {
        let store = TTSServiceStore.shared
        guard let service = store.selectedService(),
              service.enabled,
              store.hasAPIKey(for: service),
              let provider = TTSProviderBridge.provider(for: service) else { return [] }
        return [Candidate(
            key: "tts-service:\(service.id)",
            label: "\(service.name) · \(service.voice)",
            provider: provider,
            makeRequest: { text in TTSProviderBridge.request(for: service, text: text) }
        )]
    }

    /// Fail over across Model-Group TTS candidates: try each model's
    /// `synthWithRetry` (same-text retries + split) in order; return the first
    /// success. Throws only when EVERY candidate has been exhausted — that's the
    /// only case the caller surfaces a failure toast to the user.
    nonisolated private static func synthWithFailover(
        text: String, candidates: [Candidate], seq: Int
    ) async throws -> (Data, Candidate) {
        var lastError: Error?
        for (i, c) in candidates.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            do {
                let data = try await synthWithRetry(text: text, candidate: c, seq: seq)
                if i > 0 { VoiceLog.log("TTS #\(seq): succeeded on fail-over model \(i + 1)/\(candidates.count) (\(c.label))") }
                return (data, c)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if i + 1 < candidates.count {
                    VoiceLog.log("TTS #\(seq): model \(i + 1)/\(candidates.count) (\(c.label)) failed — failing over to next")
                }
            }
        }
        throw lastError ?? VoiceProviderError.parseError("All TTS candidates failed")
    }

    /// Synthesize `text`, retrying the SAME text `synthRetriesSameText` times with
    /// backoff; if it still fails, SPLIT the text into smaller sentence chunks and
    /// synthesize+concatenate those (a too-long / partially-rejected batch often
    /// succeeds in smaller pieces). Throws only if even the split fallback fails.
    ///
    /// [T-tts-services 09-11] Takes the whole `Candidate` (not a bare model id)
    /// so the request is built by `candidate.makeRequest` — that is what lets
    /// the service layer carry voice id + tuning knobs while the legacy
    /// Model-Group path keeps sending exactly what it sent before.
    nonisolated private static func synthWithRetry(
        text: String, candidate: Candidate, seq: Int
    ) async throws -> Data {
        let provider = candidate.provider
        var lastError: Error?
        // Phase 1: retry the same text.
        for attempt in 0...synthRetriesSameText {
            if Task.isCancelled { throw CancellationError() }
            do {
                return try await provider.synthesize(candidate.makeRequest(text))
            } catch {
                lastError = error
                VoiceLog.log("TTS synth retry #\(seq) attempt \(attempt + 1)/\(synthRetriesSameText + 1) failed: \(error.localizedDescription)")
                let backoff = synthRetryBackoff * Double(attempt + 1)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
            }
        }
        // Phase 2: split into smaller chunks and synthesize each, then concatenate.
        let chunks = splitForRetry(text)
        guard chunks.count > 1 else { throw lastError ?? VoiceProviderError.parseError("synth failed") }
        VoiceLog.log("TTS synth #\(seq): retrying as \(chunks.count) smaller chunks")
        var pieces: [Data] = []
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            var ok = false
            for attempt in 0...synthRetriesSameText {
                do {
                    let d = try await provider.synthesize(candidate.makeRequest(chunk))
                    pieces.append(d); ok = true; break
                } catch {
                    lastError = error
                    VoiceLog.log("TTS synth #\(seq) chunk \(i + 1)/\(chunks.count) attempt \(attempt + 1) failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(synthRetryBackoff * 1e9))
                }
            }
            guard ok else { throw lastError ?? VoiceProviderError.parseError("chunk synth failed") }
        }
        return concatPieces(pieces)
    }

    /// Split text into ≤`synthSplitChunkChars` chunks on sentence/pause boundaries.
    nonisolated private static func splitForRetry(_ text: String) -> [String] {
        splitText(text, maxChars: synthSplitChunkChars)
    }

    /// [TTS-11] The sentence-boundary splitter, generalized: chunks of at
    /// most `maxChars`, cut only at sentence/pause punctuation once the
    /// running chunk reaches the cap. Shared by the read-aloud retry path
    /// and the voice-bubble composer (which splits UP FRONT at the
    /// vendor's per-request character limit instead of failing whole).
    nonisolated static func splitText(_ text: String, maxChars: Int) -> [String] {
        let enders: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";", "，", ",", "、", "\n"]
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if cur.count >= maxChars && enders.contains(ch) {
                out.append(cur); cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out.isEmpty ? [text] : out
    }

    /// Join synthesized pieces into one playable blob. Only genuine WAV
    /// pieces may go through the header surgery in `concatWav` — the default
    /// request format is MP3, and stripping 44 "header" bytes off MP3 frames
    /// corrupts the audio. Frame-based formats (mp3/opus/aac) join correctly
    /// by plain concatenation. Sniff the actual bytes rather than trusting
    /// the requested format, so a vendor that ignores the request can't
    /// corrupt the join.
    /// [TTS-11] Internal (was private) so the voice-bubble composer joins
    /// its per-limit chunks with the exact same rules.
    nonisolated static func concatPieces(_ pieces: [Data]) -> Data {
        guard let first = pieces.first else { return Data() }
        guard pieces.count > 1 else { return first }
        if isWAV(first) { return concatWav(pieces) }
        var out = Data()
        for p in pieces { out.append(p) }
        return out
    }

    nonisolated private static func isWAV(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.subdata(in: 0..<4) == Data("RIFF".utf8)
            && data.subdata(in: 8..<12) == Data("WAVE".utf8)
    }

    /// Concatenate multiple WAV blobs into one (uses the first header, sums data).
    /// Assumes identical format (same model → same 24 kHz/16-bit mono).
    nonisolated private static func concatWav(_ wavs: [Data]) -> Data {
        guard let first = wavs.first else { return Data() }
        guard wavs.count > 1 else { return first }
        var pcm = Data()
        for w in wavs where w.count > 44 { pcm.append(w.subdata(in: 44..<w.count)) }
        var out = first.subdata(in: 0..<44)   // reuse header, then fix sizes
        let dataSize = UInt32(pcm.count).littleEndian
        let riffSize = UInt32(36 + pcm.count).littleEndian
        out.replaceSubrange(4..<8, with: withUnsafeBytes(of: riffSize) { Data($0) })
        out.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize) { Data($0) })
        out.append(pcm)
        return out
    }

    /// Play the front unit if it's ready and nothing is currently playing.
    private func pumpPlayback() {
        // Honor an external-audio pause: while paused (e.g. another app is
        // recording) we must NOT start the next queued unit, even though there
        // is no live `player` — otherwise a unit whose synthesis completes
        // mid-recording would start playing under the recorder. `resume()`
        // re-enters here when the pause lifts.
        guard !isPaused else { return }
        guard player == nil else { return }            // already playing
        guard let front = queue.first else {           // queue drained
            if isPlaying { isPlaying = false }
            return
        }
        // Skip a failed front unit.
        if front.failed {
            queue.removeFirst()
            pumpPlayback()
            return
        }
        guard let audio = front.audio else { return }  // front not generated yet

        queue.removeFirst()
        playingSeq = front.seq
        playingSessionId = front.ownerSessionId
        playingUnit = front
        do {
            try activatePlaybackSession()
            let p = try AVAudioPlayer(data: audio)
            p.delegate = self
            // Real-time variable speed: rate is applied at PLAYBACK (not synthesis),
            // so changing speed takes effect on the CURRENTLY-playing audio.
            p.enableRate = true
            p.rate = VoiceOutputPreferences.speedMultiplier
            p.prepareToPlay()
            p.play()
            player = p
            isPlaying = true
            VoiceNowPlaying.shared.refresh()
            // [T-kelivo-tts 09-10] Progress tick for the floating control's
            // scrubber (0.1s cadence — kelivo's floating player updates at
            // frame rate but a tenth-second is plenty for a 40pt-wide bar).
            startProgressTick()
            VoiceLog.log(String(format: "TTS ▶︎ play #%d owner=%@ dur=%.2fs rate=%.2f queueAhead=%d bufferedAfter=%.2fs",
                front.seq, String(front.ownerSessionId.prefix(8)), p.duration, p.rate, queue.count, bufferedAudioSeconds))
        } catch {
            logger.error("TTS play failed #\(front.seq): \(error.localizedDescription)")
            playingSeq = -1
            playingSessionId = nil
            playingUnit = nil
            pumpPlayback()                              // try next
        }
        pumpPrefetch()
    }

    // MARK: - [T-kelivo-tts] Playback progress tick

    private var progressTick: Task<Void, Never>?

    private func startProgressTick() {
        progressTick?.cancel()
        playbackProgress = 0
        playbackPosition = 0
        playbackDuration = player?.duration ?? 0
        progressTick = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, let p = self.player {
                self.playbackPosition = p.currentTime
                let d = p.duration
                self.playbackDuration = d
                self.playbackProgress = d > 0 ? min(1, p.currentTime / d) : 0
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopProgressTick(reset: Bool) {
        progressTick?.cancel()
        progressTick = nil
        if reset {
            playbackProgress = 0
            playbackPosition = 0
            playbackDuration = 0
        }
    }

    /// [T-kelivo-tts] Seek within the CURRENTLY-playing unit (the floating
    /// control's scrubber drag). Out-of-range clamps; seeking a synthesizing
    /// or not-yet-started unit is a no-op.
    func seekCurrentUnit(to fraction: Double) {
        guard let p = player else { return }
        let clamped = min(1, max(0, fraction))
        p.currentTime = p.duration * clamped
        playbackPosition = p.currentTime
        playbackProgress = clamped
    }

    private func activatePlaybackSession() throws {
        // Session is owned by AudioSessionCoordinator — declare the reply-TTS intent
        // (idempotent; AIChatViewModel.speak* already did). It applies the
        // `.playback/.spokenAudio/.duckOthers` profile.
        AudioSessionCoordinator.shared.begin(.replyTTS)
    }
}

extension VoiceOutputPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Only react if THIS player is still the current one — stopAll() or a
            // newly-started unit may have already replaced it.
            guard self.player === finished else { return }
            let finishedSeq = self.playingSeq
            self.stopProgressTick(reset: true)
            self.player = nil
            self.playingSeq = -1
            self.playingSessionId = nil
            self.playingUnit = nil
            // Detect an UNDER-RUN: audio finished but the next unit isn't ready yet
            // (still generating) → a gap. Logged so the dynamic window can be tuned.
            let nextReady = self.queue.first?.audio != nil
            let generating = self.queue.contains { $0.task != nil && $0.audio == nil && !$0.failed }
            if !self.queue.isEmpty && !nextReady && generating {
                VoiceLog.log("TTS ⚠︎ UNDER-RUN after #\(finishedSeq): next unit not ready (queue=\(self.queue.count), still synthesizing)")
            } else {
                VoiceLog.log("TTS ■ finished #\(finishedSeq) (queue=\(self.queue.count) buffered=\(String(format: "%.2f", self.bufferedAudioSeconds))s)")
            }
            self.pumpPlayback()
            // Nothing left and nothing generating → release the session (guarded
            // so it never deactivates a recording session).
            if self.queue.isEmpty && self.player == nil && !generating {
                self.releaseSessionIfSafe()
            }
            // [TTS-10] A unit just ended (or the queue moved on): the
            // Now Playing title belongs to the NEXT unit — refresh.
            VoiceNowPlaying.shared.refresh()
        }
    }
}
