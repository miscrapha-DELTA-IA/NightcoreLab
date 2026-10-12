import Foundation

/// Stage 12 (first cut): a visual material is the renderer-side description
/// of HOW resolved audio/rhythm values drive a shader. It is not another
/// preset layer: it is derived from the existing CreativeVisualProgram, and
/// its output is the exact set of uniforms the shader receives.
///
/// Only the Marble exists in this cut. Liquid Glass, Chrome and fluid
/// materials are future cases; fluid needs frame-to-frame state, which would
/// break deterministic Story scrubbing, so it is deliberately not modeled yet.
struct VisualMaterial: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case marble
    }

    let kind: Kind
    /// Beat pulse amount in 0...1. 0 renders the pre-Stage-12 Marble exactly.
    let beatPulse: Double
    /// Exponential decay of the pulse per beat phase (higher = snappier).
    let pulseDecay: Double
    /// Non-downbeat pulses are scaled by this when downbeats are reliable.
    let offbeatScale: Double

    init(kind: Kind = .marble, beatPulse: Double = 0,
         pulseDecay: Double = 6, offbeatScale: Double = 0.7) {
        self.kind = kind
        self.beatPulse = Self.bound(beatPulse, 0...1, fallback: 0)
        self.pulseDecay = Self.bound(pulseDecay, 1...20, fallback: 6)
        self.offbeatScale = Self.bound(offbeatScale, 0...1, fallback: 0.7)
    }

    /// The pre-Stage-12 look: no rhythm uniform.
    static let legacyMarble = VisualMaterial()

    /// Marble driven by an existing program: the pulse follows the same
    /// audio-reaction switch and visual intensity as the distortion.
    static func marble(for program: CreativeVisualProgram?) -> VisualMaterial {
        guard let program else { return .legacyMarble }
        let reaction: Double
        switch program.preset.audioReaction {
        case .off: return .legacyMarble
        case .subtle: reaction = 0.35
        case .responsive: reaction = 1
        }
        return VisualMaterial(beatPulse: 0.8 * reaction * program.preset.visualStyle.intensity)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, beatPulse, pulseDecay, offbeatScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
                  beatPulse: try c.decode(Double.self, forKey: .beatPulse),
                  pulseDecay: try c.decodeIfPresent(Double.self, forKey: .pulseDecay) ?? 6,
                  offbeatScale: try c.decodeIfPresent(Double.self, forKey: .offbeatScale) ?? 0.7)
    }

    private static func bound(_ value: Double, _ range: ClosedRange<Double>,
                              fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// Exactly the Marble shader's reactive uniforms, all in 0...1.
struct MarbleUniforms: Equatable, Sendable {
    let distortion: Double
    let beatPulse: Double

    static let neutral = MarbleUniforms(distortion: 0, beatPulse: 0)
}

/// Pure mapping: (material, existing parameter frame, rhythm frame) → uniforms.
/// No clock, RNG or history, so the live player, the Story preview and the MP4
/// produce the same uniforms for the same source timestamp.
enum MaterialResolver {
    static func marble(_ material: VisualMaterial,
                       parameters: CreativeParameterFrame,
                       rhythm: RhythmFrame?) -> MarbleUniforms {
        MarbleUniforms(distortion: unit(parameters.marbleDistortion),
                       beatPulse: beatPulse(material, rhythm: rhythm))
    }

    /// Weighted by rhythm confidence: weak evidence fades the pulse out instead
    /// of flashing on noise. Insufficient analyses publish no beats at all.
    static func beatPulse(_ material: VisualMaterial, rhythm: RhythmFrame?) -> Double {
        guard material.beatPulse > 0, let rhythm else { return 0 }
        let trust = unit((Double(rhythm.confidence) - 0.25) / 0.5)
        guard trust > 0 else { return 0 }
        var accent = 1.0
        if let barBeat = rhythm.barBeat, rhythm.downbeatConfidence >= 0.3, barBeat != 0 {
            accent = material.offbeatScale
        }
        return unit(material.beatPulse * trust * accent * rhythm.pulse(decay: material.pulseDecay))
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// Render-rate pulse source for the LIVE Marble. The 12 Hz reactive loop is
/// too coarse for a ~150 ms pulse, so the Marble's own TimelineView asks this
/// driver once per frame. The value is still a pure function of the source
/// time read from the playback clock.
struct MarblePulseDriver: Equatable, Sendable {
    let material: VisualMaterial
    let rhythm: RhythmAnalysisResult
    let clock: PlaybackClock
    /// Identity of this run, so views only update when the source changes.
    let id: UUID

    init(material: VisualMaterial, rhythm: RhythmAnalysisResult, clock: PlaybackClock) {
        self.material = material
        self.rhythm = rhythm
        self.clock = clock
        self.id = UUID()
    }

    func pulse() -> Double {
        guard clock.isPlaying else { return 0 }
        return MaterialResolver.beatPulse(
            material, rhythm: RhythmFrame.at(clock.lyricTime, in: rhythm))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
