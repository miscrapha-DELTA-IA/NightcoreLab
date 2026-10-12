import Foundation

/// Deterministic O(N) transient extraction + bounded tempo hypothesis search.
/// Consumes the EXISTING ~12 Hz energy/spectral bands; no second FFT, decode,
/// AVAudioEngine, vDSP setup, external dependency, or neural model is created.
/// Accuracy is bounded by envelope hop size and analyzed coverage.
enum RhythmAnalyzer {
    static func analyze(timeline: AudioFeatureTimeline) throws -> RhythmAnalysisResult {
        let points = timeline.points
        guard timeline.duration.isFinite, timeline.duration > 0, points.count >= 4 else {
            return empty
        }

        // Positive spectral flux and positive RMS slope, with the Foundation
        // heuristic onset as supporting (not required) evidence.
        var novelty = [Double](repeating: 0, count: points.count)
        for i in 1..<points.count {
            if i % 256 == 0 { try Task.checkCancellation() }
            let a = points[i - 1].features
            let b = points[i].features
            let flux = 0.40 * max(0, b.bass - a.bass)
                     + 0.35 * max(0, b.mid - a.mid)
                     + 0.25 * max(0, b.treble - a.treble)
            let rise = max(0, b.energy - a.energy)
            if b.energy > 0.055 {
                novelty[i] = flux * 0.8 + rise * 0.65
                    + (b.beatDetected ? 0.12 : 0)
            }
        }

        // Local adaptive threshold prevents background dynamics and silence
        // from becoming a beat grid. The refractory interval is shorter than
        // the fastest accepted quarter note (210 BPM).
        var onsets = [TimeInterval]()
        for i in 1..<(points.count - 1) {
            if i % 256 == 0 { try Task.checkCancellation() }
            let low = max(1, i - 6)
            let high = min(points.count - 1, i + 6)
            var sum = 0.0
            var sumSquares = 0.0
            for j in low...high {
                sum += novelty[j]
                sumSquares += novelty[j] * novelty[j]
            }
            let n = Double(high - low + 1)
            let mean = sum / n
            let deviation = sqrt(max(0, sumSquares / n - mean * mean))
            let threshold = max(0.085, mean + 0.65 * deviation)
            guard novelty[i] > threshold,
                  novelty[i] >= novelty[i - 1],
                  novelty[i] > novelty[i + 1] else { continue }
            let t = points[i].time
            guard t.isFinite, t >= 0, t <= timeline.duration else { continue }
            if let last = onsets.last, t - last < 0.20 {
                // The largest local maximum wins in a clustered transient.
                let previousIndex = points.binarySearchTime(last)
                if novelty[i] > novelty[previousIndex] { onsets[onsets.count - 1] = t }
            } else {
                onsets.append(t)
            }
        }
        guard onsets.count >= 4 else {
            return RhythmAnalysisResult(onsetEvents: onsets, bpmCandidates: [],
                                        beatGrid: [], confidence: 0)
        }

        // Lagged onset intervals (up to 3 events apart) stabilize gaps due to
        // missed attacks. Octave hypotheses remain separate: 80 and 160 BPM
        // may describe the same pulse sequence. No single BPM is asserted.
        var votes: [Int: Double] = [:]
        for i in 1..<onsets.count {
            if i % 256 == 0 { try Task.checkCancellation() }
            for lag in 1...min(3, i) {
                let delta = onsets[i] - onsets[i - lag]
                guard delta > 0 else { continue }
                let base = 60 * Double(lag) / delta
                for (factor, weight) in [(1.0, 1.0), (2.0, 0.70), (0.5, 0.45)] {
                    let bpm = base * factor
                    guard (55...210).contains(bpm) else { continue }
                    let bin = Int((bpm / 2).rounded()) * 2
                    votes[bin, default: 0] += weight / Double(lag)
                }
            }
        }
        let peaks = votes.keys.sorted {
            let left = votes[$0, default: 0]
            let right = votes[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }
        var candidates: [RhythmAnalysisResult.BPMCandidate] = []
        for bin in peaks {
            if candidates.count == 4 { break }
            let bpm = Double(bin)
            if candidates.contains(where: { abs($0.bpm - bpm) < 5 }) { continue }
            let period = 60 / bpm
            var match = 0.0
            var count = 0.0
            for i in 1..<onsets.count {
                let intervals = (onsets[i] - onsets[i - 1]) / period
                let multiple = max(1, intervals.rounded())
                let distance = abs(intervals - multiple)
                if distance <= 0.22 {
                    // Missing beats are possible, but not free evidence.
                    match += 1 / sqrt(multiple)
                }
                count += 1
            }
            let periodicity = count > 0 ? match / count : 0
            let evidence = min(1, Double(onsets.count - 2) / 8)
            let voteFraction = min(1, votes[bin, default: 0] / max(1, Double(onsets.count - 1)))
            let score = Float(min(1, (0.85 * periodicity + 0.15 * voteFraction) * evidence))
            if score >= 0.25 {
                candidates.append(.init(bpm: bpm, confidence: score))
            }
        }
        candidates.sort { $0.confidence == $1.confidence ?
            $0.bpm < $1.bpm : $0.confidence > $1.confidence }
        let confidence = candidates.first?.confidence ?? 0

        // A regular grid is only a proposal when the evidence is sufficient.
        // Grid indexes and timestamps never exceed the analyzed source prefix.
        var grid: [RhythmAnalysisResult.BeatEvent] = []
        if confidence >= 0.50, let selected = candidates.first {
            let period = 60 / selected.bpm
            let first = onsets[0]
            let initial = max(0, first - floor(first / period) * period)
            let maxCount = min(5_000, Int((timeline.duration - initial) / period) + 1)
            if maxCount > 0 {
                for index in 0..<maxCount {
                    if index % 256 == 0 { try Task.checkCancellation() }
                    let time = initial + Double(index) * period
                    guard time <= timeline.duration else { break }
                    let closest = onsets.lowerBound(time)
                    let left = closest > 0 ? abs(onsets[closest - 1] - time) : Double.infinity
                    let right = closest < onsets.count ? abs(onsets[closest] - time) : Double.infinity
                    let distance = min(left, right)
                    let strength = Float(max(0, 1 - distance / (0.22 * period)))
                    grid.append(.init(time: time, index: index, strength: strength))
                }
            }
        }
        return RhythmAnalysisResult(onsetEvents: onsets, bpmCandidates: candidates,
                                    beatGrid: grid, confidence: confidence)
    }

    private static let empty = RhythmAnalysisResult(onsetEvents: [],
        bpmCandidates: [], beatGrid: [], confidence: 0)
}

private extension Array where Element == AudioFeaturePoint {
    func binarySearchTime(_ time: Double) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return Swift.min(Swift.max(0, low), count - 1)
    }
}

private extension Array where Element == TimeInterval {
    func lowerBound(_ value: TimeInterval) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
