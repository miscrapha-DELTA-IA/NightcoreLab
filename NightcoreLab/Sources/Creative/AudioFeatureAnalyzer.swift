import Foundation
import AVFoundation

/// A cheap, source-time-indexed envelope. No AVAudioEngine, taps, live
/// callback allocations, timers or SwiftUI publications are involved.
struct AudioFeaturePoint: Codable, Equatable, Sendable {
    let time: TimeInterval
    let features: AudioFeatures
}

struct AudioFeatureTimeline: Codable, Equatable, Sendable {
    let points: [AudioFeaturePoint]
    let duration: TimeInterval

    /// Index of the first point strictly later than the supplied media time.
    /// Used for both the envelope and pulse queries.
    private func upperBound(_ time: TimeInterval) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = low + (high - low) / 2
            if points[middle].time <= time { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    /// Binary search: O(log n) even on multi-minute songs.
    func features(at time: TimeInterval) -> AudioFeatures {
        guard time.isFinite, time >= 0, time <= duration, !points.isEmpty
        else { return .silent }
        return points[max(0, upperBound(time) - 1)].features
    }

    /// Event pulses between two *source-time* snapshots. A visual reader may
    /// drop intermediate envelope frames without losing beat onsets.
    func beatCount(after start: TimeInterval, through end: TimeInterval) -> Int {
        guard start.isFinite, end.isFinite,
              start >= 0, end <= duration, end > start else { return 0 }
        let begin = upperBound(start)
        let finish = upperBound(end)
        guard begin < finish else { return 0 }
        return points[begin..<finish].reduce(0) {
            $0 + ($1.features.beatDetected ? 1 : 0)
        }
    }
}

enum AudioFeatureAnalysisError: LocalizedError {
    case unsupportedAudio
    var errorDescription: String? {
        "Formato de áudio indisponível para análise visual."
    }
}

/// A ~12 Hz visual envelope: Accelerate/vDSP real FFT supplies three frequency
/// bands and the original RMS/onset detector supplies energy and beat flags.
/// Spectral bins are approximate bands, not BPM or a calibrated spectrum.
///
/// Reading is opt-in and independent of the live audio graph; work should be
/// launched from Task.detached(priority: .utility).
enum AudioFeatureAnalyzer {
    static let maxAnalysisSeconds: Double = 20 * 60

    static func analyzeFile(at url: URL) throws -> AudioFeatureTimeline {
        try Task.checkCancellation()
        guard url.isFileURL else { throw AudioFeatureAnalysisError.unsupportedAudio }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0,
              (1...2).contains(file.processingFormat.channelCount)
        else { throw AudioFeatureAnalysisError.unsupportedAudio }

        let windowSize = windowFrames(sampleRate: sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(windowSize))
        else { throw AudioFeatureAnalysisError.unsupportedAudio }

        let allowed = min(file.length, AVAudioFramePosition(maxAnalysisSeconds * sampleRate))
        // Analyze each stereo channel independently and combine power
        // afterwards. Downmixing anti-phase channels into mono loses bass.
        var accumulators = (0..<Int(file.processingFormat.channelCount)).map {
            _ in EnvelopeAccumulator(sampleRate: sampleRate, windowSize: windowSize)
        }
        var processed: AVAudioFramePosition = 0

        while processed < allowed {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(windowSize), allowed - processed))
            try file.read(into: buffer, frameCount: count)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                for channel in accumulators.indices {
                    accumulators[channel].consume(Double(channels[channel][frame]))
                }
            }
            processed += AVAudioFramePosition(frames)
        }
        for channel in accumulators.indices { accumulators[channel].finish() }
        let reference = accumulators[0].points
        if accumulators.count == 1 {
            return AudioFeatureTimeline(points: reference,
                                        duration: Double(processed) / sampleRate)
        }
        let combined: [AudioFeaturePoint] = reference.indices.map { index in
            let bands = accumulators.map { $0.points[index].features }
            func rms(_ level: (AudioFeatures) -> Double) -> Double {
                sqrt(bands.reduce(0.0) { $0 + pow(level($1), 2) } / Double(bands.count))
            }
            return AudioFeaturePoint(
                time: reference[index].time,
                features: AudioFeatures(bass: rms { $0.bass }, mid: rms { $0.mid },
                                        treble: rms { $0.treble },
                                        energy: rms { $0.energy },
                                        beatDetected: bands.contains { $0.beatDetected })
            )
        }
        return AudioFeatureTimeline(points: combined,
                                    duration: Double(processed) / sampleRate)
    }

    /// Deterministic, dependency-free entry point for DSP tests and fixtures.
    static func analyze(samples: [Float], sampleRate: Double) -> AudioFeatureTimeline {
        guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty else {
            return AudioFeatureTimeline(points: [], duration: 0)
        }
        let allowed = min(samples.count, Int(maxAnalysisSeconds * sampleRate))
        var accumulator = EnvelopeAccumulator(
            sampleRate: sampleRate, windowSize: windowFrames(sampleRate: sampleRate))
        for value in samples.prefix(allowed) { accumulator.consume(Double(value)) }
        accumulator.finish()
        return AudioFeatureTimeline(points: accumulator.points,
                                    duration: Double(allowed) / sampleRate)
    }

    private static func windowFrames(sampleRate: Double) -> Int {
        min(8192, max(512, Int(sampleRate / 12)))
    }

    private struct EnvelopeAccumulator {
        let sampleRate: Double
        let windowSize: Int
        private let spectrum: AudioFFTSpectrum?

        private var totalFrames = 0
        private var windowCount = 0
        private var fullPower = 0.0
        private var rollingEnergy = 0.0
        private var lastOnset = -1.0
        private(set) var points: [AudioFeaturePoint] = []

        init(sampleRate: Double, windowSize: Int) {
            self.sampleRate = sampleRate
            self.windowSize = windowSize
            spectrum = AudioFFTSpectrum(sampleRate: sampleRate)
        }

        mutating func consume(_ sample: Double) {
            let x = sample.isFinite ? min(max(sample, -1), 1) : 0
            spectrum?.consume(Float(x))
            fullPower += x * x
            totalFrames += 1
            windowCount += 1
            if windowCount == windowSize { flush() }
        }

        mutating func finish() {
            if windowCount > 0 { flush() }
        }

        private mutating func flush() {
            guard windowCount > 0 else { return }
            let count = Double(windowCount)
            func level(_ power: Double) -> Double {
                min(1, sqrt(power / count) * 4)
            }
            let energy = level(fullPower)
            let time = Double(totalFrames - windowCount / 2) / sampleRate
            let onset = energy > 0.16 &&
                energy > max(rollingEnergy * 1.55, 0.12) &&
                time - lastOnset >= 0.23
            if onset { lastOnset = time }
            rollingEnergy = rollingEnergy * 0.82 + energy * 0.18
            let bands = spectrum?.bands() ?? (bass: 0, mid: 0, treble: 0)
            points.append(AudioFeaturePoint(
                time: time,
                features: AudioFeatures(bass: bands.bass, mid: bands.mid,
                                        treble: bands.treble, energy: energy,
                                        beatDetected: onset)
            ))
            windowCount = 0
            fullPower = 0
        }
    }
}
