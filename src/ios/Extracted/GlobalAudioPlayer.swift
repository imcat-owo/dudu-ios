// Extracted from OpenMinis (GPL-3.0) — engine logic only, no UI.
// Part of Dudu native rewrite.
import AVFoundation
import Combine

/// Global audio player for media attachments (voice messages, audio files).
/// Engine logic only — no UI.
class GlobalAudioPlayer: ObservableObject {
    static let shared = GlobalAudioPlayer()

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoaded = false
    @Published var rate: Float = 1.0

    private var player: AVAudioPlayer?

    private init() {}

    func play(url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
            isPlaying = true
            isLoaded = true
            duration = player?.duration ?? 0
        } catch {
            isPlaying = false
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        isPlaying = false
        isLoaded = false
        currentTime = 0
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.rate = rate
            p.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = time
        currentTime = time
    }
}
