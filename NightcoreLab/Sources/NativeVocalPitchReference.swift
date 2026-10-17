import AVFoundation
import Foundation

/// Sparse, optional pitch evidence from the locally extracted vocal file.
/// Sample times are source times, so the existing karaoke clock needs no change.
struct NativeVocalPitchReference: Sendable {
    static let interval = 0.2
    let frequencies: [Double?]
    let hasVoicedSamples: Bool

    init(frequencies: [Double?]) {
        self.frequencies = frequencies
        hasVoicedSamples = frequencies.contains { $0 != nil }
    }

    func frequency(at sourceTime: TimeInterval) -> Double? {
        guard sourceTime.isFinite, sourceTime >= 0 else { return nil }
        let index = Int((sourceTime / Self.interval).rounded())
        guard frequencies.indices.contains(index) else { return nil }
        return frequencies[index]
    }

    static func analyze(vocalsURL: URL) throws -> Self {
        let file = try AVAudioFile(forReading: vocalsURL, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate >= 4_000,
              (1...2).contains(format.channelCount), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rate = format.sampleRate
        let count = Int(ceil(Double(file.length) / rate / interval))
        let stride = max(1, Int(rate / 8_000))
        var frequencies: [Double?] = []
        frequencies.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            file.framePosition = AVAudioFramePosition(Double(index) * interval * rate)
            try file.read(into: buffer, frameCount: 4096)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
                frequencies.append(nil)
                continue
            }
            let frames = Int(buffer.frameLength)
            var samples: [Float] = []
            samples.reserveCapacity(frames / stride + 1)
            for frame in Swift.stride(from: 0, to: frames, by: stride) {
                let left = channels[0][frame]
                let right = format.channelCount == 2 ? channels[1][frame] : left
                samples.append((left + right) * 0.5)
            }
            let voice = KaraokeVoiceAnalyzer.analyze(samples,
                sampleRate: rate / Double(stride))
            frequencies.append(voice.isVoiced ? voice.frequency : nil)
        }
        return Self(frequencies: frequencies)
    }

    static func accuracy(sung: Double, reference: Double, pitchShift: Double) -> Double? {
        guard sung.isFinite, reference.isFinite, sung > 0, reference > 0,
              pitchShift.isFinite else { return nil }
        let cents = 1200 * log2(sung / reference) - pitchShift
        // Octave equivalence avoids penalizing a singer for a different register.
        let octaveDistance = abs(cents - 1200 * (cents / 1200).rounded())
        return max(0, min(1, 1 - max(0, octaveDistance - 35) / 165))
    }
}
