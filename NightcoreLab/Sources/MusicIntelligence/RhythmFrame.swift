import Foundation

/// Rhythm state at one ORIGINAL-source timestamp (Stage 11).
///
/// A pure function of a cached RhythmAnalysisResult and a time: the same
/// timestamp gives the same frame in the live player, the Story preview and
/// the MP4, at any frame rate and in any query order. Visual consumers
/// (typography pulse, Marble, materials) read this instead of re-deriving
/// beats. Beats are extrapolated at most one interval past the tracked
/// region; beyond that there is deliberately no pulse.
struct RhythmFrame: Equatable, Sendable {
    /// Index into the tracked beats; -1 / count are the one-interval
    /// extrapolations before the first and after the last beat.
    let beatIndex: Int
    /// Progress from the current beat to the next, in 0..<1.
    let phase: Double
    let timeSinceBeat: TimeInterval
    /// Local tempo from the surrounding inter-beat interval.
    let bpm: Double
    /// Strength of the current tracked beat (0 when extrapolated).
    let beatStrength: Float
    /// Beat within a 4/4 bar (0 = downbeat), when downbeats were detected.
    let barBeat: Int?
    /// Progress through the bar in 0..<1, when downbeats were detected.
    let barPhase: Double?
    let confidence: Float
    let downbeatConfidence: Float

    /// 1 exactly on the beat, decaying exponentially until the next one.
    func pulse(decay: Double = 6) -> Double {
        exp(-max(0, decay) * phase)
    }

    static func at(_ sourceTime: TimeInterval,
                   in rhythm: RhythmAnalysisResult) -> RhythmFrame? {
        let beats = rhythm.beatGrid
        guard sourceTime.isFinite, beats.count >= 2 else { return nil }

        // Last beat at or before sourceTime (binary search).
        var low = 0, high = beats.count
        while low < high {
            let middle = (low + high) / 2
            if beats[middle].time <= sourceTime { low = middle + 1 } else { high = middle }
        }
        let current = low - 1
        let last = beats.count - 1

        let beatTime: TimeInterval
        let interval: TimeInterval
        let index: Int
        let strength: Float
        if current < 0 {
            interval = beats[1].time - beats[0].time
            beatTime = beats[0].time - interval
            index = -1
            strength = 0
            guard sourceTime >= beatTime else { return nil }
        } else if current == last {
            interval = beats[last].time - beats[last - 1].time
            if sourceTime < beats[last].time + interval {
                beatTime = beats[last].time
                index = last
                strength = beats[last].strength
            } else {
                beatTime = beats[last].time + interval
                index = last + 1
                strength = 0
                guard sourceTime < beatTime + interval else { return nil }
            }
        } else {
            beatTime = beats[current].time
            interval = beats[current + 1].time - beatTime
            index = current
            strength = beats[current].strength
        }
        guard interval.isFinite, interval > 0 else { return nil }

        let elapsed = sourceTime - beatTime
        let phase = min(max(0, elapsed / interval), 1.0.nextDown)
        var barBeat: Int?
        var barPhase: Double?
        if let first = beats.firstIndex(where: \.isDownbeat) {
            let position = ((index - first) % 4 + 4) % 4
            barBeat = position
            barPhase = (Double(position) + phase) / 4
        }
        return RhythmFrame(beatIndex: index, phase: phase, timeSinceBeat: elapsed,
                           bpm: 60 / interval, beatStrength: strength,
                           barBeat: barBeat, barPhase: barPhase,
                           confidence: rhythm.confidence,
                           downbeatConfidence: rhythm.downbeatConfidence)
    }
}
