import AVFoundation
import Foundation

/// Offline preparation for an opt-in live playback lane. The original lane
/// remains the transport clock; the two lanes crossfade without graph rebuilds.
enum CenterCutProcessor {
    struct BandState {
        private let bassAlpha: Double
        private let highAlpha: Double
        private var bass = 0.0
        private var lowHigh1 = 0.0
        private var lowHigh2 = 0.0

        init(sampleRate: Double) {
            bassAlpha = exp(-2 * Double.pi * 150 / sampleRate)
            highAlpha = exp(-2 * Double.pi * 4200 / sampleRate)
        }

        mutating func process(left: Float, right: Float) -> (Float, Float) {
            let l = Double(left), r = Double(right)
            let center = (l + r) * 0.5
            let side = (l - r) * 0.5
            bass = bassAlpha * bass + (1 - bassAlpha) * center
            lowHigh1 = highAlpha * lowHigh1 + (1 - highAlpha) * center
            let high1 = center - lowHigh1
            lowHigh2 = highAlpha * lowHigh2 + (1 - highAlpha) * high1
            let preservedCenter = bass + high1 - lowHigh2
            return (Float(max(-1, min(1, preservedCenter + side))),
                    Float(max(-1, min(1, preservedCenter - side))))
        }
    }

    static func prepare(source: URL) throws -> URL? {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        guard input.processingFormat.channelCount == 2 else { return nil }
        let rate = input.processingFormat.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("nightcore_center_cut_\(UUID().uuidString).caf")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        let writer = try AVAudioFile(forWriting: output, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else { return nil }
        var state = BandState(sampleRate: rate)
        while true {
            try Task.checkCancellation()
            try input.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            for index in 0..<frames {
                let output = state.process(left: left[index], right: right[index])
                left[index] = output.0
                right[index] = output.1
            }
            try writer.write(from: buffer)
        }
        completed = true
        return output
    }

    static func ramp(_ step: Int, total: Int = 5) -> Float {
        Float(min(total, max(0, step))) / Float(total)
    }
}
