import AVFoundation
import Foundation

/// Offline preparation for an opt-in live playback lane. The original lane
/// remains the transport clock; the two lanes crossfade without graph rebuilds.
enum CenterCutProcessor {
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
        let hpAlpha = exp(-2 * Double.pi * 220 / rate)
        let lpAlpha = exp(-2 * Double.pi * 4200 / rate)
        var low220 = 0.0
        var low4200 = 0.0
        while true {
            try Task.checkCancellation()
            try input.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            for index in 0..<frames {
                let l = Double(left[index]), r = Double(right[index])
                let center = (l + r) * 0.5
                low220 = hpAlpha * low220 + (1 - hpAlpha) * center
                low4200 = lpAlpha * low4200 + (1 - lpAlpha) * center
                let vocalBand = low4200 - low220
                left[index] = Float(max(-1, min(1, l - vocalBand)))
                right[index] = Float(max(-1, min(1, r - vocalBand)))
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
