import Foundation

/// Output contracts only. Consumers may eventually connect these to
/// typography, Metal, particles or export. Nothing is rendered here.
struct VisualResponse: Equatable, Codable, Sendable {
    let scale: Double                 // 1.00 ... 1.06
    let glow: Double                  // 0 ... 1
    let distortion: Double            // 0 ... 1
    let intensity: Double             // 0 ... 1
    let motion: Double                // 0 ... 1
    let wordAnimationIntensity: Double
    let distortionAmount: Double
    let emissionRate: Double

    static let neutral = VisualResponse(
        scale: 1, glow: 0, distortion: 0, intensity: 0,
        motion: 0, wordAnimationIntensity: 0, distortionAmount: 0,
        emissionRate: 0
    )
}

/// Pure, deterministic mapping independent of SwiftUI, UIKit, the audio graph
/// and the shader implementation. All outputs are bounded.
enum AudioVisualMapper {
    static func map(_ features: AudioFeatures, preset: CreativePreset) -> VisualResponse {
        let reaction: Double
        switch preset.audioReaction {
        case .off: return .neutral
        case .subtle: reaction = 0.35
        case .responsive: reaction = 1
        }

        let intensity = preset.visualStyle.intensity * reaction
        let bass = features.bass
        let energy = features.energy
        let mid = features.mid
        let treble = features.treble
        let drive = max(bass, energy * 0.65)
        let power = clamp(drive * intensity)
        let glow = clamp((bass * 0.55 + energy * 0.45) * intensity)
        let distortion = clamp((bass * 0.65 + treble * 0.35)
                               * intensity * preset.visualStyle.shaderParameters.distortion)
        let motion = clamp(energy * reaction * preset.visualStyle.motion)
        let onset = features.beatDetected ? 1.0 : 0.0
        let word = clamp((energy * 0.55 + mid * 0.25 + onset * 0.20) * intensity)

        return VisualResponse(
            scale: 1 + 0.06 * bass * intensity,
            glow: glow,
            distortion: distortion,
            intensity: power,
            motion: motion,
            wordAnimationIntensity: word,
            distortionAmount: distortion,
            emissionRate: clamp((energy * 0.85 + onset * 0.15) * intensity)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// No timer and no SwiftUI invalidation. The next consumer explicitly pulls
/// snapshots at its own pace; this gate enforces a maximum of 12 Hz, or 6 Hz
/// in Low Power Mode, and resets cleanly after a seek.
struct VisualResponseThrottle: Sendable {
    private(set) var previousTime: TimeInterval?

    mutating func shouldEmit(at time: TimeInterval, lowPower: Bool) -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        let minimumInterval = lowPower ? 1.0 / 6 : 1.0 / 12
        if let previousTime, time >= previousTime,
           time - previousTime < minimumInterval {
            return false
        }
        previousTime = time
        return true
    }

    mutating func reset() { previousTime = nil }
}
