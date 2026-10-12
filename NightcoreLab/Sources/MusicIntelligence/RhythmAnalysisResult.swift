import Foundation

/// Offline rhythm descriptors in ORIGINAL source seconds. Heuristic BPM
/// candidates are hypotheses, never a definitive tempo or a metronome clock.
struct RhythmAnalysisResult: Codable, Equatable, Sendable {
    static let algorithmVersion = 1
    static let methodIdentifier = "spectral-flux-energy-interval-voting-v1"

    struct BPMCandidate: Codable, Equatable, Sendable {
        let bpm: Double
        /// Periodicity agreement in 0...1; octave-related alternatives can coexist.
        let confidence: Float
    }

    struct BeatEvent: Codable, Equatable, Sendable {
        let time: TimeInterval
        let index: Int
        /// How closely this predicted grid beat corresponds to an observed attack.
        let strength: Float
    }

    enum Quality: String, Codable, Sendable {
        case insufficient, low, medium, high
    }

    let onsetEvents: [TimeInterval]
    let bpmCandidates: [BPMCandidate]
    let beatGrid: [BeatEvent]
    let confidence: Float
    let method: String
    let algorithmVersion: Int
    let quality: Quality

    init(onsetEvents: [TimeInterval], bpmCandidates: [BPMCandidate],
         beatGrid: [BeatEvent], confidence: Float,
         method: String = Self.methodIdentifier,
         algorithmVersion: Int = Self.algorithmVersion) {
        self.onsetEvents = onsetEvents
        self.bpmCandidates = bpmCandidates
        self.beatGrid = beatGrid
        self.confidence = confidence
        self.method = method
        self.algorithmVersion = algorithmVersion
        quality = confidence < 0.25 ? .insufficient :
                  confidence < 0.5 ? .low : confidence < 0.75 ? .medium : .high
    }

    /// Never trust unvalidated cache payloads as event positions or confidence.
    func isValid(through duration: TimeInterval) -> Bool {
        guard duration.isFinite, duration >= 0,
              algorithmVersion >= 1, !method.isEmpty,
              confidence.isFinite, (0...1).contains(confidence),
              quality == (confidence < 0.25 ? .insufficient :
                          confidence < 0.5 ? .low : confidence < 0.75 ? .medium : .high),
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
