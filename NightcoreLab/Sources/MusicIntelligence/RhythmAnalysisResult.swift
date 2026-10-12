import Foundation

/// Offline rhythm descriptors in ORIGINAL source seconds.
///
/// Version 2 (Stage 11): onset strength from a ~11.6 ms spectral-flux
/// envelope (independent of the 83 ms visual envelope), tempo from its
/// autocorrelation with sub-frame interpolation, beats from dynamic-programming
/// tracking (they follow small tempo drift instead of a fixed grid), a 4/4
/// downbeat estimate and an evidence-based confidence. BPM candidates remain
/// hypotheses: octave-related alternatives (e.g. 87 and 174) can coexist.
///
/// Version 3 (Stage 12.5): octave and phase checks plus a contrast gate,
/// validated on genre fixtures (EDM, house, rock, hip hop, no drums). Cached
/// v2 rhythm is recomputed; the energy timeline is kept.
struct RhythmAnalysisResult: Codable, Equatable, Sendable {
    static let algorithmVersion = 3
    static let methodIdentifier = "spectral-flux-acf-dp-beat-tracking-v3"

    struct BPMCandidate: Codable, Equatable, Sendable {
        let bpm: Double
        /// Periodicity agreement in 0...1; octave-related alternatives can coexist.
        let confidence: Float
    }

    struct BeatEvent: Codable, Equatable, Sendable {
        let time: TimeInterval
        let index: Int
        /// Onset strength at this beat relative to the strongest beat (0...1).
        let strength: Float
        /// First beat of a bar under the 4/4 assumption; see downbeatConfidence.
        let isDownbeat: Bool

        init(time: TimeInterval, index: Int, strength: Float, isDownbeat: Bool = false) {
            self.time = time
            self.index = index
            self.strength = strength
            self.isDownbeat = isDownbeat
        }

        private enum CodingKeys: String, CodingKey {
            case time, index, strength, isDownbeat
        }

        /// Version-1 payloads have no downbeat flag.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(time: try c.decode(TimeInterval.self, forKey: .time),
                      index: try c.decode(Int.self, forKey: .index),
                      strength: try c.decode(Float.self, forKey: .strength),
                      isDownbeat: try c.decodeIfPresent(Bool.self, forKey: .isDownbeat) ?? false)
        }
    }

    enum Quality: String, Codable, Sendable {
        case insufficient, low, medium, high
    }

    let onsetEvents: [TimeInterval]
    let bpmCandidates: [BPMCandidate]
    /// Tracked beats (not necessarily equally spaced). Empty when the evidence
    /// is insufficient: consumers must not invent a pulse from noise.
    let beatGrid: [BeatEvent]
    let confidence: Float
    /// How clearly one bar phase stands out (0 = unknown, 1 = unambiguous).
    let downbeatConfidence: Float
    let method: String
    let algorithmVersion: Int
    let quality: Quality

    init(onsetEvents: [TimeInterval], bpmCandidates: [BPMCandidate],
         beatGrid: [BeatEvent], confidence: Float,
         downbeatConfidence: Float = 0,
         method: String = Self.methodIdentifier,
         algorithmVersion: Int = Self.algorithmVersion) {
        self.onsetEvents = onsetEvents
        self.bpmCandidates = bpmCandidates
        self.beatGrid = beatGrid
        self.confidence = confidence
        self.downbeatConfidence = downbeatConfidence
        self.method = method
        self.algorithmVersion = algorithmVersion
        quality = Self.quality(for: confidence)
    }

    static func quality(for confidence: Float) -> Quality {
        confidence < 0.25 ? .insufficient :
            confidence < 0.5 ? .low : confidence < 0.75 ? .medium : .high
    }

    private enum CodingKeys: String, CodingKey {
        case onsetEvents, bpmCandidates, beatGrid, confidence, downbeatConfidence
        case method, algorithmVersion, quality
    }

    /// Version-1 payloads (no downbeat confidence) still decode; the cache then
    /// discards them by version, without touching the energy timeline.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onsetEvents = try c.decode([TimeInterval].self, forKey: .onsetEvents)
        bpmCandidates = try c.decode([BPMCandidate].self, forKey: .bpmCandidates)
        beatGrid = try c.decode([BeatEvent].self, forKey: .beatGrid)
        confidence = try c.decode(Float.self, forKey: .confidence)
        downbeatConfidence = try c.decodeIfPresent(Float.self, forKey: .downbeatConfidence) ?? 0
        method = try c.decode(String.self, forKey: .method)
        algorithmVersion = try c.decode(Int.self, forKey: .algorithmVersion)
        quality = try c.decode(Quality.self, forKey: .quality)
    }

    /// Never trust unvalidated cache payloads as event positions or confidence.
    func isValid(through duration: TimeInterval) -> Bool {
        guard duration.isFinite, duration >= 0,
              algorithmVersion >= 1, !method.isEmpty,
              confidence.isFinite, (0...1).contains(confidence),
              downbeatConfidence.isFinite, (0...1).contains(downbeatConfidence),
              quality == Self.quality(for: confidence),
              bpmCandidates.count <= 4,
              beatGrid.count <= 5_000 else { return false }
        var last = -Double.infinity
        for time in onsetEvents {
            guard time.isFinite, time >= 0, time <= duration, time > last else { return false }
            last = time
        }
        var priorConfidence = Float.infinity
        for candidate in bpmCandidates {
            guard candidate.bpm.isFinite, (55...210).contains(candidate.bpm),
                  candidate.confidence.isFinite, (0...1).contains(candidate.confidence),
                  candidate.confidence <= priorConfidence else { return false }
            priorConfidence = candidate.confidence
        }
        var previous = -Double.infinity
        for (index, beat) in beatGrid.enumerated() {
            guard beat.time.isFinite, beat.time >= 0, beat.time <= duration,
                  beat.time > previous, beat.index == index,
                  beat.strength.isFinite, (0...1).contains(beat.strength) else { return false }
            previous = beat.time
        }
        return true
    }
}
