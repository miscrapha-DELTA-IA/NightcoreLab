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
        // Downbeats are periodic (every 4th beat), so the first one is within
        // the first bar: O(1) per render frame instead of scanning all beats.
        if let first = beats.prefix(4).firstIndex(where: \.isDownbeat) {
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


/// Musical coordinates derived ONLY from the existing validated rhythm grid.
/// Values are 0-based beat positions (2.5 = halfway through the third beat),
/// with 1-based bars assuming 4/4. No tempo analysis or clock is created.
enum PadMusicalGrid {
    enum Subdivision: Int, Codable, Sendable {
        case eighth = 2
        case sixteenth = 4
    }

    struct Position: Equatable, Sendable {
        let beat: Double
        let bar: Int
        let bpm: Double
        let nearestGridSourceTime: TimeInterval?
    }

    /// Requires meaningful rhythm evidence; silent/ambiguous sections leave
    /// event timing untouched instead of inventing a BPM.
    static func at(_ sourceTime: TimeInterval, rhythm: RhythmAnalysisResult,
                   subdivision: Subdivision = .sixteenth) -> Position? {
        guard (rhythm.quality == .medium || rhythm.quality == .high),
              rhythm.algorithmVersion == RhythmAnalysisResult.algorithmVersion,
              rhythm.beatGrid.count >= 2,
              let frame = RhythmFrame.at(sourceTime, in: rhythm),
              frame.beatIndex >= 0, frame.beatIndex < rhythm.beatGrid.count,
              frame.bpm.isFinite, frame.bpm > 0 else { return nil }
        let beat = Double(frame.beatIndex) + frame.phase
        guard beat.isFinite, beat >= 0 else { return nil }
        let snapped = (beat * Double(subdivision.rawValue))
            .rounded(.toNearestOrAwayFromZero) / Double(subdivision.rawValue)
        let gridTime = time(forBeat: snapped, rhythm: rhythm)
        return Position(beat: beat, bar: Int(beat / 4) + 1,
                        bpm: frame.bpm, nearestGridSourceTime: gridTime)
    }

    /// Piecewise linear inversion over TRACKED beats. Local tempo drift is
    /// preserved; out-of-range requests do not extrapolate a fictional grid.
    static func time(forBeat beat: Double,
                     rhythm: RhythmAnalysisResult) -> TimeInterval? {
        let beats = rhythm.beatGrid
        guard beat.isFinite, beat >= 0, beats.count >= 2,
              beat <= Double(beats.count - 1) else { return nil }
        let index = Int(beat.rounded(.down))
        let start = beats[index].time
        let fraction = beat - Double(index)
        if fraction == 0 { return start.isFinite ? start : nil }
        guard index + 1 < beats.count else { return nil }
        let end = beats[index + 1].time
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return start + (end - start) * fraction
    }

    /// Applies magnetic pull without mutating a PadEvent's raw timestamp.
    static func assistedTime(raw: TimeInterval,
                             grid: TimeInterval?,
                             strength: Float) -> TimeInterval {
        guard raw.isFinite, raw >= 0, let grid, grid.isFinite, grid >= 0,
              strength.isFinite, strength > 0 else { return raw }
        let clamped = Double(min(1, max(0, strength)))
        return max(0, raw + (grid - raw) * clamped)
    }
}
