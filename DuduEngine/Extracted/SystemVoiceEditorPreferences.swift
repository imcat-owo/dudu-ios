// Extracted from OpenMinis (GPL-3.0) — engine logic only, no UI.
// Part of Dudu native rewrite.
import Foundation

// MARK: - System voice editor
//
// [T-tts-services 09-11] The System (Apple) row's gear sheet. Previously the
// on-device voice's pitch/volume lived in Enhanced Background settings and the
// voice roster only inside the Model Output picker — two unrelated places for
// "tune my voice". This editor gives the built-in engine the same treatment as
// any cloud service: pick a voice, set speed/pitch/volume, test-listen.
//
// The chosen voice identifier is stored in SystemVoicePreferences.selectedVoiceId
// and honoured by VoiceProviderResolver.resolvedSystemOutputVoiceId() (which
// already reads selection overrides / group members — this adds a direct
// selection without touching the Model-Group machinery).

// MARK: - Preference storage

enum SystemVoiceEditorPreferences {
    private static let voiceKey = "systemVoice.selectedIdentifier"
    private static let rateKey = "systemVoice.rateMultiplier"

    /// Pinned AVSpeechSynthesisVoice identifier; nil = auto by language.
    static var selectedVoiceId: String? {
        get { UserDefaults.standard.string(forKey: voiceKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: voiceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: voiceKey)
            }
        }
    }

    /// Utterance rate multiplier (0.4–0.62 → AVSpeech 0–1 scale). Default 1.0.
    /// Stored as the AVSpeechUtterance.rate value directly for simplicity.
    static var utteranceRate: Float {
        get {
            let v = UserDefaults.standard.object(forKey: rateKey) as? Float
            return v ?? 0.5
        }
        set { UserDefaults.standard.set(newValue, forKey: rateKey) }
    }
}
