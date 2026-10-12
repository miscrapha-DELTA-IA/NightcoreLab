import Foundation

/// Passive actor boundary for future visual audio reactivity.
///
/// Does NOT install an AVAudioNode tap, poll the player, change playback,
/// schedule timers, or manufacture beat/energy readings from metadata.
/// The future DSP producer must run away from MainActor and explicitly supply
/// AudioFeatureFrame values. Until then snapshot() returns silence.
actor AudioFeatureEngine {
    private var current: AudioFeatures = .silent

    func snapshot() -> AudioFeatures { current }

    @discardableResult
    func accept(_ frame: AudioFeatureFrame) -> AudioFeatures {
        let features = AudioFeatures(
            bass: frame.bassLevel,
            mid: frame.midLevel,
            treble: frame.trebleLevel,
            energy: frame.rmsLevel,
            beatDetected: frame.beatDetected
        )
        current = features
        return features
    }

    func reset() { current = .silent }
}
