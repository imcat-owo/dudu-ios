import Foundation

// MARK: - Voice-bubble playback state (TTS-13, technical part)
//
// Two pieces of durable per-file state for voice bubbles / audio
// attachments, kept OUT of the UI layer so any player surface can read
// them:
//
//  1. Listen progress: seconds heard + whether the file was finished,
//     keyed by the stable file name (e.g. "tts-a1b2c3d4"). Recorded when
//     playback stops or ends naturally. UI uses it for "unlistened" badges
//     and resume hints (the badge styling itself is a UI decision and is
//     intentionally not built here).
//  2. Playback rate memory: the last rate the user picked in the audio
//     preview, applied to the NEXT bubble instead of resetting to 1.0.
//     Global for now — per-session rate would need the session id at the
//     player, which the bubble path doesn't carry; the store is shaped so
//     a per-session key can be added without changing call sites.

enum VoiceBubblePlaybackState {

    private static let progressKey = "voice.bubble.progress.v1"
    private static let rateKey = "voice.bubble.rate.v1"

    /// Progress snapshot for one audio file.
    struct Progress: Codable {
        /// Seconds heard when playback last stopped.
        var position: Double
        /// File duration at the time, for "x / y" display.
        var duration: Double
        /// True when playback reached the end (within tolerance).
        var finished: Bool
        var updatedAt: Date
    }

    // MARK: - Progress

    static func recordProgress(fileName: String, position: Double, duration: Double) {
        guard !fileName.isEmpty else { return }
        var all = loadAll()
        all[fileName] = Progress(
            position: position,
            duration: duration,
            finished: duration > 0 && position >= duration - 0.5,
            updatedAt: Date())
        saveAll(all)
    }

    static func progress(for fileName: String) -> Progress? {
        loadAll()[fileName]
    }

    static func clearProgress(for fileName: String) {
        var all = loadAll()
        all.removeValue(forKey: fileName)
        saveAll(all)
    }

    private static func loadAll() -> [String: Progress] {
        guard let data = UserDefaults.standard.data(forKey: progressKey),
              let decoded = try? JSONDecoder().decode([String: Progress].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveAll(_ all: [String: Progress]) {
        // Cap the table so a heavy voice-message user can't grow it
        // without bound — keep the 200 most recently updated.
        let trimmed: [String: Progress]
        if all.count > 200 {
            let keep = all.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(200)
            trimmed = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        } else {
            trimmed = all
        }
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: progressKey)
        }
    }

    // MARK: - Rate memory

    /// Last user-chosen bubble playback rate; 1.0 when never set.
    static var rememberedRate: Float {
        let v = UserDefaults.standard.float(forKey: rateKey)
        return v > 0 ? v : 1.0
    }

    static func rememberRate(_ rate: Float) {
        guard rate > 0 else { return }
        UserDefaults.standard.set(rate, forKey: rateKey)
    }
}
