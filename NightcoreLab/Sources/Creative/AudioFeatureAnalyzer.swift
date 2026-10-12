import Foundation
import AVFoundation

/// A cheap, source-time-indexed envelope. No AVAudioEngine, taps, live
/// callback allocations, timers or SwiftUI publications are involved.
struct AudioFeaturePoint: Equatable, Sendable {
    let time: TimeInterval
    let features: AudioFeatures
}

struct AudioFeatureTimeline: Sendable {
    let points: [AudioFeaturePoint]
    let duration: TimeInterval

    /// Binary search: O(log n) even on multi-minute songs.
    func features(at time: TimeInterval) -> AudioFeatures {
        guard time.isFinite, time >= 0, time <= duration, !points.isEmpty
        else { return .silent }
        var low = 0
        var high = points.count
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].time <= time { low = mid + 1 }
            else { high = mid }
        }
        let index = max(0, low - 1)
        return points[index].features
    }
}

enum AudioFeatureAnalysisError: LocalizedError {
    case unsupportedAudio
    var errorDescription: String? {
        "Formato de áudio indisponível para análise visual."
    }
}

/// Coarse 12 Hz three-band envelope. First-order filters are a lightweight
/// *approximation*, not an FFT or validated BPM estimator. Beat flags indicate
/// energy onsets, not a tempo transcription.
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
        var accumulator = EnvelopeAccumulator(sampleRate: sampleRate, windowSize: windowSize)
        var processed: AVAudioFramePosition = 0

        while processed < allowed {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(windowSize), allowed - processed))
            try file.read(into: buffer, frameCount: count)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            let stereo = file.processingFormat.channelCount == 2
            for frame in 0..<frames {
                let sample = stereo
                    ? 0.5 * (Double(channels[0][frame]) + Double(channels[1][frame]))
                    : Double(channels[0][frame])
                accumulator.consume(sample)
            }
            processed += AVAudioFramePosition(frames)
        }
        accumulator.finish()
        return AudioFeatureTimeline(points: accumulator.points,
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
        private let bassCoefficient: Double
        private let midCoefficient: Double

        private var bassFilter = 0.0
        private var midFilter = 0.0
        private var totalFrames = 0
        private var windowCount = 0
        private var bassPower = 0.0
        private var midPower = 0.0
        private var treblePower = 0.0
        private var fullPower = 0.0
        private var rollingEnergy = 0.0
        private var lastOnset = -1.0
        private(set) var points: [AudioFeaturePoint] = []

        init(sampleRate: Double, windowSize: Int) {
            self.sampleRate = sampleRate
            self.windowSize = windowSize
            bassCoefficient = 1 - exp(-2 * .pi * 180 / sampleRate)
            midCoefficient = 1 - exp(-2 * .pi * 2200 / sampleRate)
        }

        mutating func consume(_ sample: Double) {
            let x = sample.isFinite ? min(max(sample, -1), 1) : 0
            bassFilter += bassCoefficient * (x - bassFilter)
            midFilter += midCoefficient * (x - midFilter)
            let bass = bassFilter
            let mid = midFilter - bassFilter
            let treble = x - midFilter
            bassPower += bass * bass
            midPower += mid * mid
            treblePower += treble * treble
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
            points.append(AudioFeaturePoint(
                time: time,
                features: AudioFeatures(bass: level(bassPower), mid: level(midPower),
                                        treble: level(treblePower), energy: energy,
                                        beatDetected: onset)
            ))
            windowCount = 0
            bassPower = 0
            midPower = 0
            treblePower = 0
            fullPower = 0
        }
    }
}
