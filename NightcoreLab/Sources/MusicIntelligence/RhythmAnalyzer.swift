import Accelerate
import AVFoundation
import Foundation

/// Rhythm Intelligence v3 (Stage 12.5; v2 = Stage 11). Deterministic,
/// offline, no dependency.
///
/// v1 derived tempo from intervals between onsets quantized to the 83 ms
/// visual envelope; any tempo that was not a multiple of that hop came out
/// wrong (128 BPM → 120 with ~0.96 confidence, drifting ~2 s/min).
///
/// v2 pipeline (validated against a numerical prototype before porting):
/// 1. Onset strength: log-magnitude spectral flux, window 2·H with hop H
///    (256/512/1024 samples ≈ 11–16 ms), per channel then summed (no downmix
///    cancellation), detrended by a ±0.25 s moving average, half-wave
///    rectified and normalized by its standard deviation.
/// 2. Tempo: autocorrelation of the centered onset strength over 55…210 BPM,
///    weighted by a log-Gaussian prior (120 BPM, σ = 1 octave), with parabolic
///    sub-frame interpolation of the chosen peak.
/// 3. Beats: dynamic-programming tracking (Ellis 2007) with log-interval
///    penalty, then sub-frame refinement on the onset curve.
/// 3b. Metrical checks (v3, from genre fixtures — see
///    docs/RHYTHM_REAL_WORLD_VALIDATION_STAGE12_5.md):
///    - octave: a > 160 BPM pick moves to half tempo when the double lag keeps
///      ≥ 50 % of the periodicity; a < 80 BPM pick moves to double when the
///      half lag does (drum patterns repeat every 2 beats);
///    - doubling: half-beats as strong as beats (both bands, or either band
///      below 80 BPM) mean the tracked level is half the tempo;
///    - phase: when the low band (kick) sits clearly on the half-beat, loud
///      off-beat hats pulled the beats off phase; shift by half a period.
/// 4. Downbeat (4/4 assumption): the bar phase with the most low-band
///    (< 150 Hz) energy at its beats; confidence = its margin over the next.
/// 5. Confidence: periodicity (ACF at the tempo), beat/off-beat contrast and
///    inter-beat stability. Without beat/off-beat contrast (v3) confidence is
///    scaled down to 40 %: periodic textures without drums are not a pulse.
///    Below 0.25 no beats are published.
enum RhythmAnalyzer {
    static let maxAnalysisSeconds = AudioFeatureAnalyzer.maxAnalysisSeconds

    // MARK: Entry points

    /// Decodes the same local file the player uses, without AVAudioEngine.
    /// `limit` keeps beats inside the energy timeline's analyzed coverage.
    static func analyzeFile(at url: URL, through limit: TimeInterval? = nil) throws -> RhythmAnalysisResult {
        try Task.checkCancellation()
        guard url.isFileURL else { throw AudioFeatureAnalysisError.unsupportedAudio }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let sampleRate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        guard sampleRate.isFinite, sampleRate > 0, (1...2).contains(channels)
        else { throw AudioFeatureAnalysisError.unsupportedAudio }

        let seconds = min(limit ?? maxAnalysisSeconds, maxAnalysisSeconds)
        let allowed = min(file.length, AVAudioFramePosition(max(0, seconds) * sampleRate))
        var builder = OnsetEnvelopeBuilder(sampleRate: sampleRate, channels: channels)
        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: chunk)
        else { throw AudioFeatureAnalysisError.unsupportedAudio }
        var processed: AVAudioFramePosition = 0
        while processed < allowed {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(chunk), allowed - processed))
            try file.read(into: buffer, frameCount: count)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            builder.consume((0..<channels).map {
                UnsafeBufferPointer<Float>(start: data[$0], count: frames)
            })
            processed += AVAudioFramePosition(frames)
        }
        return try analyze(builder.finish(duration: Double(processed) / sampleRate))
    }

    /// Deterministic, dependency-free entry point for DSP tests and fixtures.
    static func analyze(channels: [[Float]], sampleRate: Double) throws -> RhythmAnalysisResult {
        guard sampleRate.isFinite, sampleRate > 0,
              (1...2).contains(channels.count),
              let length = channels.map(\.count).min(), length > 0 else { return empty }
        let allowed = min(length, Int(maxAnalysisSeconds * sampleRate))
        var builder = OnsetEnvelopeBuilder(sampleRate: sampleRate, channels: channels.count)
        try Task.checkCancellation()
        channels[0].withUnsafeBufferPointer { first in
            let left = UnsafeBufferPointer(rebasing: first[0..<allowed])
            if channels.count == 2 {
                channels[1].withUnsafeBufferPointer { second in
                    builder.consume([left, UnsafeBufferPointer(rebasing: second[0..<allowed])])
                }
            } else {
                builder.consume([left])
            }
        }
        try Task.checkCancellation()
        return try analyze(builder.finish(duration: Double(allowed) / sampleRate))
    }

    static let empty = RhythmAnalysisResult(onsetEvents: [], bpmCandidates: [],
                                            beatGrid: [], confidence: 0)

    // MARK: Onset strength envelope

    struct OnsetEnvelope {
        /// Spectral flux per analysis frame (summed over channels).
        let flux: [Double]
        /// Linear low-band (< 150 Hz) energy per frame, for downbeats.
        let lowEnergy: [Double]
        /// Low-band (< 150 Hz) part of the flux: kick onsets, for phase checks.
        let lowFlux: [Double]
        /// Seconds between frames.
        let hop: Double
        /// Frame t is reported at (t·H + H) / sampleRate: the centre of the newer
        /// window, which the prototype calibrated to ~1 ms mean beat error.
        let frameOffset: Double
        let duration: TimeInterval

        func time(ofFrame frame: Double) -> TimeInterval { frame * hop + frameOffset }
    }

    static func hopSize(sampleRate: Double) -> Int {
        sampleRate <= 24_000 ? 256 : (sampleRate <= 50_000 ? 512 : 1_024)
    }

    /// Streaming STFT flux; nothing is allocated per frame.
    struct OnsetEnvelopeBuilder {
        private let hop: Int
        private let size: Int
        private let sampleRate: Double
        private let lowBins: Int
        private let fft: RealFFT
        private let window: [Float]
        private var rings: [[Float]]
        private var previous: [[Float]]
        private var hasPrevious: [Bool]
        private var written = 0
        private var flux: [Double] = []
        private var lowEnergy: [Double] = []
        private var lowFlux: [Double] = []
        private var frameScratch: [Float]
        private var logScratch: [Float]

        init(sampleRate: Double, channels: Int) {
            // Locals only: no closure may capture `self` before initialization.
            let hop = RhythmAnalyzer.hopSize(sampleRate: sampleRate)
            let size = hop * 2
            let bins = size / 2 - 1
            self.sampleRate = sampleRate
            self.hop = hop
            self.size = size
            fft = RealFFT(size: size)
            // Periodic Hann, written out so it never depends on vDSP flags.
            window = (0..<size).map { index in
                Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(size)))
            }
            lowBins = max(1, Int((150 / (sampleRate / Double(size))).rounded()))
            rings = Array(repeating: [Float](repeating: 0, count: size), count: channels)
            previous = Array(repeating: [Float](repeating: 0, count: bins), count: channels)
            hasPrevious = Array(repeating: false, count: channels)
            frameScratch = [Float](repeating: 0, count: size)
            logScratch = [Float](repeating: 0, count: bins)
        }

        /// One buffer per channel, all with the same frame count.
        mutating func consume(_ data: [UnsafeBufferPointer<Float>]) {
            let channels = min(data.count, rings.count)
            guard channels > 0 else { return }
            let frames = data[..<channels].map(\.count).min() ?? 0
            for frame in 0..<frames {
                let slot = written % size
                for channel in 0..<channels {
                    let value = data[channel][frame]
                    rings[channel][slot] = value.isFinite ? min(1, max(-1, value)) : 0
                }
                written += 1
                if written >= size, (written - size) % hop == 0 { emitFrame(channels: channels) }
            }
        }

        private mutating func emitFrame(channels: Int) {
            var frameFlux = 0.0
            var frameLow = 0.0
            var frameLowFlux = 0.0
            let scale = Float(2) / Float(size)
            let bins = size / 2 - 1
            for channel in 0..<channels {
                // Chronological window: oldest sample is at `written % size`.
                let start = written % size
                for i in 0..<size {
                    let index = start + i
                    frameScratch[i] = rings[channel][index < size ? index : index - size] * window[i]
                }
                // Magnitudes of bins 1..<size/2 (DC and Nyquist dropped).
                fft.magnitudes(of: frameScratch, into: &logScratch)
                for k in 0..<bins {
                    let magnitude = logScratch[k] * scale
                    if k < lowBins { frameLow += Double(magnitude * magnitude) }
                    logScratch[k] = log1p(100 * magnitude)
                }
                if hasPrevious[channel] {
                    var sum = 0.0
                    var low = 0.0
                    for k in 0..<bins {
                        let rise = logScratch[k] - previous[channel][k]
                        if rise > 0 {
                            sum += Double(rise)
                            if k < lowBins { low += Double(rise) }
                        }
                    }
                    frameFlux += sum
                    frameLowFlux += low
                }
                // Element copy: keeps both buffers uniquely owned (no per-frame
                // copy-on-write allocation).
                for k in 0..<bins { previous[channel][k] = logScratch[k] }
                hasPrevious[channel] = true
            }
            flux.append(frameFlux)
            lowEnergy.append(frameLow)
            lowFlux.append(frameLowFlux)
        }

        func finish(duration: TimeInterval) -> OnsetEnvelope {
            OnsetEnvelope(flux: flux, lowEnergy: lowEnergy, lowFlux: lowFlux,
                          hop: Double(hop) / sampleRate,
                          frameOffset: Double(hop) / sampleRate,
                          duration: duration)
        }
    }

    // MARK: Analysis

    static func analyze(_ envelope: OnsetEnvelope) throws -> RhythmAnalysisResult {
        let flux = envelope.flux
        let frames = flux.count
        let hop = envelope.hop
        guard frames >= 8, hop > 0, envelope.duration > 0 else { return empty }

        // 1. Detrended, rectified, normalized onset strength.
        let reach = max(1, Int((0.25 / hop).rounded()))
        var prefix = [Double](repeating: 0, count: frames + 1)
        for t in 0..<frames { prefix[t + 1] = prefix[t] + flux[t] }
        var ose = [Double](repeating: 0, count: frames)
        for t in 0..<frames {
            let a = max(0, t - reach), b = min(frames, t + reach + 1)
            ose[t] = max(0, flux[t] - (prefix[b] - prefix[a]) / Double(b - a))
        }
        let mean = ose.reduce(0, +) / Double(frames)
        let variance = ose.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(frames)
        let deviation = variance.squareRoot()
        guard deviation.isFinite, deviation > 1e-6, (flux.max() ?? 0) > 1e-3 else { return empty }
        for t in 0..<frames { ose[t] /= deviation }
        try Task.checkCancellation()

        // 2. Tempo from the centered autocorrelation.
        let lagMin = Int((60 / (210 * hop)).rounded(.down))
        let lagMax = min(Int((60 / (55 * hop)).rounded(.up)), frames - 2)
        guard lagMax > lagMin + 2 else { return empty }
        let centerMean = ose.reduce(0, +) / Double(frames)
        let centered = ose.map { $0 - centerMean }
        var acf = [Double](repeating: 0, count: lagMax + 2)
        for lag in 0...(lagMax + 1) {
            var sum = 0.0
            for t in 0..<(frames - lag) { sum += centered[t] * centered[t + lag] }
            acf[lag] = sum / Double(frames - lag)
        }
        guard acf[0] > 0 else { return empty }
        let normalized = acf.map { $0 / acf[0] }
        func prior(_ lag: Double) -> Double {
            let bpm = 60 / (lag * hop)
            let octaves = log2(bpm / 120)
            return exp(-0.5 * octaves * octaves)
        }
        var bestLag = -1
        var bestScore = -Double.infinity
        for lag in max(lagMin, 1)...lagMax {
            let value = normalized[lag]
            guard value >= normalized[lag - 1], value >= normalized[lag + 1] else { continue }
            let score = value * prior(Double(lag))
            if bestLag < 0 || score > bestScore { bestLag = lag; bestScore = score }
        }
        guard bestLag > 0 else { return empty }
        // Same rounding as the prototype (ties to even) for half lags.
        func nearestLag(_ lag: Double) -> Int { Int(lag.rounded(.toNearestOrEven)) }
        func acfNear(_ lag: Double) -> Double {
            let center = nearestLag(lag)
            guard center >= 1, center + 1 < normalized.count else { return -1 }
            return max(normalized[center - 1], normalized[center], normalized[center + 1])
        }
        func bestNear(_ lag: Double) -> Int {
            let center = nearestLag(lag)
            var best = -1
            for k in (center - 1)...(center + 1) where k >= 1 && k < normalized.count - 1 {
                if best < 0 || normalized[k] > normalized[best] { best = k }
            }
            return best
        }
        // Octave correction toward 80…160 BPM when the other octave keeps at
        // least half of the periodicity (v3; v2 picked 64 for EDM at 128).
        for _ in 0..<2 {
            let lagBPM = 60 / (Double(bestLag) * hop)
            let halfLag = Double(bestLag) / 2
            if lagBPM < 80, halfLag >= Double(max(lagMin, 1)),
               acfNear(halfLag) >= 0.5 * normalized[bestLag] {
                let moved = bestNear(halfLag)
                guard moved > 0 else { break }
                bestLag = moved
            } else if lagBPM > 160, 2 * bestLag <= lagMax,
                      acfNear(Double(2 * bestLag)) >= 0.5 * normalized[bestLag] {
                let moved = bestNear(Double(2 * bestLag))
                guard moved > 0 else { break }
                bestLag = moved
            } else {
                break
            }
        }
        let (a, b, c) = (normalized[bestLag - 1], normalized[bestLag], normalized[bestLag + 1])
        let curvature = a - 2 * b + c
        let shift = abs(curvature) > 1e-12 ? min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) : 0
        var period = Double(bestLag) + shift
        var bpm = 60 / (period * hop)
        try Task.checkCancellation()

        // 3. Dynamic-programming beat tracking.
        let tightness = 100.0
        let longest = Int((2 * period).rounded())
        let shortest = max(1, Int((period / 2).rounded()))
        var penalty = [Double](repeating: 0, count: longest + 1)
        for distance in shortest...max(shortest, longest) where distance <= longest {
            let ratio = log(Double(distance) / period)
            penalty[distance] = -tightness * ratio * ratio
        }
        var score = ose
        var backlink = [Int](repeating: -1, count: frames)
        for t in 0..<frames {
            if t % 4_096 == 0 { try Task.checkCancellation() }
            let first = max(0, t - longest)
            let last = t - shortest
            guard last >= first else { continue }
            var best = -Double.infinity
            var link = -1
            for tau in first...last {
                let value = score[tau] + penalty[t - tau]
                if link < 0 || value > best { best = value; link = tau }
            }
            if link >= 0, best > 0 {
                score[t] = ose[t] + best
                backlink[t] = link
            }
        }
        let tailStart = max(0, frames - Int(period.rounded(.up)))
        var end = tailStart
        for t in tailStart..<frames where score[t] > score[end] { end = t }
        var beatFrames = [end]
        while let last = beatFrames.last, backlink[last] >= 0 { beatFrames.append(backlink[last]) }
        beatFrames.reverse()

        // 3b. Metrical checks on the tracked beats (v3).
        func peak(_ curve: [Double], around frame: Int) -> Double {
            curve[max(0, frame - 1)...min(frames - 1, frame + 1)].max() ?? 0
        }
        /// Beat/half-beat ratios in the full band and in the low band, and the
        /// low-band half-beat/beat ratio.
        func contrasts(_ tracked: [Int], period: Double)
            -> (broad: Double, low: Double, lowOffRatio: Double) {
            let half = nearestLag(period / 2)
            var broadOn = 0.0, broadOff = 0.0, lowOn = 0.0, lowOff = 0.0, count = 0
            for frame in tracked where frame + half + 1 < frames {
                broadOn += peak(ose, around: frame)
                broadOff += peak(ose, around: frame + half)
                lowOn += peak(envelope.lowFlux, around: frame)
                lowOff += peak(envelope.lowFlux, around: frame + half)
                count += 1
            }
            guard count > 0 else { return (1, 1, 1) }
            let n = Double(count)
            let (bOn, bOff) = (broadOn / n, broadOff / n)
            let (lOn, lOff) = (lowOn / n, lowOff / n)
            return ((bOn + 1e-9) / (bOff + 1e-9), (lOn + 1e-9) / (lOff + 1e-9),
                    (lOff + 1e-9) / (lOn + 1e-9))
        }
        var metrics = contrasts(beatFrames, period: period)
        // Half-beats as strong as beats: the tracked level is half the tempo.
        let flat = max(metrics.broad, metrics.low) < 1.4
            || (bpm < 80 && min(metrics.broad, metrics.low) < 1.4)
        if flat, 60 / (period / 2 * hop) <= 210,
           acfNear(period / 2) >= 0.25 * normalized[bestLag], beatFrames.count >= 2 {
            var doubled: [Int] = []
            for (index, frame) in beatFrames.enumerated() {
                doubled.append(frame)
                if index + 1 < beatFrames.count {
                    let middle = Int((Double(frame + beatFrames[index + 1]) / 2)
                        .rounded(.toNearestOrEven))
                    if middle > frame, middle < beatFrames[index + 1] { doubled.append(middle) }
                }
            }
            beatFrames = doubled
            period /= 2
            bpm = 60 / (period * hop)
            metrics = contrasts(beatFrames, period: period)
        }
        // Loud off-beat hats can out-flux the kick: when the low band sits
        // clearly on the half-beat, the beats are on the wrong phase.
        if metrics.lowOffRatio > 2 {
            let half = nearestLag(period / 2)
            beatFrames = beatFrames.map { $0 + half }.filter { $0 < frames }
            metrics = contrasts(beatFrames, period: period)
        }

        var beats: [(frame: Int, time: TimeInterval)] = []
        for frame in beatFrames {
            var offset = 0.0
            if frame > 0, frame < frames - 1 {
                let (l, m, r) = (ose[frame - 1], ose[frame], ose[frame + 1])
                let bend = l - 2 * m + r
                if m >= l, m >= r, abs(bend) > 1e-12 {
                    offset = min(0.5, max(-0.5, 0.5 * (l - r) / bend))
                }
            }
            let time = envelope.time(ofFrame: Double(frame) + offset)
            if time >= 0, time <= envelope.duration,
               beats.last.map({ time > $0.time }) ?? true {
                beats.append((frame, time))
            }
        }

        // 5. Confidence: periodicity, beat/off-beat contrast, stability.
        let onBeat = beats.map { peak(ose, around: $0.frame) }
        // Either band may carry the contrast (kick-only accents live in the low band).
        let salience = max(metrics.broad, metrics.low)
        let intervals = zip(beats.dropFirst(), beats).map { $0.time - $1.time }
        let spread: Double
        if intervals.count > 1 {
            let m = average(intervals)
            let v = intervals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(intervals.count)
            spread = m > 0 ? v.squareRoot() / m : 1
        } else { spread = 1 }
        let contrast = clamp((salience - 2) / 4)
        let periodicity = clamp(normalized[bestLag] / 0.35)
        let stability = clamp(1 - spread * 4)
        var confidence = clamp(0.6 * periodicity + 0.25 * contrast + 0.15 * stability)
        if periodicity < 0.3 { confidence *= periodicity / 0.3 }
        // Beats must stand out from the half-beat between them (songs without
        // drums showed contrast 0 with periodicity up to 0.73).
        confidence *= min(1, 0.4 + 4 * contrast)
        if beats.count < 4 { confidence = 0 }
        let reliable = RhythmAnalysisResult.quality(for: Float(confidence)) != .insufficient

        // 4. Downbeat under a 4/4 assumption.
        var downbeatPhase: Int?
        var downbeatConfidence = 0.0
        if beats.count >= 8 {
            let accentReach = max(2, Int((0.08 / hop).rounded()))
            let accents = beats.map { beat -> Double in
                let lower = max(0, beat.frame - 1)
                let upper = min(frames, beat.frame + accentReach)
                return envelope.lowEnergy[lower..<upper].max() ?? 0
            }
            var sums: [Double] = []
            for phase in 0..<4 {
                let members = stride(from: phase, to: accents.count, by: 4).map { accents[$0] }
                sums.append(members.isEmpty ? 0 : average(members))
            }
            let order = sums.indices.sorted { sums[$0] == sums[$1] ? $0 < $1 : sums[$0] > sums[$1] }
            if sums[order[0]] > 0 {
                downbeatPhase = order[0]
                downbeatConfidence = clamp((sums[order[0]] - sums[order[1]]) / (sums[order[0]] + 1e-9))
            }
        }

        let strongest = onBeat.max() ?? 0
        let grid: [RhythmAnalysisResult.BeatEvent] = reliable ? beats.prefix(5_000).enumerated().map { index, beat in
            RhythmAnalysisResult.BeatEvent(
                time: beat.time, index: index,
                strength: Float(strongest > 0 ? clamp(onBeat[index] / strongest) : 0),
                isDownbeat: downbeatPhase.map { index % 4 == $0 } ?? false)
        } : []

        return RhythmAnalysisResult(
            onsetEvents: onsets(ose, envelope: envelope),
            bpmCandidates: candidates(bpm: bpm, period: period, normalized: normalized,
                                      confidence: confidence, hop: hop),
            beatGrid: grid,
            confidence: Float(confidence),
            downbeatConfidence: reliable ? Float(downbeatConfidence) : 0)
    }

    /// Local maxima at least one standard deviation strong, ≥ 50 ms apart.
    private static func onsets(_ ose: [Double], envelope: OnsetEnvelope) -> [TimeInterval] {
        var result: [TimeInterval] = []
        guard ose.count >= 3 else { return result }
        for t in 1..<(ose.count - 1) where ose[t] > 1 && ose[t] > ose[t - 1] && ose[t] >= ose[t + 1] {
            let time = envelope.time(ofFrame: Double(t))
            guard time <= envelope.duration else { break }
            if let last = result.last, time - last < 0.05 { continue }
            result.append(time)
        }
        return result
    }

    /// The tracked tempo plus its octave relatives, each weighted by how much
    /// periodicity the autocorrelation shows at that lag.
    private static func candidates(bpm: Double, period: Double, normalized: [Double],
                                   confidence: Double, hop: Double) -> [RhythmAnalysisResult.BPMCandidate] {
        guard confidence > 0, (55...210).contains(bpm) else { return [] }
        func acf(at lag: Double) -> Double {
            let lower = Int(lag.rounded(.down))
            guard lower >= 0, lower + 1 < normalized.count else { return 0 }
            let fraction = lag - Double(lower)
            return normalized[lower] * (1 - fraction) + normalized[lower + 1] * fraction
        }
        let reference = max(acf(at: period), 1e-9)
        // The TRACKED tempo is always first: on a strictly periodic signal the
        // autocorrelation at 2× the period is as high as at the period, and a
        // confidence tie must not promote the half tempo (CI: 124 → 62 BPM).
        var alternatives: [RhythmAnalysisResult.BPMCandidate] = []
        for factor in [2.0, 0.5] {
            let alternative = bpm * factor
            guard (55...210).contains(alternative) else { continue }
            let support = clamp(acf(at: period / factor) / reference)
            alternatives.append(.init(bpm: alternative, confidence: Float(confidence * support)))
        }
        alternatives.sort {
            $0.confidence == $1.confidence ? $0.bpm > $1.bpm : $0.confidence > $1.confidence
        }
        return [RhythmAnalysisResult.BPMCandidate(bpm: bpm, confidence: Float(confidence))]
            + alternatives
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// Minimal vDSP real FFT returning magnitudes of bins 1..<n/2, in DFT units
/// (vDSP's 2× forward scaling is removed).
final class RealFFT {
    let size: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private var real: [Float]
    private var imaginary: [Float]

    init(size: Int) {
        self.size = size
        log2Size = vDSP_Length(Int(log2(Double(size))))
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(of samples: [Float], into output: inout [Float]) {
        let half = size / 2
        samples.withUnsafeBytes { bytes in
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    guard let input = bytes.bindMemory(to: DSPComplex.self).baseAddress,
                          let realAddress = re.baseAddress,
                          let imaginaryAddress = im.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realAddress, imagp: imaginaryAddress)
                    vDSP_ctoz(input, 2, &split, 1, vDSP_Length(half))
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                }
            }
        }
        for bin in 1..<half {
            let re = real[bin], im = imaginary[bin]
            output[bin - 1] = (re * re + im * im).squareRoot() / 2
        }
    }
}
