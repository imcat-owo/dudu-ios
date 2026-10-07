// Extracted from OpenMinis (GPL-3.0) — engine logic only, no UI.
// Part of Dudu native rewrite.
import AVFoundation
import Combine
import SwiftUI
import UIKit
class GlobalAudioPlayer: ObservableObject {
    static let shared = GlobalAudioPlayer()
    private init() {
        // Observe AVAudioSession interruptions so we can log when playback
        // is paused by an external audio source (call, Siri, another media
        // app). The actual decision to resume lives elsewhere — this is a
        // diagnostic hook for the silent-audio keep-alive investigation.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            let label = type == .began ? "began" : "ended"
            let isPlaying = self?.isPlaying ?? false
            logger.info("[AudioPlayback] interruption: type=\(label) shouldResume=\(shouldResume) wasPlaying=\(isPlaying)")
        }
        // [T-ios-live-activity-audio-toggle] The Live Activity play/pause toggle
        // is handled by VoiceOutputState (read-aloud engine), NOT here — see
        // VoiceOutputState.registerLiveActivityToggleObserver (b0f3f884 fix).
    }

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var rate: Float = 1.0
    @Published var isLoaded = false
    @Published var activeFileURL: URL?
    @Published var fileName: String = ""
    /// Set to true when user taps capsule to re-open the full preview.
    @Published var showFullPreview = false

    /// Capsule is shown whenever an audio file is loaded. The only way to hide
    /// it is to call `stop()` (e.g. via the capsule's close button), which
    /// resets `isLoaded`. The capsule view itself further hides when the full
    /// preview sheet is open to avoid overlapping UI.
    var isPiPActive: Bool { isLoaded }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var seekWorkItem: DispatchWorkItem?

    /// Generation counter for in-flight loads. `play` loads off-thread and
    /// the detached task cannot be cancelled, so completion instead checks
    /// that its request is still the current one: bumped by every new
    /// `play` and by `stopInternal` (i.e. stop()).
    private var playRequestId = 0

    /// Whether the given URL is the currently active audio file.
    func isActive(url: URL) -> Bool {
        activeFileURL == url
    }

    /// Load and play a URL. If already playing this URL, just ensures playback. If a different URL, stops current and loads new.
    func play(url: URL) {
        if activeFileURL == url {
            // Same file — restart from beginning if finished, otherwise resume
            if !isPlaying {
                if duration > 0 && currentTime >= duration - 0.1 {
                    seek(to: 0)
                }
                togglePlayPause()
            }
            return
        }
        // Stop any current playback
        stopInternal()
        // Claim a new load generation (stopInternal bumped it, staling any
        // load still in flight from a previous play).
        playRequestId += 1
        let requestId = playRequestId
        // Suspend silent audio so media gets full volume
        let preCount = BackgroundKeepAliveManager.shared.silentAudioSuspendCount
        logger.info("[AudioPlayback] play: url=\(url.lastPathComponent) suspendSilentAudio → count will be \(preCount + 1)")
        BackgroundKeepAliveManager.shared.suspendSilentAudioForMedia()
        // Load new file
        let loadURL = url
        Task.detached(priority: .userInitiated) {
            guard let p = try? AVAudioPlayer(contentsOf: loadURL) else {
                await MainActor.run {
                    BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia()
                }
                return
            }
            p.prepareToPlay()
            p.enableRate = true
            let dur = p.duration
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.playRequestId == requestId else {
                    // Superseded by a newer play() or cancelled by stop()
                    // while this load was in flight. Do NOT install/play —
                    // and hand back the silent-audio suspension THIS request
                    // took: stopInternal can never return it, because this
                    // load never became `isLoaded`. (Without this, rapid
                    // play→play leaves the keep-alive suspend count +1
                    // forever, and the stale player starts playing anyway.)
                    BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia()
                    return
                }
                self.player = p
                self.activeFileURL = loadURL
                self.fileName = loadURL.deletingPathExtension().lastPathComponent
                self.duration = dur
                self.currentTime = 0
                self.isLoaded = true
                // [TTS-13] Don't reset to 1.0 — reuse the last rate the
                // user picked in the audio preview.
                self.rate = VoiceBubblePlaybackState.rememberedRate
                // Start playing immediately. Declaring `.mediaAttachment` preempts
                // reply TTS (mutually exclusive) and applies the playback profile.
                AudioSessionCoordinator.shared.begin(.mediaAttachment)
                p.rate = self.rate
                p.play()
                self.isPlaying = true
                self.startTimer()
                VoiceNowPlaying.shared.refresh()
            }
