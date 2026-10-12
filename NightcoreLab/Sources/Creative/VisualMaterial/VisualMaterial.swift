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

    /// Stage 12.5 tuning defaults: exactly the values the Stage 12 Marble
    /// used (the last two were constants inside the Metal shader).
    static let defaultPulseDecay = 6.0
    static let defaultOffbeatScale = 0.7
    static let defaultWarpAmount = 0.18
    static let defaultBrightnessBoost = 0.10
    /// Share of a program's visual intensity used as pulse amount.
    static let programPulseScale = 0.8

    let kind: Kind
    /// Beat pulse amount in 0...1 (`beatPulseIntensity`). 0 renders the
    /// pre-Stage-12 Marble exactly. Stored name kept for Codable payloads.
    let beatPulse: Double
    /// Exponential decay of the pulse per beat phase (higher = snappier).
    let pulseDecay: Double
    /// Non-downbeat pulses are scaled by this when downbeats are reliable
    /// (`downbeatBoost` = 1 − offbeatScale).
    let offbeatScale: Double
    /// Extra domain warp per unit of pulse (shader: warp × (… + warpAmount·pulse)).
    let warpAmount: Double
    /// Accent-colour glow per unit of pulse, kept off the dark veins.
    let brightnessBoost: Double

    var beatPulseIntensity: Double { beatPulse }
    /// How much the downbeat stands out: other beats pulse at 1 − downbeatBoost.
    var downbeatBoost: Double { 1 - offbeatScale }

    init(kind: Kind = .marble, beatPulse: Double = 0,
         pulseDecay: Double = VisualMaterial.defaultPulseDecay,
         offbeatScale: Double = VisualMaterial.defaultOffbeatScale,
         warpAmount: Double = VisualMaterial.defaultWarpAmount,
         brightnessBoost: Double = VisualMaterial.defaultBrightnessBoost) {
        self.kind = kind
        self.beatPulse = Self.bound(beatPulse, 0...1, fallback: 0)
        self.pulseDecay = Self.bound(pulseDecay, 1...20, fallback: Self.defaultPulseDecay)
        self.offbeatScale = Self.bound(offbeatScale, 0...1, fallback: Self.defaultOffbeatScale)
        self.warpAmount = Self.bound(warpAmount, 0...0.5, fallback: Self.defaultWarpAmount)
        self.brightnessBoost = Self.bound(brightnessBoost, 0...0.3,
                                          fallback: Self.defaultBrightnessBoost)
    }

    /// Stage 12.5 tuning vocabulary. Omitted values keep the current look
    /// bit for bit (a nil downbeatBoost keeps offbeatScale = 0.7 exactly).
    init(beatPulseIntensity: Double,
         pulseDecay: Double = VisualMaterial.defaultPulseDecay,
         downbeatBoost: Double? = nil,
         warpAmount: Double = VisualMaterial.defaultWarpAmount,
         brightnessBoost: Double = VisualMaterial.defaultBrightnessBoost) {
        let offbeat = downbeatBoost.map { boost in
            1 - Self.bound(boost, 0...1, fallback: 1 - Self.defaultOffbeatScale)
        } ?? Self.defaultOffbeatScale
        self.init(beatPulse: beatPulseIntensity, pulseDecay: pulseDecay,
                  offbeatScale: offbeat, warpAmount: warpAmount,
                  brightnessBoost: brightnessBoost)
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
        return VisualMaterial(
            beatPulse: programPulseScale * reaction * program.preset.visualStyle.intensity)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, beatPulse, pulseDecay, offbeatScale, warpAmount, brightnessBoost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
                  beatPulse: try c.decode(Double.self, forKey: .beatPulse),
                  pulseDecay: try c.decodeIfPresent(Double.self, forKey: .pulseDecay)
                      ?? Self.defaultPulseDecay,
                  offbeatScale: try c.decodeIfPresent(Double.self, forKey: .offbeatScale)
                      ?? Self.defaultOffbeatScale,
                  warpAmount: try c.decodeIfPresent(Double.self, forKey: .warpAmount)
                      ?? Self.defaultWarpAmount,
                  brightnessBoost: try c.decodeIfPresent(Double.self, forKey: .brightnessBoost)
                      ?? Self.defaultBrightnessBoost)
    }

    private static func bound(_ value: Double, _ range: ClosedRange<Double>,
                              fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// Exactly the Marble shader's reactive uniforms.
struct MarbleUniforms: Equatable, Sendable {
    let distortion: Double
    let beatPulse: Double
    /// Material tuning bound with the pulse (Stage 12.5; former shader constants).
    let warpAmount: Double
    let brightnessBoost: Double

    init(distortion: Double, beatPulse: Double,
         warpAmount: Double = VisualMaterial.defaultWarpAmount,
         brightnessBoost: Double = VisualMaterial.defaultBrightnessBoost) {
        self.distortion = distortion
        self.beatPulse = beatPulse
        self.warpAmount = warpAmount
        self.brightnessBoost = brightnessBoost
    }

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
                       beatPulse: beatPulse(material, rhythm: rhythm),
                       warpAmount: material.warpAmount,
                       brightnessBoost: material.brightnessBoost)
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
