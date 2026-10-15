import AVFoundation
import Foundation

/// Advisory stereo-center energy for offline lyric alignment. It never runs on
/// the audio callback or drives karaoke scoring.
enum StereoVocalEnergyAnalyzer {
    static func analyze(_ url: URL) throws -> [(time: TimeInterval, value: Double)] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        guard file.processingFormat.channelCount == 2,
              file.processingFormat.sampleRate > 0 else { return [] }
        let rate = file.processingFormat.sampleRate
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else { return [] }
        let lowAlpha = exp(-2 * Double.pi * 250 / rate)
        let highAlpha = exp(-2 * Double.pi * 3500 / rate)
        let binFrames = max(1, Int(rate * 0.025))
        var low250 = 0.0, low3500 = 0.0
        var sum = 0.0, count = 0, frameIndex = 0
        var result: [(time: TimeInterval, value: Double)] = []
        while true {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            for index in 0..<frames {
                let center = (Double(left[index]) + Double(right[index])) * 0.5
                low250 = lowAlpha * low250 + (1 - lowAlpha) * center
                low3500 = highAlpha * low3500 + (1 - highAlpha) * center
                let band = low3500 - low250
                sum += band * band
                count += 1
                frameIndex += 1
                if count == binFrames {
                    result.append((Double(frameIndex - count / 2) / rate,
                                   (sum / Double(count)).squareRoot()))
                    sum = 0; count = 0
                }
            }
        }
        let peak = result.map { $0.value }.max() ?? 0
        guard peak > 0 else { return result }
        return result.map { ($0.time, min(1, $0.value / peak)) }
    }
}
