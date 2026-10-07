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
}
